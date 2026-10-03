import Foundation

/// Code-side candidate generation.
///
/// Jev picks from options; it never writes text. So before asking anything, code finds every value
/// the answer could be: spans of the transcript (song, artist, query), installed apps, known sites.
/// These finders over-find; Jev does the choosing.
public enum Candidates {
    public static let none = "none"
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "mm", "mhm"]
    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "to", "of", "in", "on", "at", "for", "with", "by", "from",
        "up", "me", "my", "i", "you", "it", "is", "be", "can", "could", "would", "please", "some",
        "that", "this", "then", "also", "just", "go", "open", "play", "search", "look", "find", "want",
        "like", "let's", "lets", "do", "few", "bunch", "kindly", "hey", "ok", "okay",
    ]
    public static let separators: Set<String> = ["and", "then", "also", "plus", "&"]
    static let defaultApps = ["Spotify", "Google Chrome", "Safari", "Music", "Finder", "Notes", "Reminders",
                              "Messages", "Mail", "Calendar", "System Settings"]
    static let articles: Set<String> = ["the", "a", "an", "some", "my"]
    static let leading: Set<Character> = ["\"", "'", "“", "”", "‘", "’", "(", "[", "{"]
    static let trailing: Set<Character> = ["\"", "'", "“", "”", "‘", "’", ")", "]", "}", ",", ".", "!", "?", ";", ":"]
    static let domainRegex = try! NSRegularExpression(pattern: "^[a-z0-9-]+(\\.[a-z0-9-]+)*\\.[a-z]{2,}$", options: [.caseInsensitive])

    public static func isDomain(_ s: String) -> Bool {
        domainRegex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Tokens with edge punctuation and filler sounds removed; a trailing comma becomes its own token.
    public static func words(_ text: String) -> [String] {
        var out: [String] = []
        for rawSub in text.split(whereSeparator: \.isWhitespace) {
            let raw = String(rawSub)
            var r = raw
            while let c = r.last, "\"'”’)".contains(c) { r.removeLast() }
            let comma = r.hasSuffix(",")
            var w = Substring(raw)
            while let c = w.first, leading.contains(c) { w.removeFirst() }
            while let c = w.last, trailing.contains(c) { w.removeLast() }
            let word = String(w)
            if !word.isEmpty && !fillers.contains(word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))) {
                out.append(word)
            }
            if comma, let last = out.last, last != "," { out.append(",") }
        }
        return out
    }

    public static func clean(_ text: String) -> String { words(text).filter { $0 != "," }.joined(separator: " ") }

    /// Every contiguous run of 1...maxLen words, deduped, skipping runs of only stopwords.
    /// Choice questions cap at 255 options, so maxLen shrinks until the list fits `limit`.
    public static func spans(_ ws: [String], maxLen: Int = 8, limit: Int = 240) -> [String] {
        let ws = ws.filter { $0 != "," }
        var maxLen = maxLen
        while true {
            var seen = Set<String>()
            var out: [String] = []
            if maxLen >= 1 {
                for n in 1...maxLen where n <= ws.count {
                    for i in 0...(ws.count - n) {
                        let run = ws[i..<(i + n)]
                        if run.allSatisfy({ stopwords.contains($0.lowercased()) }) { continue }
                        let s = run.joined(separator: " ")
                        let low = s.lowercased()
                        if low != none && seen.insert(low).inserted { out.append(s) }
                    }
                }
            }
            if out.count <= limit || maxLen == 1 { return Array(out.prefix(limit)) }
            maxLen -= 1
        }
    }

    /// Things that read as a web address: "github.com", or spoken "github dot com".
    public static func domainCandidates(_ ws: [String]) -> [String] {
        let ws = ws.filter { $0 != "," }.map { $0.lowercased() }
        var out = ws.filter(isDomain)
        if ws.count >= 3 {
            for i in 1..<(ws.count - 1) where ws[i] == "dot" {
                for start in max(0, i - 3)..<i {
                    let name = ws[start..<i].joined()
                    if !name.isEmpty && !stopwords.contains(name) { out.append("\(name).\(ws[i + 1])") }
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// "x dot com" -> "x.com"; other spans unchanged.
    public static func spokenDomain(_ span: String) -> String {
        let low = span.lowercased()
        guard " \(low) ".contains(" dot ") else { return span }
        let candidate = low.replacingOccurrences(of: " dot ", with: ".").replacingOccurrences(of: " ", with: "")
        guard isDomain(candidate) else { return span }
        return low.split(separator: " ").joined().replacingOccurrences(of: "dot", with: ".")
    }

    public struct Clauses: Equatable {
        public var parts: [String]
        public var separators: [String]
    }

    /// Split on "and" / "then" / commas; Jev decides which separators really divide two searches.
    public static func clauses(_ ws: [String]) -> Clauses {
        var parts: [[String]] = [[]]
        var seps: [String] = []
        for w in ws {
            let lw = w.lowercased()
            if separators.contains(lw) || w == "," {
                if parts[parts.count - 1].isEmpty {
                    if !seps.isEmpty { seps[seps.count - 1] = "\(seps[seps.count - 1]) \(lw)".replacingOccurrences(of: " ,", with: ",") }
                    continue
                }
                parts.append([])
                seps.append(lw)
            } else {
                parts[parts.count - 1].append(w)
            }
        }
        if parts[parts.count - 1].isEmpty && !seps.isEmpty {
            parts.removeLast()
            seps.removeLast()
        }
        return Clauses(parts: parts.map { $0.joined(separator: " ") }, separators: seps)
    }

    static func shortSpans(_ ws: [String], maxLen: Int = 4) -> [String] {
        spans(ws, maxLen: maxLen, limit: 10_000).map { $0.lowercased() }
    }

    static func appScores(_ ws: [String], _ apps: [String]) -> [(Double, String)] {
        let cands = shortSpans(ws)
        var scored: [(Double, String)] = []
        for app in apps {
            let names = [app.lowercased()] + (MacSources.appAliases[app] ?? [])
            var best = 0.0
            for n in names { for c in cands { best = max(best, Fuzzy.ratio(n, c)) } }
            if best >= 70 { scored.append((best, app)) }
        }
        return scored.sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
    }

    /// Installed apps the command names almost exactly (context for the intent question).
    public static func namedApps(_ ws: [String], _ apps: [String]) -> [String] {
        Array(appScores(ws, apps).filter { $0.0 >= 88 }.map(\.1).prefix(5))
    }

    /// Installed apps resembling part of the command, plus common defaults.
    public static func shortlistApps(_ ws: [String], _ apps: [String], k: Int = 25) -> [String] {
        var picked = Array(appScores(ws, apps).prefix(k).map(\.1))
        let installed = Set(apps)
        for a in defaultApps where installed.contains(a) && !picked.contains(a) { picked.append(a) }
        return picked
    }

    public static func siteLabel(_ site: Site) -> String {
        var title = site.title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if title.count > 60 { title = String(title.prefix(57)) + "..." }
        return site.domain.lowercased().contains(title.lowercased()) ? title : "\(title) (\(site.domain))"
    }

    /// A span without leading/trailing articles: "the weather in paris" ~ "weather in paris".
    public static func core(_ span: String) -> String {
        var w = span.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        while let f = w.first, articles.contains(f) { w.removeFirst() }
        while let l = w.last, articles.contains(l) { w.removeLast() }
        return w.joined(separator: " ")
    }

    static func domainLabel(_ domain: String) -> String {
        let parts = domain.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return parts.count >= 2 ? parts[parts.count - 2] : domain
    }

    /// Known sites whose title or domain resembles part of the command.
    public static func shortlistSites(_ ws: [String], _ sites: [Site], k: Int = 30) -> [Site] {
        let cands = shortSpans(ws).filter { $0.count >= 3 }
        if cands.isEmpty { return [] }
        let joined = cands.map { $0.replacingOccurrences(of: " ", with: "") }
        var scored: [(Double, Int, Int, Int, Site)] = []
        for (idx, s) in sites.enumerated() {
            let title = s.title.lowercased()
            let label = domainLabel(s.domain)
            var best = 0.0
            for c in cands { best = max(best, Fuzzy.tokenSetRatio(c, title)) }
            for j in joined { best = max(best, Fuzzy.ratio(j, label), Fuzzy.ratio(j, s.domain)) }
            if best >= 80 {
                let builtin = MacSources.builtinURLs.contains(MacSources.rstripSlash(s.url)) ? 0 : 1
                scored.append((best, builtin, s.title.count, idx, s))
            }
        }
        scored.sort { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            return a.3 < b.3 // keep input order for ties, so the question is deterministic
        }
        return Array(scored.prefix(k).map(\.4))
    }

    /// Titles of shortlisted sites the command names outright (context for the intent question).
    public static func namedSites(_ command: String, _ sites: [Site], k: Int = 5) -> [String] {
        let text = command.lowercased()
        let squashed = text.replacingOccurrences(of: " ", with: "")
        var out: [String] = []
        for s in sites {
            let root = s.domain.contains(".") ? domainLabel(s.domain) : s.domain
            if text.contains(s.title.lowercased()) || (root.count >= 4 && squashed.contains(root)) { out.append(s.title) }
        }
        return Array(out.prefix(k))
    }
}

/// Python's urllib.parse.quote / quote_plus rules, which is what the recorded eval fixtures expect.
public enum URLQuote {
    static let alwaysSafe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~".utf8)

    public static func quote(_ s: String, safe: String = "/") -> String {
        let safeSet = alwaysSafe.union(safe.utf8)
        var out = ""
        for b in s.utf8 {
            if safeSet.contains(b) { out.unicodeScalars.append(Unicode.Scalar(b)) } else { out += String(format: "%%%02X", b) }
        }
        return out
    }

    public static func quotePlus(_ s: String) -> String {
        quote(s, safe: " ").replacingOccurrences(of: " ", with: "+")
    }
}
