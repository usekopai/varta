import AVFoundation
import VartaCore
import SwiftUI

/// The push-to-talk shortcut as Setup shows it; the app owns registration.
final class HotkeyState: ObservableObject {
    @Published var display = Shortcut.current.display
    @Published var taken = false
    @Published var conflict: String?
    @Published var recording = false { didSet { onRecording?(recording) } }
    var onRecording: ((Bool) -> Void)?
}

/// Speech model state, shown in Setup and the notch.
final class SpeechState: ObservableObject {
    @Published var status = "Preparing the speech model…"
    @Published var ready = false
}

/// First-run setup: the permissions Varta needs, the local speech model, and API keys.
struct SetupView: View {
    @ObservedObject var speech: SpeechState
    @ObservedObject var hotkey: HotkeyState
    @State private var monitor: Any?
    @State private var hint = ""
    @State private var tick = 0
    @State private var keys: [KeyName: String] = [:]
    @State private var saved = false
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    static var needsSetup: Bool {
        !Credentials.has(.typesafe) || !Permissions.accessibility || AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up Varta").font(.title2.weight(.semibold))
                Text("Hold ⌥Space, say what you want, let go.").foregroundStyle(.secondary)
                Text("Version \(Varta.version)").font(.caption).foregroundStyle(.tertiary)
            }

            GroupBox("Hotkey") {
                HStack {
                    Image(systemName: hotkey.taken || hotkey.conflict != nil ? "exclamationmark.triangle.fill" : "keyboard")
                        .foregroundStyle(hotkey.taken || hotkey.conflict != nil ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(hotkey.recording ? "Press the new shortcut…" : "Hold \(hotkey.display) to talk")
                        Text(hotkey.recording ? (hint.isEmpty ? "Use ⌃, ⌥ or ⌘ with a key, or a function key. Esc cancels." : hint)
                             : hotkey.taken ? "\(hotkey.display) couldn't be registered. Choose a different shortcut."
                             : hotkey.conflict.map { "\($0) uses \(hotkey.display) by default. If it opens \($0), change one of them." }
                             ?? "A quick tap works too: tap, speak, tap again.")
                            .font(.caption).foregroundStyle((hotkey.taken || hotkey.conflict != nil) && !hotkey.recording ? .orange : .secondary)
                    }
                    Spacer()
                    Button(hotkey.recording ? "Cancel" : "Change…") { hotkey.recording ? stopRecording() : startRecording() }
                }
                .padding(6)
            }

            GroupBox("Speech") {
                HStack {
                    Image(systemName: speech.ready ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(speech.ready ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Whisper, on this Mac")
                        Text(speech.ready ? "Ready. Your voice never leaves this Mac." : speech.status)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(6)
            }

            GroupBox("Permissions") {
                VStack(alignment: .leading, spacing: 10) {
                    row("Microphone", "hear your command", AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                        "Privacy_Microphone") { Task { _ = await AVCaptureDevice.requestAccess(for: .audio) } }
                    row("Accessibility", "press buttons and menu items in other apps", Permissions.accessibility,
                        "Privacy_Accessibility") { Permissions.requestAccessibility() }
                    if Features.computerUse {
                        row("Screen Recording", "only for computer use: let it see the app it's working in", Permissions.screenRecording,
                            "Privacy_ScreenCapture") { Permissions.requestScreenRecording() }
                    }
                    Text("Automation (Spotify, Chrome) is asked the first time a command needs it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(6)
                .id(tick)
            }

            GroupBox("Keys") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(KeyName.allCases.filter { Features.computerUse || $0 == .typesafe }, id: \.self) { k in
                        HStack {
                            Text(k.label).frame(width: 230, alignment: .leading)
                            SecureField(Credentials.has(k) ? "saved" : (k == .typesafe ? "required" : "optional"),
                                        text: Binding(get: { keys[k] ?? "" }, set: { keys[k] = $0; saved = false }))
                        }
                    }
                    Text("Stored in your login Keychain. Jev is the only key you need.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        if saved { Text("Saved").foregroundStyle(.green) }
                        Button("Save keys") {
                            for (k, v) in keys where !v.trimmingCharacters(in: .whitespaces).isEmpty {
                                Credentials.set(k, v.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                            keys = [:]
                            saved = true
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(6)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 520, height: 650)
        .onDisappear { stopRecording() }
        .onReceive(timer) { _ in tick += 1 } // permissions change in System Settings; re-read them
    }

    private func startRecording() {
        hint = ""
        hotkey.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(Keys.escape) && event.modifierFlags.intersection([.control, .option, .command]).isEmpty {
                stopRecording()
                return nil
            }
            guard let s = Shortcut(event: event) else {
                hint = "That needs ⌃, ⌥ or ⌘ as well (or use a function key)."
                return nil
            }
            stopRecording()
            Shortcut.current = s // the app re-registers and reports whether it's taken
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if hotkey.recording { hotkey.recording = false }
    }

    @ViewBuilder
    private func row(_ name: String, _ why: String, _ ok: Bool, _ pane: String, request: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok {
                Button("Allow") {
                    request()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        }
    }
}
