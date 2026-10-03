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
    private(set) var status = "Speech model not loaded"

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
    func prepare(progress: @escaping (String) -> Void) async {
        do {
            try await speech.prepare(vocabulary: Listener.vocabulary) { [weak self] s in
                self?.status = s
                progress(s)
            }
        } catch {
            status = "Speech model failed to load: \(error)"
            progress(status)
            Log.write(status)
        }
    }

    func start() throws {
        guard speech.isReady else { throw JevError(description: status) }
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
