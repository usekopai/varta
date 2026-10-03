import AppKit
import Carbon
import VartaCore
import SwiftUI

/// Hold ⌥Space and speak; release to send. A quick tap toggles instead: tap, speak, tap again.
/// Esc stops a running command. Everything runs in this process: speech, Jev routing, actions.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = NotchModel()
    private let listener = Listener()
    private let speechState = SpeechState()
    private let hotkeyState = HotkeyState()
    private var pipeline: Pipeline!
    private var panel: NotchPanel!
    private var timing: CommandTiming?
    private var agendaWindow: CalendarAgendaWindow?
    private var statusItem: NSStatusItem!
    private var setupWindow: NSWindow?
    private var talkKey: HotKey?
    private var escKey: HotKey?
    private var cancel = CancelFlag()
    private var collapseWork: DispatchWorkItem?
    private var pressedAt = Date.distantPast
    private var toggleMode = false
    private var sawSpaceDown = false
    private var releasePoll: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        let jev = Jev { guard let k = Credentials.get(.typesafe) else { throw JevError(description: "Add a TypeSafe key in Setup") }; return k }
        pipeline = Pipeline(jev: jev)
        // Warm the app and site lists off the main thread so the first command isn't slower.
        DispatchQueue.global(qos: .utility).async { _ = MacSources.installedApps; _ = MacSources.knownSites; _ = Listener.vocabulary }

        panel = NotchPanel(model: model)
        panel.orderFrontRegardless()
        setUpStatusItem()

        listener.onLevel = { [weak self] level in DispatchQueue.main.async { self?.model.level = level } }

        registerTalkKey()
        NotificationCenter.default.addObserver(forName: Shortcut.changed, object: nil, queue: .main) { [weak self] _ in self?.registerTalkKey() }
        // While Setup records a new shortcut, release ours so pressing it doesn't start listening.
        hotkeyState.onRecording = { [weak self] recording in
            if recording { self?.talkKey = nil } else { self?.registerTalkKey() }
        }
        Log.write("launched")
        Task { @MainActor in
            if let problem = await Listener.requestPermissions() { self.show(message: problem, for: 6) }
            if SetupView.needsSetup || self.hotkeyState.taken || (self.hotkeyState.conflict != nil && !UserDefaults.standard.bool(forKey: "SeenHotkeyNote")) {
                UserDefaults.standard.set(true, forKey: "SeenHotkeyNote")
                self.openSetup()
            }
        }
        // Load Whisper in the background. The first run downloads it (~1.5 GB) and compiles it for the Neural Engine.
        let state = speechState, listener = self.listener
        Task.detached(priority: .utility) {
            let t0 = Date()
            await listener.prepare { s in DispatchQueue.main.async { state.status = s } }
            DispatchQueue.main.async { state.ready = listener.isReady }
            Log.write(String(format: "speech model: %@ in %.1f s", listener.isReady ? "ready" : "not ready", Date().timeIntervalSince(t0)))
        }
        // Screens change when an external display is plugged in; keep the panel on the notch.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel = NotchPanel(model: self.model)
            self.panel.orderFrontRegardless()
        }
    }

    // MARK: menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Varta")
        let menu = NSMenu()
        menu.addItem(withTitle: "Hold \(Shortcut.current.display) to talk", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Setup…", action: #selector(openSetup), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Varta", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc func openSetup() {
        if setupWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Varta Setup"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView(speech: speechState, hotkey: hotkeyState))
            w.center()
            setupWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: push-to-talk

    /// Register the chosen shortcut. Carbon refuses one another app already holds; say so and point to Setup.
    private func registerTalkKey() {
        let s = Shortcut.current
        talkKey = nil
        let key = HotKey(keyCode: s.keyCode, modifiers: s.modifiers) { [weak self] pressed in
            pressed ? self?.talkPressed() : self?.talkReleased()
        }
        hotkeyState.display = s.display
        hotkeyState.taken = !key.registered
        hotkeyState.conflict = s.likelyConflict
        statusItem?.menu?.items.first?.title = "Hold \(s.display) to talk"
        if key.registered {
            talkKey = key
            Log.write("hotkey: \(s.display)")
        } else {
            Log.write("hotkey: \(s.display) could not be registered")
            show(message: "\(s.display) couldn't be registered. Pick a new shortcut in Setup (menu bar icon).", for: 6)
        }
    }

    private func talkPressed() {
        if model.phase == .listening {
            if toggleMode { Log.write("hotkey: second tap -> send"); stopListening() }
            return // key repeat while holding
        }
        pressedAt = Date()
        toggleMode = false
        sawSpaceDown = false
        startListening()
        // Carbon doesn't always report the release (e.g. Option let go first), so also watch Space itself.
        releasePoll?.invalidate()
        releasePoll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.model.phase == .listening, !self.toggleMode else { self?.releasePoll?.invalidate(); return }
            let down = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(Shortcut.current.keyCode))
            if down { self.sawSpaceDown = true }
            if !down && self.sawSpaceDown { self.talkReleased() }
        }
    }

    private func talkReleased() {
        guard model.phase == .listening, !toggleMode else { return }
        releasePoll?.invalidate()
        if Date().timeIntervalSince(pressedAt) < 0.35 {
            toggleMode = true
            Log.write("hotkey: quick tap -> toggle mode")
            return
        }
        stopListening()
    }

    private func startListening() {
        guard model.phase != .listening else { return }
        guard listener.isReady else {
            show(message: speechState.status.isEmpty ? "The speech model is still loading" : speechState.status, for: 3)
            return
        }
        // One token covers recording, final transcription, routing and execution. Replacing
        // it invalidates pending transcription and queued UI events from the previous command.
        if let sample = timing?.finish("replaced") { Log.timing(sample) }
        cancel.cancel()
        let flag = CancelFlag()
        cancel = flag
        listener.onPartial = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.cancel === flag, !flag.isSet, self.model.phase == .listening else { return }
                self.model.transcript = text
            }
        }
        collapseWork?.cancel()
        model.reset()
        model.phase = .listening
        do {
            try listener.start()
        } catch {
            show(message: error.localizedDescription, for: 3)
        }
        armEscape()
    }

    private func stopListening() {
        guard model.phase == .listening else { return }
        let measurement = CommandTiming()
        timing = measurement
        releasePoll?.invalidate()
        toggleMode = false
        model.phase = .thinking
        model.status = "Finishing…"
        let heldFor = Date().timeIntervalSince(pressedAt)
        let flag = cancel
        Task { @MainActor in
            guard self.cancel === flag, !flag.isSet else { return }
            let t0 = Date()
            let text = await listener.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            guard self.cancel === flag, !flag.isSet else { return }
            measurement.transcribed(source: listener.lastSource)
            model.level = 0
            Log.write(String(format: "transcript (%@, %.0f ms after release, held %.1f s): \"%@\"", listener.lastSource, Date().timeIntervalSince(t0) * 1000, heldFor, text))
            guard !text.isEmpty else { if let sample = measurement.finish("no_speech") { Log.timing(sample) }; show(message: "Didn't hear anything", for: 1.5); return }
            guard Credentials.has(.typesafe) else { if let sample = measurement.finish("missing_credentials") { Log.timing(sample) }; show(message: "Add your TypeSafe key in Setup (menu bar → Setup…)", for: 5); return }
            model.transcript = text
            model.status = "Understanding…"
            run(text, flag: flag, measurement: measurement)
        }
    }

    private func run(_ text: String, flag: CancelFlag, measurement: CommandTiming) {
        guard cancel === flag, !flag.isSet else { return }
        let pipeline = self.pipeline!
        Task.detached {
            await pipeline.run(text, cancel: flag) { event in
                if let sample = measurement.observe(event) { Log.timing(sample) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.cancel === flag, !flag.isSet else { return }
                    self.handle(event)
                }
            }
        }
    }

    private func armEscape() {
        escKey = HotKey(keyCode: Keys.escape, modifiers: 0) { [weak self] pressed in
            guard pressed, let self else { return }
            if let sample = self.timing?.finish("cancelled") { Log.timing(sample) }
            self.cancel.cancel()
            Task { await self.pipeline?.clearPendingReminder() }
            self.releasePoll?.invalidate()
            self.toggleMode = false
            self.listener.cancel()
            self.show(message: "Stopped", for: 1.5)
        }
    }

    // MARK: pipeline events

    @MainActor private func handle(_ event: PipelineEvent) {
        Log.write(event.line.count > 300 ? String(event.line.prefix(300)) + "…" : event.line)
        switch event {
        case let .agenda(agenda):
            if agendaWindow == nil { agendaWindow = CalendarAgendaWindow() }
            agendaWindow?.show(agenda)
        case let .clarification(question):
            model.status = question
            model.phase = .message
            collapse(after: 90)
        case .thinking:
            break
        case let .plan(plan):
            model.applyPlan(plan)
            model.status = plan.route == .computerUse ? "Working on it…" : "Doing it…"
            if plan.route != .clarify { model.phase = .acting }
        case let .ran(r):
            if !r.note.isEmpty { model.status = r.note }
        case let .axPress(label, _):
            model.status = "Pressed \(label)"
        case let .cuStart(apps):
            model.status = "Using \(apps.joined(separator: ", "))…"
        case let .cuAction(a):
            model.steps += 1
            model.status = a
        case .cuDone:
            break
        case let .check(v, _):
            model.status = "Checking: \(v.detail)"
        case .retry:
            model.status = "Not quite right, trying again…"
        case let .error(m):
            model.status = m
        case let .done(ok, summary):
            model.status = summary
            model.phase = .done(ok: ok)
            collapse(after: ok ? 2.5 : 4)
        }
    }

    // MARK: helpers

    private func show(message: String, for seconds: Double) {
        model.status = message
        model.phase = .message
        collapse(after: seconds)
    }

    private func collapse(after seconds: Double) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.phase = .idle
            self?.model.reset()
            self?.escKey = nil
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
