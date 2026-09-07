import Foundation

enum ModelError: Error, LocalizedError {
    case http(Int)
    case incomplete
    case missing
    case notGGML

    var errorDescription: String? {
        switch self {
        case .http(let code): return "Hugging Face HTTP \(code)"
        case .incomplete: return "Файл скачался не полностью"
        case .missing: return "Модель ещё не скачана"
        case .notGGML: return "Скачался не ggml (HTML/ошибка Hugging Face). Повторите загрузку."
        }
    }
}

@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    @Published var selectedASRId: String {
        didSet { UserDefaults.standard.set(selectedASRId, forKey: "models.asr") }
    }
    @Published var progress: [String: Double] = [:]
    @Published var busyId: String?
    @Published var lastError: String?

    private let fm = FileManager.default
    private let root: URL

    private init() {
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = base.appendingPathComponent("Models", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        selectedASRId = UserDefaults.standard.string(forKey: "models.asr") ?? ModelCatalog.defaultASRId
    }

    var selectedASR: ASRModelSpec {
        ModelCatalog.asr(selectedASRId) ?? ModelCatalog.asr.first { $0.id == ModelCatalog.defaultASRId }!
    }

    var asrReady: Bool { isDownloaded(asr: selectedASR) }
    var llmReady: Bool { isDownloaded(llm: ModelCatalog.llm) }

    func asrFileURL(_ spec: ASRModelSpec) -> URL {
        root.appendingPathComponent("asr/\(spec.id)/\(spec.file.path)", isDirectory: false)
    }

    func llmDirectory() -> URL {
        root.appendingPathComponent("llm/\(ModelCatalog.llm.id)", isDirectory: true)
    }

    func isDownloaded(asr spec: ASRModelSpec) -> Bool {
        let url = asrFileURL(spec)
        return fileOK(url, expected: spec.file.bytes) && Self.isGGML(url)
    }

    func isDownloaded(llm spec: LLMModelSpec) -> Bool {
        spec.files.allSatisfy { fileOK(llmDirectory().appendingPathComponent($0.path), expected: $0.bytes) }
    }

    func downloadASR(_ spec: ASRModelSpec) async {
        lastError = nil
        busyId = spec.id
        defer { busyId = nil }
        do {
            try await download(spec.file, to: asrFileURL(spec), key: spec.id)
            selectedASRId = spec.id
            await WhisperEngine.shared.unloadModel()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectASR(_ spec: ASRModelSpec) async {
        guard isDownloaded(asr: spec) else {
            await downloadASR(spec)
            return
        }
        if selectedASRId != spec.id {
            selectedASRId = spec.id
            await WhisperEngine.shared.unloadModel()
        }
    }

    func downloadLLM() async {
        lastError = nil
        busyId = ModelCatalog.llm.id
        defer { busyId = nil }
        do {
            let dir = llmDirectory()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let total = ModelCatalog.llm.files.reduce(Int64(0)) { $0 + $1.bytes }
            var done: Int64 = 0
            for file in ModelCatalog.llm.files {
                let dest = dir.appendingPathComponent(file.path)
                try await download(file, to: dest, key: ModelCatalog.llm.id, base: done, total: total)
                done += file.bytes
            }
            await LLMEngine.shared.unload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func prepareWhisper() async throws {
        let spec = selectedASR
        guard isDownloaded(asr: spec) else { throw ModelError.missing }
        try await WhisperEngine.shared.ensureLoaded(from: asrFileURL(spec), turboDTW: spec.turboDTW)
    }

    private func fileOK(_ url: URL, expected: Int64) -> Bool {
        guard let n = try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber else { return false }
        let size = n.int64Value
        if expected < 10_000 { return size > 0 }
        return size >= expected - 1024
    }

    private func download(_ file: RemoteFile, to dest: URL, key: String, base: Int64 = 0, total: Int64? = nil) async throws {
        if fileOK(dest, expected: file.bytes) {
            progress[key] = 1
            return
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        var request = URLRequest(url: file.url)
        request.setValue("huggingface-hub/0.25.0; dicta/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 600

        let span = total ?? file.bytes
        let (tmp, response) = try await HFDownload.run(request) { written, expected in
            let denom = expected > 0 ? expected : file.bytes
            let overall = Double(base + written) / Double(max(total ?? denom, 1))
            Task { @MainActor in
                self.progress[key] = min(0.99, overall)
            }
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            try? fm.removeItem(at: tmp)
            throw ModelError.http(code)
        }
        let size = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            try? fm.removeItem(at: tmp)
            throw ModelError.incomplete
        }
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: tmp, to: dest)
        if file.path.hasSuffix(".bin"), !Self.isGGML(dest) {
            try? fm.removeItem(at: dest)
            throw ModelError.notGGML
        }
        progress[key] = total == nil ? 1 : Double(base + size) / Double(max(span, 1))
    }

    static func isGGML(_ url: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: 4)
        guard data.count == 4 else { return false }
        let s = String(bytes: data, encoding: .ascii) ?? ""
        if s.hasPrefix("<") || s.hasPrefix("{") { return false }
        return true
    }
}

private final class HFDownload: NSObject, URLSessionDownloadDelegate {
    private var cont: CheckedContinuation<(URL, URLResponse), Error>?
    private var onProgress: ((Int64, Int64) -> Void)?
    private var tmpCopy: URL?

    static func run(_ request: URLRequest, progress: @escaping (Int64, Int64) -> Void) async throws -> (URL, URLResponse) {
        let box = HFDownload()
        box.onProgress = progress
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 3600
        let session = URLSession(configuration: config, delegate: box, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { cont in
            box.cont = cont
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.copyItem(at: location, to: dest)
            tmpCopy = dest
            if let response = downloadTask.response {
                cont?.resume(returning: (dest, response))
            } else {
                cont?.resume(throwing: ModelError.incomplete)
            }
        } catch {
            cont?.resume(throwing: error)
        }
        cont = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            cont?.resume(throwing: error)
            cont = nil
        }
    }
}
