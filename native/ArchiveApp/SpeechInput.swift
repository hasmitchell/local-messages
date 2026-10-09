@preconcurrency import AVFoundation
import Speech

/// Voice input with Apple's on-device speech model (macOS 26): the microphone
/// streams into SpeechAnalyzer, and its words reach the composer as they are
/// recognised. Words still being decided arrive through `onVolatile` (shown as
/// marked text, replaced each time); settled ones through `onFinal`. Audio and
/// text stay on this Mac.
@available(macOS 26.0, *)
@MainActor final class OnDeviceDictation {
    enum Failure: LocalizedError {
        case microphoneDenied, unsupportedLanguage, noMicrophone, modelUnavailable
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "Allow the microphone for Local Messages in System Settings › Privacy & Security › Microphone."
            case .unsupportedLanguage: "The on-device speech model does not support your language yet. Using macOS Dictation instead."
            case .noMicrophone: "No microphone is available."
            case .modelUnavailable: "The on-device speech model could not start. Using macOS Dictation instead."
            }
        }
    }

    var onVolatile: (String) -> Void = { _ in }
    var onFinal: (String) -> Void = { _ in }
    /// A short status while preparing (permission, one-time model download), nil once listening.
    var onStatus: (String?) -> Void = { _ in }
    /// Input level, 0...1, a few times a second.
    var onLevel: (Float) -> Void = { _ in }
    /// The session ended by itself (an error, or the input went away).
    var onEnded: (Error?) -> Void = { _ in }

    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    private var engine: AVAudioEngine?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var levels: Task<Void, Never>?
    private(set) var running = false
    /// True once the microphone is on; before that the session is still preparing.
    private(set) var listening = false

    func start() async throws {
        guard !running else { return }
        running = true
        do { try await begin() }
        // Stopped while preparing: nothing to report, and nothing may be left on.
        catch is CancellationError { await teardown(finish: false) }
        catch { await teardown(finish: false); throw error }
    }
    /// Every await while preparing can outlast a Stop; carry on only if still wanted.
    private func ensureRunning() throws { if !running { throw CancellationError() } }
    /// Status from a session that has been stopped is dropped, so it cannot linger.
    private func status(_ text: String?) { if running { onStatus(text) } }

    private func begin() async throws {
        status("Asking for the microphone…")
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        try ensureRunning()
        guard allowed else { throw Failure.microphoneDenied }
        let transcriber = try await prepareModel()
        try ensureRunning()
        let engine = AVAudioEngine()
        let microphone = engine.inputNode.outputFormat(forBus: 0)
        guard microphone.sampleRate > 0, microphone.channelCount > 0 else { throw Failure.noMicrophone }
        // Held before the tap goes in, so a failure still removes it.
        self.engine = engine
        try await listen(with: transcriber, from: microphone) { tap in
            engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: microphone, block: tap)
            engine.prepare()
            try engine.start()
        }
    }

    /// The model for the user's language, downloaded the first time.
    private func prepareModel() async throws -> SpeechTranscriber {
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        try ensureRunning()
        guard let locale = supported else { throw Failure.unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
        try ensureRunning()
        if let request {
            // Once per app and language. When the system already has the model
            // (it often does) this takes a moment; otherwise it downloads.
            status("Getting Apple’s speech model ready…")
            let watch = Task { @MainActor [weak self, progress = request.progress] in
                while !Task.isCancelled {
                    let percent = Int(progress.fractionCompleted * 100)
                    if percent > 0 && percent < 100 { self?.status("Downloading Apple’s speech model (one time)… \(percent)%") }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            defer { watch.cancel() }
            try await request.downloadAndInstall()
            try ensureRunning()
        }
        return transcriber
    }

    /// Converts audio in `source` format for the model, starts it, and routes
    /// its results. `attach` connects the audio to the returned tap block.
    private func listen(with transcriber: SpeechTranscriber, from source: AVAudioFormat, attach: (@escaping AVAudioNodeTapBlock) throws -> Void) async throws {
        status("Starting…")
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: source)
        try ensureRunning()
        guard let format = best, let converter = BufferConverter(from: source, to: format) else { throw Failure.modelUnavailable }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.prepareToAnalyze(in: format)
        try ensureRunning()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.input = continuation
        results = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal { self?.onFinal(text) } else { self?.onVolatile(text) }
                }
                self?.ended(nil)
            } catch { self?.ended(error) }
        }
        levels = Task { @MainActor [weak self] in
            for await level in levelStream { self?.onLevel(level) }
        }
        try await analyzer.start(inputSequence: stream)
        try ensureRunning()
        try attach(Self.tap(converter: converter, input: continuation, level: levelContinuation))
        listening = true
        status(nil)
    }

    #if ARCHIVE_TESTING
    /// Plays a recording through the same converter, stream and model as the
    /// microphone, then stops as the composer's Stop would.
    func transcribe(file url: URL) async throws {
        running = true
        do {
            let transcriber = try await prepareModel()
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            var feed: AVAudioNodeTapBlock?
            try await listen(with: transcriber, from: format) { feed = $0 }
            while let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096), (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
                feed?(buffer, AVAudioTime(sampleTime: file.framePosition, atRate: format.sampleRate))
                try await Task.sleep(for: .milliseconds(40))
            }
        } catch { await teardown(finish: false); throw error }
        await stop()
    }
    #endif

    /// Stops listening and waits for the last words to be settled.
    func stop() async {
        guard running else { return }
        await teardown(finish: true)
    }

    private func teardown(finish: Bool) async {
        running = false
        listening = false
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        input?.finish(); input = nil
        levels?.cancel(); levels = nil
        if let analyzer {
            if finish { try? await analyzer.finalizeAndFinishThroughEndOfInput() } else { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
        // The results end once the analyzer has finished.
        if finish { await results?.value } else { results?.cancel() }
        results = nil
        onLevel(0)
        onStatus(nil)
    }


    private func ended(_ error: Error?) {
        guard running else { return }
        Task { await teardown(finish: false); onEnded(error) }
    }

    /// Built outside the main actor: the tap runs on the audio thread.
    private nonisolated static func tap(converter: BufferConverter, input: AsyncStream<AnalyzerInput>.Continuation, level: AsyncStream<Float>.Continuation) -> AVAudioNodeTapBlock {
        { buffer, _ in
            level.yield(BufferConverter.level(of: buffer))
            if let converted = converter.convert(buffer) { input.yield(AnalyzerInput(buffer: converted)) }
        }
    }
}

/// Converts microphone buffers to the analyzer's format. Used only from the
/// audio thread's tap, one buffer at a time.
private final class BufferConverter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let format: AVAudioFormat
    init?(from source: AVAudioFormat, to format: AVAudioFormat) {
        self.format = format
        if source == format { converter = nil; return }
        guard let converter = AVAudioConverter(from: source, to: format) else { return nil }
        // Skips priming, so timestamps do not drift from the source.
        converter.primeMethod = .none
        self.converter = converter
    }
    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let source = OneBuffer(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            guard let next = source.take() else { state.pointee = .noDataNow; return nil }
            state.pointee = .haveData
            return next
        }
        return status == .error || output.frameLength == 0 ? nil : output
    }
    /// Hands the converter one buffer, once. The converter calls back on this thread.
    private final class OneBuffer: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? { defer { buffer = nil }; return buffer }
    }
    /// Root-mean-square loudness of the first channel, scaled to roughly 0...1 for speech.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return min(1, rms * 12)
    }
}
