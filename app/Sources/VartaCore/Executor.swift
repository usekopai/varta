import AppKit
import Foundation

public struct ProcessResult {
    public let code: Int32
    public let stdout: String
    public let stderr: String

    public init(code: Int32, stdout: String, stderr: String) {
        self.code = code
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs a command with an argument list (never a shell), with a timeout.
public protocol Runner {
    func run(_ cmd: [String], timeout: TimeInterval) -> ProcessResult
}

public struct SystemRunner: Runner {
    public init() {}

    public func run(_ cmd: [String], timeout: TimeInterval = 15) -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd[0].hasPrefix("/") ? cmd[0] : "/usr/bin/\(cmd[0])")
        p.arguments = Array(cmd.dropFirst())
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return ProcessResult(code: 127, stdout: "", stderr: "\(error)") }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            // A first AppleScript call to an app can block on macOS's "allow to control" prompt.
            return ProcessResult(code: 124, stdout: "", stderr: "timed out (macOS may be asking to allow automation; check for a dialog)")
        }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(code: p.terminationStatus, stdout: o, stderr: e)
    }
}

public struct ExecResult {
    public var ok = true
    public var ran: [String] = []
    public var note = ""
    /// What computer use still has to do, if anything.
    public var handoff = ""
    public var ms = 0.0
}

/// Deterministic fast-path actions: `open` and AppleScript, no model involved.
/// AppleScript gets values through `on run argv`, so a transcript can't become code.
public final class Executor {
    static let browsers = ["Google Chrome", "Safari", "Arc", "Brave Browser", "Firefox", "Microsoft Edge"]
    static let preferredBrowser = "Google Chrome"
    /// Spotify's top *track* is right for these; albums and playlists need their own play button.
    static let directPlayKinds: Set<String> = ["track", "artist", "mood"]

    let browserController: BrowserController
    let runner: Runner
    let apps: Set<String>

    public init(runner: Runner = SystemRunner(), apps: [String] = MacSources.installedApps, browserController: BrowserController = BrowserController()) {
        self.browserController = browserController
        self.runner = runner
        self.apps = Set(apps)
    }

    @discardableResult
    func exec(_ res: inout ExecResult, _ cmd: [String], cancel: CancelFlag? = nil) -> Bool {
        guard !stopped(&res, cancel) else { return false }
        res.ran.append(cmd.joined(separator: " "))
        let p = runner.run(cmd, timeout: 15)
        if p.code != 0 {
            res.ok = false
            res.note = String((p.stderr.isEmpty ? p.stdout : p.stderr).trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            return false
        }
        return true
    }

    func osascript(_ res: inout ExecResult, _ script: String, _ argv: String..., cancel: CancelFlag? = nil) -> String? {
        guard !stopped(&res, cancel) else { return nil }
        res.ran.append("osascript <\(script.split(separator: "\n").first ?? "")…> \(argv.map { "'\($0)'" }.joined(separator: " "))")
        let p = runner.run(["osascript", "-e", script] + argv, timeout: 15)
        if p.code != 0 {
            res.ok = false
            res.note = String(p.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            return nil
        }
        return p.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cancellation prevents new dispatches; it cannot undo a subprocess already started.
    private func stopped(_ res: inout ExecResult, _ cancel: CancelFlag?) -> Bool {
        guard cancel?.isSet == true || Task.isCancelled else { return false }
        res.ok = false
        res.note = "Stopped"
        return true
    }

    func browser(for plan: Plan) -> String? {
        if let named = plan.arg("app"), Executor.browsers.contains(named), apps.contains(named) { return named }
        return apps.contains(Executor.preferredBrowser) ? Executor.preferredBrowser : nil
    }

    public func execute(_ plan: Plan, cancel: CancelFlag? = nil, browserOrigin: BrowserTarget? = nil) -> ExecResult {
        let t0 = Date()
        var res = ExecResult()
        guard !stopped(&res, cancel) else { return res }
        switch plan.route {
        case .fastpath, .fastpathThenCheck:
            switch plan.intent {
            case "browser_control":
                res = browserController.execute(operation: plan.arg("operation"), browser: plan.arg("browser"), origin: browserOrigin, cancel: cancel ?? CancelFlag())
            case "audio_control": controlAudio(plan, &res, cancel: cancel)
            case "playback_control": controlPlayback(plan, &res, cancel: cancel)
            case "open_app": exec(&res, ["open", "-a", plan.arg("app") ?? ""], cancel: cancel)
            case "open_site", "web_search": openURLs(plan, &res, cancel: cancel)
            case "play_music": playMusic(plan, &res, cancel: cancel)
            default:
                res.ok = false
                res.note = "no fast path for \(plan.intent)"
            }
        default:
            res.ok = false
            res.note = "not executed: route is \(plan.route.rawValue) (\(plan.reason))"
        }
        res.ms = Date().timeIntervalSince(t0) * 1000
        return res
    }

    func openURLs(_ plan: Plan, _ res: inout ExecResult, cancel: CancelFlag? = nil) {
        if let b = browser(for: plan) {
            exec(&res, ["open", "-a", b] + plan.urls, cancel: cancel)
        } else {
            for u in plan.urls where !exec(&res, ["open", u], cancel: cancel) { return }
        }
    }

    func playMusic(_ plan: Plan, _ res: inout ExecResult, cancel: CancelFlag? = nil) {
        let player = plan.arg("player") ?? "Spotify"
        let query = plan.arg("query") ?? ""
        if player == "Music" { return playAppleMusic(query, &res, cancel: cancel) }
        if query.isEmpty {
            _ = osascript(&res, "tell application \"Spotify\" to play", cancel: cancel)
            return
        }
        let kind = plan.arg("kind") ?? "track"
        if Executor.directPlayKinds.contains(kind) {
            // Spotify plays a search URI's top track directly (~1 s, no screen). The check afterwards
            // catches a wrong top result and hands it to computer use.
            if osascript(&res, "on run argv\n    tell application \"Spotify\" to play track (item 1 of argv)\nend run", plan.urls[0], cancel: cancel) != nil {
                res.note = "playing the top result for \"\(query)\""
            }
            return
        }
        guard exec(&res, ["open", plan.urls[0]], cancel: cancel) else { return }
        res.handoff = "The user said: \"\(plan.transcript)\". Spotify is showing search results for \"\(query)\". Start playing the \(kind) they asked for, usually the top result. If the results don't match what they asked for, search Spotify for it yourself."
        res.note = "Opened the Spotify search for \"\(query)\". Press play on the result."
    }

    func playAppleMusic(_ query: String, _ res: inout ExecResult, cancel: CancelFlag? = nil) {
        if query.isEmpty {
            _ = osascript(&res, "tell application \"Music\" to play", cancel: cancel)
            return
        }
        // Library only: Music has no scriptable catalogue search.
        let script = """
        on run argv
            set q to item 1 of argv
            tell application "Music"
                set hits to (every track of library playlist 1 whose name contains q or artist contains q)
                if (count of hits) is 0 then return "none"
                play item 1 of hits
                return (name of item 1 of hits) & " - " & (artist of item 1 of hits)
            end tell
        end run
        """
        let out = osascript(&res, script, query, cancel: cancel)
        if out == "none" {
            res.ok = true
            res.note = "\"\(query)\" is not in your Music library. Search for it in Music"
            res.handoff = "In Music, search the catalogue for \"\(query)\" and play the top result."
        } else if let out {
            res.note = "playing \(out)"
        }
    }
}
