import Foundation
import Network

enum BrainMode: String, CaseIterable, Identifiable {
    case auto
    case cloudflare
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто (сеть → Cloudflare, иначе локально)"
        case .cloudflare: return "Только Cloudflare"
        case .local: return "Только локальная модель"
        }
    }
}

@MainActor
final class BrainSettings: ObservableObject {
    static let shared = BrainSettings()

    /// Public Worker URL only. Cloudflare API token never lives in the app.
    static let defaultWorkerURL = ""

    @Published var mode: BrainMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "brain.mode") }
    }

    @Published var workerURL: String {
        didSet { UserDefaults.standard.set(workerURL, forKey: "brain.workerURL") }
    }

    private let monitor = NWPathMonitor()
    private(set) var pathSatisfied: Bool = true

    private init() {
        let raw = UserDefaults.standard.string(forKey: "brain.mode") ?? BrainMode.auto.rawValue
        self.mode = BrainMode(rawValue: raw) ?? .auto
        let stored = UserDefaults.standard.string(forKey: "brain.workerURL") ?? ""
        self.workerURL = stored.isEmpty ? Self.defaultWorkerURL : stored
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.pathSatisfied = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "brain.path"))
    }

    var isOnline: Bool { pathSatisfied }

    func resolvedWorkerURL() -> URL? {
        URL(string: workerURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
