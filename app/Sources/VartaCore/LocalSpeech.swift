import AVFoundation
import Foundation
import WhisperKit

/// Speech-to-text with Whisper, fully on this Mac (WhisperKit: Core ML on the Neural Engine).
/// No audio leaves the machine and no key is needed.
///
/// Push-to-talk records the whole utterance, then transcribes it once on release. The prompt
/// lists names from this Mac (apps, sites) so Whisper spells them the way the router expects.
public final class LocalSpeech: @unchecked Sendable {
    /// Override with VARTA_WHISPER_MODEL (any variant in argmaxinc/whisperkit-coreml).
    public static var model = ProcessInfo.processInfo.environment["VARTA_WHISPER_MODEL"] ?? "openai_whisper-large-v3-v20240930_turbo"
    public static var language = ProcessInfo.processInfo.environment["VARTA_WHISPER_LANGUAGE"] ?? "en"
    public static let modelsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".varta/models")
    public static let sampleRate = 16_000.0

    /// VARTA_WHISPER_ENCODER=ane|gpu picks where the audio encoder runs (it dominates latency).
    static var computeOptions: ModelComputeOptions? {
        switch ProcessInfo.processInfo.environment["VARTA_WHISPER_ENCODER"] {
        case "ane": return ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
        case "gpu": return ModelComputeOptions(melCompute: .cpuAndGPU, audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndNeuralEngine)
        default: return nil
        }
    }

    private var pipe: WhisperKit?
    private var promptTokens: [Int]?
    private let lock = NSLock()

    public init() {}

    public var isReady: Bool { lock.withLock { pipe != nil } }

    /// Where a downloaded model lives, if it's already here.
    public static func localModelFolder(_ variant: String = model) -> URL? {
        let base = modelsDir.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        let exact = base.appendingPathComponent(variant)
        if FileManager.default.fileExists(atPath: exact.appendingPathComponent("AudioEncoder.mlmodelc").path) { return exact }
        let alt = base.appendingPathComponent("openai_whisper-\(variant)")
        return FileManager.default.fileExists(atPath: alt.appendingPathComponent("AudioEncoder.mlmodelc").path) ? alt : nil
    }

    /// Download the model if needed (once, to ~/.varta/models), then load and prewarm it.
    /// The first load on a Mac also compiles the model for the Neural Engine, which can take a minute;
    /// later launches reuse that and are quick.
    public func prepare(vocabulary: [String] = [], preparation: ((SpeechPreparation) -> Void)? = nil,
                        progress: ((String) -> Void)? = nil) async throws {
        func report(_ state: SpeechPreparation) {
            preparation?(state)
            progress?(state.status)
        }
        if isReady { report(.ready); return }
        report(.preparing)
        var folder = LocalSpeech.localModelFolder()
        if folder == nil {
            report(.downloading(nil))
            folder = try await WhisperKit.download(variant: LocalSpeech.model, downloadBase: LocalSpeech.modelsDir) { p in
                let state = SpeechPreparation.downloading(p.fractionCompleted)
                preparation?(state)
                progress?(state.status)
            }
        }
        report(.loading)
        let config = WhisperKitConfig(model: LocalSpeech.model, downloadBase: LocalSpeech.modelsDir, modelFolder: folder!.path,
                                      computeOptions: LocalSpeech.computeOptions,
                                      verbose: false, logLevel: .error, prewarm: true, load: true, download: false)
        let kit = try await WhisperKit(config)
        var tokens: [Int]?
        if let tokenizer = kit.tokenizer, !vocabulary.isEmpty {
            // Whisper's prompt window is small; keep the most useful names.
            let prompt = vocabulary.prefix(60).joined(separator: ", ")
            tokens = Array(tokenizer.encode(text: " " + prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }.prefix(200))
        }
        lock.withLock {
            pipe = kit
            promptTokens = tokens
        }
        report(.ready)
    }

    /// Transcribe 16 kHz mono float samples.
    public func transcribe(_ samples: [Float]) async throws -> String {
        guard let kit = lock.withLock({ pipe }) else { throw JevError(description: "The speech model isn't loaded yet") }
        guard samples.count > Int(LocalSpeech.sampleRate * 0.2) else { return "" }
        // Short commands ("launch cursor" is under a second) need a little trailing silence to decode reliably.
        let minimum = Int(LocalSpeech.sampleRate * 1.5)
        let audio = samples.count < minimum ? samples + [Float](repeating: 0, count: minimum - samples.count) : samples
        // windowClipTime 0: the default trims the last second of the window, which swallows short commands.
        let options = DecodingOptions(language: LocalSpeech.language, temperatureFallbackCount: 2, usePrefillPrompt: true,
                                      detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: true,
                                      windowClipTime: 0, promptTokens: lock.withLock { promptTokens }, suppressBlank: true)
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        return LocalSpeech.clean(results.map(\.text).joined(separator: " "))
    }

    /// Transcribe an audio file (any format AVFoundation reads); used by `varta-cli transcribe`.
    public func transcribe(file: String) async throws -> String {
        try await transcribe(AudioProcessor.loadAudioAsFloatArray(fromPath: file))
    }

    /// Whisper sometimes returns bracketed non-speech tags or trailing punctuation the router doesn't need.
    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".!?".contains(last) { t.removeLast() }
        return t
    }
}

/// Collects microphone audio as 16 kHz mono floats while push-to-talk is held.
public final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: LocalSpeech.sampleRate, channels: 1, interleaved: false)!
    private var samples: [Float] = []
    private let lock = NSLock()
    public var onLevel: ((Float) -> Void)?

    public init() {}

    public func start() throws {
        stop()
        lock.withLock { samples = [] }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: format, to: target)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let converted = self.convert(buffer)
            self.lock.withLock { self.samples += converted }
            guard let ch = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            self.onLevel?(min(1, sqrt(sum / Float(max(n, 1))) * 12))
        }
        engine.prepare()
        try engine.start()
    }

    /// Everything recorded so far, without stopping (for passes while the key is held).
    public func snapshot() -> [Float] { lock.withLock { samples } }

    /// Stop and return everything recorded.
    public func finish() -> [Float] {
        stop()
        return lock.withLock { samples }
    }

    public func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, let ch = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }
}


/// Push-to-talk transcription that hides some of Whisper's latency: while the key is held it runs
/// Whisper at each pause in speech (these are also the live transcript). On release, if a pass already
/// covers everything that was said, its text is used (at once, or when it finishes); otherwise one
/// last pass runs on the full recording.
public final class HoldTranscriber: @unchecked Sendable {
    public let speech: LocalSpeech
    public var pause = 0.25
    private var passTask: Task<Void, Never>?
    private var latest: (covered: Int, text: String)?
    private var inFlight: Task<(Int, String)?, Never>?
    private let lock = NSLock()
    public private(set) var lastSource = ""

    public init(speech: LocalSpeech) { self.speech = speech }

    /// `snapshot` returns the audio recorded so far (16 kHz mono).
    ///
    /// A pass starts only at a pause (≥ `pause` s of silence after new speech) and never while another
    /// is running. Passes during speech would queue on the Neural Engine and delay the one that matters;
    /// a pass started at a pause covers everything said so far, so it is usually the final one.
    public func begin(snapshot: @escaping @Sendable () -> [Float], onPartial: @escaping @Sendable (String) -> Void) {
        cancel()
        lock.withLock { latest = nil }
        let pause = self.pause
        passTask = Task.detached(priority: .userInitiated) { [weak self] in
            var coveredSpeech = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self else { return }
                let audio = snapshot()
                guard let lastSpeech = HoldTranscriber.lastSpeechSample(audio), lastSpeech > coveredSpeech,
                      audio.count - lastSpeech >= Int(LocalSpeech.sampleRate * pause) else { continue }
                coveredSpeech = lastSpeech
                let task = Task { () -> (Int, String)? in
                    guard let text = try? await self.speech.transcribe(audio) else { return nil }
                    return (audio.count, text)
                }
                self.lock.withLock { self.inFlight = task }
                if let (covered, text) = await task.value, !Task.isCancelled {
                    self.lock.withLock { self.latest = (covered, text) }
                    if !text.isEmpty { onPartial(text) }
                }
            }
        }
    }

    /// Final transcript for everything recorded.
    public func end(_ samples: [Float]) async -> String {
        passTask?.cancel()
        guard let lastSpeech = HoldTranscriber.lastSpeechSample(samples) else {
            cancel()
            lastSource = "silence"
            return ""
        }
        let needed = min(samples.count, lastSpeech + Int(LocalSpeech.sampleRate * 0.15))
        if let done = lock.withLock({ latest }), done.covered >= needed {
            lastSource = "live pass (instant)"
            cancel()
            return done.text
        }
        // A pass that started after the speech ended will be final; wait for it rather than starting another.
        if let pending = lock.withLock({ inFlight }), let (covered, text) = await pending.value, covered >= needed {
            lastSource = "live pass (waited)"
            return text
        }
        lastSource = "final pass"
        return (try? await speech.transcribe(samples)) ?? ""
    }

    public func cancel() {
        passTask?.cancel()
        passTask = nil
        lock.withLock { inFlight = nil }
    }

    /// Index just past the last 50 ms window with speech-level energy, or nil if it's all silence.
    public static func lastSpeechSample(_ s: [Float]) -> Int? {
        let window = Int(LocalSpeech.sampleRate * 0.05)
        guard s.count >= window else { return nil }
        var rms: [Float] = []
        var i = 0
        while i + window <= s.count {
            var sum: Float = 0
            for j in i..<(i + window) { sum += s[j] * s[j] }
            rms.append(sqrt(sum / Float(window)))
            i += window
        }
        let peak = rms.max() ?? 0
        guard peak > 0.01 else { return nil }
        let threshold = max(0.008, peak * 0.12)
        guard let last = rms.lastIndex(where: { $0 > threshold }) else { return nil }
        return (last + 1) * window
    }
}
