import Foundation
import SQLite3

/// Where candidate apps and sites come from: this Mac, plus small built-in maps.
/// Plain lookup; nothing is sent anywhere until the router shortlists it against the transcript.
public struct Site: Hashable {
    public let domain: String
    public let url: String
    public let title: String

    public init?(url: String, title: String) {
        guard let u = URL(string: url), let scheme = u.scheme, ["http", "https"].contains(scheme),
              let host = u.host(percentEncoded: false), !host.isEmpty else { return nil }
        let netloc = u.port.map { "\(host):\($0)" } ?? host
        self.domain = netloc.hasPrefix("www.") ? String(netloc.dropFirst(4)) : netloc
        self.url = url
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = t.isEmpty ? netloc : t
    }
}

public enum MacSources {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let appDirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                          "/System/Applications/Utilities", home.appendingPathComponent("Applications").path]
    static let extraApps = ["/System/Library/CoreServices/Finder.app"] // not in any app folder

    /// Spoken names that don't look like the bundle name. Values are display names.
    public static let appAliases: [String: [String]] = [
        "Google Chrome": ["chrome", "browser"],
        "Visual Studio Code": ["vs code", "vscode", "code editor"],
        "System Settings": ["settings", "preferences", "system preferences"],
        "Music": ["apple music", "itunes"],
        "Microsoft Word": ["word"],
        "Microsoft Excel": ["excel"],
        "Microsoft PowerPoint": ["powerpoint"],
        "Microsoft Outlook": ["outlook"],
        "Microsoft Teams": ["teams"],
        "Finder": ["files", "file browser"],
        "Terminal": ["command line", "shell"],
        "iTerm": ["iterm"],
        "Activity Monitor": ["task manager"],
        "Messages": ["imessage", "texts"],
        "FaceTime": ["video call"],
        "Photos": ["pictures", "photo library"],
        "QuickTime Player": ["quicktime"],
        "Calculator": ["calc"],
    ]

    public static let builtinSites: [(String, String)] = [
        ("https://news.ycombinator.com", "Hacker News"),
        ("https://www.youtube.com", "YouTube"),
        ("https://mail.google.com", "Gmail"),
        ("https://calendar.google.com", "Google Calendar"),
        ("https://drive.google.com", "Google Drive"),
        ("https://docs.google.com", "Google Docs"),
        ("https://maps.google.com", "Google Maps"),
        ("https://www.google.com", "Google"),
        ("https://github.com", "GitHub"),
        ("https://www.reddit.com", "Reddit"),
        ("https://x.com", "X (Twitter)"),
        ("https://www.linkedin.com", "LinkedIn"),
        ("https://www.instagram.com", "Instagram"),
        ("https://www.facebook.com", "Facebook"),
        ("https://www.amazon.com", "Amazon"),
        ("https://www.amazon.in", "Amazon India"),
        ("https://www.netflix.com", "Netflix"),
        ("https://open.spotify.com", "Spotify Web Player"),
        ("https://en.wikipedia.org", "Wikipedia"),
        ("https://stackoverflow.com", "Stack Overflow"),
        ("https://www.nytimes.com", "The New York Times"),
        ("https://www.theverge.com", "The Verge"),
        ("https://techcrunch.com", "TechCrunch"),
        ("https://www.bbc.com", "BBC"),
        ("https://claude.ai", "Claude"),
        ("https://chatgpt.com", "ChatGPT"),
        ("https://www.notion.so", "Notion"),
        ("https://www.figma.com", "Figma"),
        ("https://vercel.com", "Vercel"),
        ("https://docs.typesafe.ai", "TypeSafe docs"),
        ("https://www.twitch.tv", "Twitch"),
        ("https://www.airbnb.com", "Airbnb"),
        ("https://www.booking.com", "Booking.com"),
        ("https://weather.com", "Weather"),
    ]

    public static let builtinURLs: Set<String> = Set(builtinSites.map { rstripSlash($0.0) })

    /// Apple's built-in apps (plus Finder); offered for implied-app tasks ("set a timer" -> Clock).
    public static let systemApps: Set<String> = {
        var names: Set<String> = ["Finder"]
        for dir in ["/System/Applications", "/System/Applications/Utilities"] {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".app") {
                names.insert(String(f.dropLast(4)))
            }
        }
        return names
    }()

    /// Display names of .app bundles in the usual install locations, sorted.
    public static let installedApps: [String] = {
        var names = Set<String>()
        for dir in appDirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".app") {
                names.insert(String(f.dropLast(4)))
            }
        }
        for p in extraApps where FileManager.default.fileExists(atPath: p) {
            names.insert(URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent)
        }
        return names.sorted()
    }()

    /// Built-in sites, then Chrome top sites and bookmarks; one entry per URL.
    public static let knownSites: [Site] = {
        var sites = builtinSites.compactMap { Site(url: $0.0, title: $0.1) }
        if let profile = chromeProfile() {
            sites += topSites(profile) + bookmarks(profile)
        }
        var seen = Set<String>()
        return sites.filter { seen.insert(rstripSlash($0.url)).inserted }
    }()

    static func rstripSlash(_ s: String) -> String {
        var s = s
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static var chromeDir: URL { home.appendingPathComponent("Library/Application Support/Google/Chrome") }

    static func chromeProfile() -> URL? {
        var last = "Default"
        if let data = try? Data(contentsOf: chromeDir.appendingPathComponent("Local State")),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = root["profile"] as? [String: Any], let lu = profile["last_used"] as? String, !lu.isEmpty {
            last = lu
        }
        let p = chromeDir.appendingPathComponent(last)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir) && isDir.boolValue ? p : nil
    }

    static func bookmarks(_ profile: URL) -> [Site] {
        guard let data = try? Data(contentsOf: profile.appendingPathComponent("Bookmarks")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { return [] }
        var out: [Site] = []
        // A stack, popped from the end: traversal order decides which bookmark wins a duplicate URL.
        var stack: [Any] = roots.keys.sorted { a, b in (rootsOrder.firstIndex(of: a) ?? 99) < (rootsOrder.firstIndex(of: b) ?? 99) }.compactMap { roots[$0] }
        while let node = stack.popLast() {
            guard let n = node as? [String: Any] else { continue }
            if n["type"] as? String == "url", let s = Site(url: n["url"] as? String ?? "", title: n["name"] as? String ?? "") {
                out.append(s)
            }
            stack.append(contentsOf: (n["children"] as? [Any]) ?? [])
        }
        return out
    }

    static let rootsOrder = ["bookmark_bar", "other", "synced"]

    static func topSites(_ profile: URL) -> [Site] {
        let src = profile.appendingPathComponent("Top Sites")
        guard FileManager.default.fileExists(atPath: src.path) else { return [] }
        // Chrome keeps the database locked while running; read a copy.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("varta-topsites-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? FileManager.default.copyItem(at: src, to: tmp)) != nil else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT url, title FROM top_sites ORDER BY url_rank", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [Site] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let url = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            if let s = Site(url: url, title: title) { out.append(s) }
        }
        return out
    }
}
