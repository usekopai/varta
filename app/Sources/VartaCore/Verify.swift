import CoreGraphics
import Foundation

/// Did the computer do what was asked?
///
/// Code gathers facts after execution: what Spotify is playing, which Chrome tabs are open, which
/// app is in front. Exact facts are compared in code; only the semantic match goes to Jev.
public struct Verdict {
    public enum Status: String { case verified, mismatch, unsure, unverified }
    public var status: Status
    public var detail: String
    public var p: Double? = nil
    public var nowPlaying: [String: String]? = nil
    public var page: [String: String]? = nil
}

public enum Observe {
    /// Owner of the topmost normal window (NSWorkspace's frontmost app goes stale off the main run loop).
    public static func frontmostApp() -> String? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 && ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0 {
            return w[kCGWindowOwnerName as String] as? String
        }
        return nil
    }

    static func osa(_ runner: Runner, _ script: String) -> String? {
        let p = runner.run(["osascript", "-e", script], timeout: 4)
        return p.code == 0 ? p.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    public static func spotify(_ runner: Runner = SystemRunner()) -> [String: String]? {
        guard let out = osa(runner, """
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is playing then return (name of current track) & "\\t" & (artist of current track) & "\\t" & (album of current track)
            end tell
        end if
        return ""
        """), !out.isEmpty else { return nil }
        let f = out.components(separatedBy: "\t") + ["", "", ""]
        return ["track": f[0], "artist": f[1], "album": f[2]]
    }

    public static func chromeTabs(_ runner: Runner = SystemRunner()) -> (active: [String: String], urls: [String])? {
        guard let out = osa(runner, """
        if application "Google Chrome" is running then
            tell application "Google Chrome"
                if (count of windows) is 0 then return ""
                set w to front window
                set out to (title of active tab of w) & "\\t" & (URL of active tab of w)
                repeat with t in tabs of w
                    set out to out & linefeed & (URL of t)
                end repeat
                return out
            end tell
        end if
        return ""
        """), !out.isEmpty else { return nil }
        var lines = out.components(separatedBy: "\n")
        let first = lines.removeFirst().components(separatedBy: "\t") + [""]
        return (["title": first[0], "url": first[1]], lines)
    }
}

public final class Verifier {
    // From a 12-case live check (2026-09-25): right tracks scored >= 0.68, wrong ones <= 0.37.
    static let matchYes = 0.60
    static let matchNo = 0.40

    let jev: Jev
    let runner: Runner

    public init(jev: Jev, runner: Runner = SystemRunner()) {
        self.jev = jev
        self.runner = runner
    }

    public func check(_ plan: Plan, settle: TimeInterval = 1.0) async -> Verdict {
        try? await Task.sleep(nanoseconds: UInt64(settle * 1e9))
        do {
            switch plan.intent {
            case "play_music": return try await checkMusic(plan)
            case "web_search": return checkSearch(plan)
            case "open_site": return try await checkSite(plan)
            case "open_app":
                let front = Observe.frontmostApp()
                return Verdict(status: front == plan.arg("app") ? .verified : .mismatch, detail: "\(front ?? "nothing") is in front")
            default: return Verdict(status: .unverified, detail: "no automatic check for \(plan.intent)")
            }
        } catch {
            // A failed check must not fail a command that ran.
            return Verdict(status: .unverified, detail: "couldn't check (\(error))")
        }
    }

    func judge(_ question: String, _ state: JSON) async throws -> Double {
        let reply = try await jev.ask(state: state, questions: [("match", obj(("type", "noul"), ("instructions", .string(question))))])
        return reply.answers["match"]?.noul ?? 0
    }

    func grade(_ p: Double, _ detail: String) -> Verdict {
        Verdict(status: p >= Verifier.matchYes ? .verified : p < Verifier.matchNo ? .mismatch : .unsure, detail: detail, p: p)
    }

    func checkMusic(_ plan: Plan) async throws -> Verdict {
        guard plan.arg("player") == "Spotify" else { return Verdict(status: .unverified, detail: "only Spotify playback is checked") }
        guard let np = Observe.spotify(runner) else { return Verdict(status: .mismatch, detail: "Spotify is not playing", p: 0) }
        let state = obj(("command", .string(plan.transcript)),
                        ("now_playing", obj(("track", .string(np["track"]!)), ("artist", .string(np["artist"]!)), ("album", .string(np["album"]!)))))
        var v = grade(try await judge("Is `now_playing` what the user asked to hear in `command`?", state), "\(np["track"]!) — \(np["artist"]!)")
        v.nowPlaying = np
        return v
    }

    func checkSearch(_ plan: Plan) -> Verdict {
        guard let tabs = Observe.chromeTabs(runner) else { return Verdict(status: .unverified, detail: "could not read Chrome tabs") }
        let missing = plan.urls.filter { u in !tabs.urls.contains { Verifier.samePage(u, $0) } }
        return Verdict(status: missing.isEmpty ? .verified : .mismatch, detail: "\(plan.urls.count - missing.count)/\(plan.urls.count) search tabs open")
    }

    func checkSite(_ plan: Plan) async throws -> Verdict {
        guard let tabs = Observe.chromeTabs(runner) else { return Verdict(status: .unverified, detail: "could not read Chrome tabs") }
        let active = tabs.active
        let detail = "\(active["title"] ?? "") (\(active["url"] ?? ""))"
        if let u = plan.urls.first, Verifier.host(u) == Verifier.host(active["url"] ?? "") {
            return Verdict(status: .verified, detail: detail, page: active)
        }
        // Redirects (the !ducky fallback, or a site that moved) need a judgement, not string equality.
        let state = obj(("command", .string(plan.transcript)), ("page", obj(("title", .string(active["title"] ?? "")), ("url", .string(active["url"] ?? "")))))
        var v = grade(try await judge("Is `page` the website the user asked to open in `command`?", state), detail)
        v.page = active
        return v
    }

    static func host(_ url: String) -> String {
        let h = URLComponents(string: url)?.host?.lowercased() ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// Same host and path; ignores scheme, www, trailing slash and extra query params Google adds.
    static func samePage(_ a: String, _ b: String) -> Bool {
        guard let pa = URLComponents(string: a), let pb = URLComponents(string: b) else { return false }
        guard host(a) == host(b), pa.percentEncodedPath.trimmingSuffix("/") == pb.percentEncodedPath.trimmingSuffix("/") else { return false }
        func q(_ c: URLComponents) -> [String: String] {
            var out: [String: String] = [:]
            for part in (c.percentEncodedQuery ?? "").split(separator: "&") {
                if let eq = part.firstIndex(of: "=") { out[String(part[..<eq])] = String(part[part.index(after: eq)...]) }
            }
            return out
        }
        let qb = q(pb)
        return q(pa).allSatisfy { qb[$0.key] == $0.value }
    }
}

extension String {
    func trimmingSuffix(_ c: Character) -> String {
        var s = self
        while s.last == c { s.removeLast() }
        return s
    }
}
