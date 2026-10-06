import AVFoundation
import VartaCore

/// Push-to-talk speech: the microphone plus local Whisper, with passes while the key is held
/// (see HoldTranscriber) so most commands are transcribed by the time you let go.
final class Listener {
    private let speech = LocalSpeech()
    private let recorder = MicRecorder()
    private lazy var hold = HoldTranscriber(speech: speech)

    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)? { didSet { recorder.onLevel = onLevel } }
    var lastSource: String { hold.lastSource }

    var isReady: Bool { speech.isReady }

    static func requestPermissions() async -> String? {
        await AVCaptureDevice.requestAccess(for: .audio) ? nil : "Microphone is off for Varta (System Settings → Privacy & Security)"
    }

    /// Names on this Mac that Whisper should spell the way the router expects.
    static let vocabulary: [String] = {
        var k = MacSources.builtinSites.map(\.1)
        k += MacSources.installedApps.filter { !$0.contains(".") && $0.count > 2 && !MacSources.systemApps.contains($0) }
        return Array(NSOrderedSet(array: k).array as! [String])
    }()

    /// Download (first run) and load the model; call at launch.
    func prepare(progress: @escaping (SpeechPreparation) -> Void) async {
        do {
            try await speech.prepare(vocabulary: Listener.vocabulary, preparation: progress)
        } catch {
            let state = SpeechPreparation.failed(error.localizedDescription)
            progress(state)
            Log.write(state.status)
        }
    }

    func start() throws {
        guard speech.isReady else { throw JevError(description: "Speech is not ready. Check Setup for progress.") }
        try recorder.start()
        let recorder = self.recorder
        hold.begin(snapshot: { recorder.snapshot() }, onPartial: { [weak self] in self?.onPartial?($0) })
    }

    func stop() async -> String { await hold.end(recorder.finish()) }

    func cancel() {
        _ = recorder.finish()
        hold.cancel()
    }
}
