import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

// Define a global actor for WhisperEngine
@globalActor
public actor WhisperActor { // Made public
    public static let shared = WhisperActor() // Made public
}

// Thin Swift wrapper around whisper.cpp for one-off transcription jobs.
public enum WhisperError: Error, LocalizedError {
    case modelLoadFailed
    case audioFileReadFailed
    case audioFormatError
    case encodeFailed(status: Int32)
    case transcriptionAttemptWhileNotActive
    case transcriptionInterrupted
    case emptyAudio

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "Не удалось загрузить Whisper. Скачайте ASR ещё раз."
        case .audioFileReadFailed: return "Не удалось прочитать запись."
        case .audioFormatError: return "Неподдерживаемый формат аудио."
        case .encodeFailed(let s): return "whisper_full статус \(s)"
        case .transcriptionAttemptWhileNotActive: return "Расшифровка прервана (приложение не активно)."
        case .transcriptionInterrupted: return "Расшифровка прервана."
        case .emptyAudio: return "Пустой файл записи."
        }
    }
}

@WhisperActor // Apply the actor to the class
public final class WhisperEngine { // Made public

    // MARK: – Singleton
    public static let shared = WhisperEngine()

    // MARK: – Private Properties
    private var modelURL: URL?
    private var useTurboDTW = false
    private let whisperLanguage: NSString = "ru"
    private var ctx: OpaquePointer?
    // Removed local state flags, will use WhisperStateManager
    // private var isTranscriptionInProgress = false
    // private var isReleasingContext = false
    private var pauseRequested = false
#if canImport(UIKit)
    // State isolated to MainActor
    @MainActor private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
#else
    private var backgroundTask: Any? = nil // Placeholder for non-UIKit
#endif
    
    // Whisper C API constants
    private let WHISPER_SAMPLE_RATE: Int32 = 16000


    // MARK: – Lifecycle
    private init() {
        registerAppLifecycleNotifications()
    }

    public func ensureLoaded(from url: URL, turboDTW: Bool) throws {
        if ctx != nil, modelURL == url { return }
        performReleaseActionsInternal()
        modelURL = url
        useTurboDTW = turboDTW
        try setupContext()
    }

    public func unloadModel() {
        performReleaseActionsInternal()
        modelURL = nil
    }

    deinit {
        if let c = ctx { whisper_free(c) }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: – Public Methods

    /// Transcribes an audio file, processing it in chunks and providing progress updates.
    public func transcribe(audioFileURL: URL, progressHandler: @escaping (Double) -> Void) async throws -> (text: String, words: [WordStamp]) { // Made public
        // Check using state manager if a transcription is already in progress by another call
        // This specific check might be redundant if calls are serialized by RecorderViewModel,
        // but good for robustness if WhisperEngine could be called from elsewhere.
        let currentlyTranscribing = await MainActor.run { WhisperStateManager.shared.isTranscribing }
        guard !currentlyTranscribing else {
            Foundation.NSLog("WhisperEngine: Transcription already in progress (checked via StateManager).")
            return ("", [])
        }

        await WhisperStateManager.shared.setIsTranscribing(true) // Now awaits an async func
        pauseRequested = false
        
        // Begin background task (method is on WhisperActor, hops internally)
        await self.beginBackgroundTask()

        // Defer cleanup *except* for endBackgroundTask
        defer {
            Task {
                await WhisperStateManager.shared.setIsTranscribing(false)
            }
        }

        // Wrap the main logic in do-catch to ensure endBackgroundTask is called
        do {
            if ctx == nil {
                Foundation.NSLog("WhisperEngine: Context is nil in transcribe(audioFileURL:). Attempting to set up context.")
                try setupContext()
            }
            guard ctx != nil else {
                await self.endBackgroundTask()
                throw WhisperError.modelLoadFailed
            }

            let audioFile = try AVAudioFile(forReading: audioFileURL)
            let fileFormat = audioFile.processingFormat
            let totalFrames = AVAudioFramePosition(audioFile.length)
            if totalFrames <= 0 {
                await self.endBackgroundTask()
                throw WhisperError.emptyAudio
            }
            let chunkDurationSeconds: TimeInterval = 30.0
            let framesPerChunk = AVAudioFrameCount(chunkDurationSeconds * fileFormat.sampleRate)
            var currentPosition: AVAudioFramePosition = 0
            var allWords: [WordStamp] = []
            // var fullText = "" // This will be reconstructed from allWords at the end.
            var accumulatedOffsetSeconds: Double = 0.0

            while currentPosition < totalFrames {
                if pauseRequested {
                    Foundation.NSLog("WhisperEngine: Pause requested during chunk processing. Aborting.")
                    await self.endBackgroundTask() // End task before throwing
                    throw WhisperError.transcriptionInterrupted
                }

                let framesToRead = min(framesPerChunk, AVAudioFrameCount(totalFrames - currentPosition))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: framesToRead) else {
                    await self.endBackgroundTask()
                    throw WhisperError.audioFileReadFailed
                }

                do {
                    audioFile.framePosition = currentPosition
                    try audioFile.read(into: buffer, frameCount: framesToRead)
                } catch {
                    Foundation.NSLog("WhisperEngine: Failed to read audio chunk: \(error)")
                    await self.endBackgroundTask()
                    throw WhisperError.audioFileReadFailed
                }

                let samples = try Self.mono16k(buffer: buffer, sourceFormat: fileFormat)

                let (_, chunkWords) = try await transcribe(samples: samples)

                let adjustedWords = chunkWords.map {
                    WordStamp(word: $0.word, start: $0.start + accumulatedOffsetSeconds, end: $0.end + accumulatedOffsetSeconds)
                }
                allWords.append(contentsOf: adjustedWords)
                // The 'fullText' is no longer built by concatenating chunkText here.
                // It will be reconstructed from 'allWords' after the loop.
                
                currentPosition += AVAudioFramePosition(framesToRead)
                accumulatedOffsetSeconds += Double(framesToRead) / fileFormat.sampleRate
                
                let progress = Double(currentPosition) / Double(totalFrames)
                progressHandler(progress)
            }
            
            // Reconstruct the full text string from the allWords array with corrected spacing.
            var newConstructedText = ""
            if let firstWord = allWords.first {
                newConstructedText = firstWord.word
                for i in 1..<allWords.count {
                    let currentWordString = allWords[i].word
                    
                    // Define punctuation marks that should attach to the preceding word.
                    let noSpaceBeforePunctuation: Set<String> = [".", ",", "?", "!", ";", ":"]
                    // Define common contraction suffixes.
                    let contractionSuffixes: Set<String> = ["'m", "'re", "'s", "'ll", "'ve", "'d", "n't"]

                    if noSpaceBeforePunctuation.contains(currentWordString) ||
                       contractionSuffixes.contains(currentWordString.lowercased()) ||
                       (currentWordString.count > 0 && currentWordString.first == "'") { // Catches general cases like 's, 't
                        newConstructedText += currentWordString
                    } else {
                        newConstructedText += " " + currentWordString
                    }
                }
            }
            
            Foundation.NSLog("WhisperEngine: Transcription completed. chars=\(newConstructedText.count) words=\(allWords.count)")
            await self.endBackgroundTask()
            return (newConstructedText, allWords)
        } catch {
            await self.endBackgroundTask() // End task on any caught error
            throw error
        }
    }


    /// Explicitly free the heavy Whisper context so GPU/CPU memory is released.
    public func release() { // Made public
        // This function itself runs on WhisperActor.
        // We need to hop to MainActor to check and set WhisperStateManager's state.
        Task { @MainActor in
            guard !WhisperStateManager.shared.isReleasingContext else {
                Foundation.NSLog("WhisperEngine: Release already in progress (checked via StateManager).")
                return
            }
            Foundation.NSLog("WhisperEngine: Attempting to release context.")
            await WhisperStateManager.shared.setIsReleasingContext(true)

            // The actual whisper_free must happen back on the WhisperActor
            // because 'ctx' is isolated to WhisperActor.
            // We can't directly call whisper_free from MainActor.
            // So, we do the actual free operation on the WhisperActor after setting the flag.
            
            // Correct way to call an instance method on its own actor:
            // No need for WhisperActor.shared if performReleaseActionsInternal is part of this instance.
            await self.performReleaseActionsInternal() // Call the internal, actor-isolated release

            // Clear the flag on MainActor after release actions are done.
            await WhisperStateManager.shared.setIsReleasingContext(false) // Now awaits an async func
            Foundation.NSLog("WhisperEngine: Finished releasing context state update.")
        }
    }

    // Renamed to avoid confusion and make its actor isolation clear
    private func performReleaseActionsInternal() {
        // This runs on WhisperActor (because 'release' calls it via 'self' from within a Task that hops to MainActor then calls back to 'self' which is on WhisperActor)
        // Or more simply, 'release' is an instance method, so 'self.perform...' is on the instance's actor.
        Foundation.NSLog("WhisperEngine: performReleaseActionsInternal on WhisperActor.")
        if let c = ctx {
            Foundation.NSLog("WhisperEngine: Calling whisper_free on WhisperActor.")
            whisper_free(c)
            ctx = nil
        } else {
            Foundation.NSLog("WhisperEngine: Context already nil on WhisperActor, no need to release.")
        }
        Foundation.NSLog("WhisperEngine: performReleaseActions completed on WhisperActor.")
    }
    
    // Removed canAcceptNewJob() as this logic is now in WhisperStateManager

    // MARK: – Private Helper Methods

    private static func mono16k(buffer: AVAudioPCMBuffer, sourceFormat: AVAudioFormat) throws -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { throw WhisperError.audioFileReadFailed }
        let n = Int(buffer.frameLength)
        let src = Array(UnsafeBufferPointer(start: channel, count: n))
        let rate = sourceFormat.sampleRate
        if abs(rate - 16000) < 1 {
            if sourceFormat.channelCount == 1 { return src }
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: outFormat) else {
            throw WhisperError.audioFormatError
        }
        let ratio = 16000.0 / rate
        let outFrames = AVAudioFrameCount((Double(n) * ratio).rounded(.up) + 16)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outFrames) else {
            throw WhisperError.audioFormatError
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: outBuf, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        guard let outCh = outBuf.floatChannelData?[0] else { throw WhisperError.audioFileReadFailed }
        return Array(UnsafeBufferPointer(start: outCh, count: Int(outBuf.frameLength)))
    }

    /// Transcribe 16-kHz mono PCM samples and return text and word-level stamps. (Made private)
    private func transcribe(samples pcm: [Float]) async throws -> (text: String, words: [WordStamp]) {
        if ctx == nil {
            Foundation.NSLog("WhisperEngine: Context is nil in private transcribe(samples:). Attempting to set up context.")
            try setupContext()
        }
        guard let currentCtx = ctx else {
            throw WhisperError.modelLoadFailed
        }

        if pauseRequested {
            Foundation.NSLog("WhisperEngine: Pause requested before whisper_full. Aborting.")
            throw WhisperError.transcriptionInterrupted
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads        = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1)))
        params.print_progress   = false
        params.print_realtime   = false
        params.print_timestamps = true
        params.token_timestamps = true
        params.max_len          = 1
        params.split_on_word    = true
        params.suppress_blank   = true
        params.temperature_inc  = 0.2
        params.entropy_thold    = 2.8
        params.logprob_thold    = -1.0
        params.no_speech_thold  = 0.5
        params.language         = whisperLanguage.utf8String
        // params.translate        = false

        let status = pcm.withUnsafeBufferPointer { buf in
            whisper_full(currentCtx, params, buf.baseAddress!, Int32(buf.count))
        }
        guard status == 0 else {
            Foundation.NSLog("WhisperEngine: whisper_full failed with status \(status).")
            throw WhisperError.encodeFailed(status: status)
        }

        var text = ""
        var words: [WordStamp] = []

        let nSegments = whisper_full_n_segments(currentCtx)
        for i in 0..<nSegments {
            if let cStr = whisper_full_get_segment_text(currentCtx, i) {
                text += String(cString: cStr)
            }

            let nTokens = whisper_full_n_tokens(currentCtx, i)
            for j in 0..<nTokens {
                let tokenData = whisper_full_get_token_data(currentCtx, i, j)
                if tokenData.id >= whisper_token_eot(currentCtx) { continue }
                
                guard let tCStr = whisper_full_get_token_text(currentCtx, i, j) else { continue }
                let tokText = String(cString: tCStr)
                
                let cleanedTokText = tokText.replacingOccurrences(of: #"(\[[^\]]+\]|\([^)]+\))"#, with: "", options: .regularExpression)
                                           .trimmingCharacters(in: .whitespacesAndNewlines)

                if cleanedTokText.isEmpty || cleanedTokText.contains("-->") { continue }

                let startSec = Double(tokenData.t0) * 0.01
                let endSec   = Double(tokenData.t1) * 0.01
                words.append(WordStamp(word: cleanedTokText, start: startSec, end: endSec))
            }
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), words)
    }

    private func setupContext() throws {
        if ctx != nil {
            Foundation.NSLog("WhisperEngine: Context already exists.")
            return
        }
        guard let modelURL else {
            throw WhisperError.modelLoadFailed
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            Foundation.NSLog("WhisperEngine: model file missing at \(modelURL.path)")
            throw WhisperError.modelLoadFailed
        }
        Foundation.NSLog("WhisperEngine: Setting up context from \(modelURL.path)")
        var cparams = whisper_context_default_params()
        if useTurboDTW {
            cparams.dtw_token_timestamps = true
            cparams.dtw_aheads_preset = WHISPER_AHEADS_LARGE_V3_TURBO
        } else {
            cparams.dtw_token_timestamps = false
        }

        let modelPath = modelURL.path
        func load(gpu: Bool) -> OpaquePointer? {
            cparams.use_gpu = gpu
            return modelPath.withCString { ptr in
                whisper_init_from_file_with_params(ptr, cparams)
            }
        }

        if let gpuCtx = load(gpu: true) {
            ctx = gpuCtx
            Foundation.NSLog("WhisperEngine: loaded with GPU/Metal")
            return
        }
        Foundation.NSLog("WhisperEngine: GPU init failed, retrying CPU")
        if let cpuCtx = load(gpu: false) {
            ctx = cpuCtx
            Foundation.NSLog("WhisperEngine: loaded with CPU")
            return
        }
        ctx = nil
        throw WhisperError.modelLoadFailed
    }

    // MARK: - Background Task Management (Methods on WhisperActor, hop internally)
#if canImport(UIKit)
    private func registerAppLifecycleNotifications() {
        // Run setup on MainActor as it involves NotificationCenter which often interacts with UI elements
        Task { @MainActor in
            NotificationCenter.default.addObserver(self, selector: #selector(handleAppWillResignActive),
                                                   name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidBecomeActive),
                                                   name: UIApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidEnterBackground),
                                                   name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleAppWillEnterForeground),
                                                   name: UIApplication.willEnterForegroundNotification, object: nil)
            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main) { [weak self] _ in
                    // Hop to WhisperActor to handle memory warning state changes
                    Task { await self?.handleMemoryWarning() }
            }
        }
    }
    
    // These @objc methods are called by NotificationCenter on the main thread.
    // They need to hop to the WhisperActor to modify its state.
    @objc private func handleAppWillResignActive() {
        Task { await actorHandleAppWillResignActive() }
    }
    @objc private func handleAppDidBecomeActive() {
        Task { await actorHandleAppDidBecomeActive() }
    }
    @objc private func handleAppDidEnterBackground() {
        Task { await actorHandleAppDidEnterBackground() }
    }
    @objc private func handleAppWillEnterForeground() {
        Task { await actorHandleAppWillEnterForeground() }
    }

    // These methods run on WhisperActor
    private func actorHandleAppWillResignActive() async {
        Foundation.NSLog("WhisperEngine: App will resign active.")
        let transcribing = await MainActor.run { WhisperStateManager.shared.isTranscribing }
        if transcribing {
            Foundation.NSLog("WhisperEngine: Transcription in progress, requesting pause.")
            let isBgTaskActive = await self.isBackgroundTaskActive() // Call method on WhisperActor
            if !isBgTaskActive {
                 pauseRequested = true
            }
        }
    }

    private func actorHandleAppDidBecomeActive() async {
        Foundation.NSLog("WhisperEngine: App did become active.")
        // let transcribing = await MainActor.run { WhisperStateManager.shared.isTranscribing } // Example if needed
        let isBgTaskActive = await self.isBackgroundTaskActive() // Call method on WhisperActor
        if pauseRequested && !isBgTaskActive {
            // Resuming is complex, safer to let it fail if pause was requested.
        }
    }

    private func actorHandleAppDidEnterBackground() async {
        Foundation.NSLog("WhisperEngine: App did enter background.")
        let transcribing = await MainActor.run { WhisperStateManager.shared.isTranscribing }
        if transcribing {
            Foundation.NSLog("WhisperEngine: Transcription in progress while entering background. Requesting pause forcefully.")
            pauseRequested = true
        } else {
             await self.endBackgroundTask() // Call method on WhisperActor
        }
    }

    private func actorHandleAppWillEnterForeground() async {
        Foundation.NSLog("WhisperEngine: App will enter foreground.")
    }

    private func handleMemoryWarning() async { // Runs on WhisperActor, made async
        Foundation.NSLog("WhisperEngine: Memory warning received.")
        let transcribing = await MainActor.run { WhisperStateManager.shared.isTranscribing }
        if transcribing {
            Foundation.NSLog("WhisperEngine: Transcription in progress during memory warning. Requesting pause.")
            pauseRequested = true
        }
        release() // This will now correctly handle actor hopping for state manager
    }

    // Method runs on WhisperActor, hops to MainActor internally
    private func beginBackgroundTask() async {
        await MainActor.run {
            if self.backgroundTask != .invalid { return }
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WhisperTranscription") { [weak self] in
                Foundation.NSLog("WhisperEngine: Background task expired.")
                // Hop to WhisperActor to handle expiration logic
                Task { await self?.actorHandleBackgroundTaskExpiration() }
            }
            Foundation.NSLog("WhisperEngine: Began background task: \(self.backgroundTask)")
        }
    }

    // Method runs on WhisperActor, hops to MainActor internally if needed
    private func actorHandleBackgroundTaskExpiration() async {
        let transcribing = await MainActor.run { WhisperStateManager.shared.isTranscribing }
        if transcribing {
            Foundation.NSLog("WhisperEngine: Background task expired during transcription. Requesting pause.")
            pauseRequested = true
        }
        await self.endBackgroundTask() // Call method on WhisperActor
    }

    // Method runs on WhisperActor, hops to MainActor internally
    private func endBackgroundTask() async {
        await MainActor.run {
            if self.backgroundTask != .invalid {
                Foundation.NSLog("WhisperEngine: Ending background task: \(self.backgroundTask)")
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
    }
    
    // Method runs on WhisperActor, hops to MainActor internally
    private func isBackgroundTaskActive() async -> Bool {
        await MainActor.run {
            return self.backgroundTask != .invalid
        }
    }

#else // Fallback for non-UIKit platforms
    private func registerAppLifecycleNotifications() { /* No-op */ }
    private func beginBackgroundTask() async { /* No-op */ }
    private func endBackgroundTask() async { /* No-op */ }
    private func isBackgroundTaskActive() async -> Bool { return false }
#endif
}

// Word-level timestamp from whisper.cpp
// This is now the canonical definition.
public struct WordStamp: Codable, Hashable, Sendable {
    public let word: String
    public let start: Double // seconds (TimeInterval is a typealias for Double)
    public let end: Double   // seconds

    public init(word: String, start: Double, end: Double) {
        self.word = word
        self.start = start
        self.end = end
    }
}
