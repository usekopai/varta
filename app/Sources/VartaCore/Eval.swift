import Foundation

/// Scores finished plans against hand-written labels, and sweeps the confidence thresholds.
/// A port of the Python `brain-eval`, so the numbers in eval/README.md stay reproducible.
///
/// It judges the *whole plan*: the right intent AND the right song, site, queries or app. That's
/// different from replaying the fixture, which only checks the router still decides the same way.
public enum Eval {
    /// One labelled row of eval/commands.csv.
    public struct Row {
        public let id: String
        public let command: String
        public let intent: String
        public let fields: [String: String]

        public func field(_ k: String) -> String { fields[k] ?? "" }
    }

    public struct Scored {
        public let row: Row
        public let plan: Plan
        public let intentOK: Bool
        public let argsOK: Bool
        public let why: String
        public var ok: Bool { intentOK && argsOK }
    }

    // MARK: scoring

    static func norm(_ s: String) -> String {
        let cleaned = String(s.lowercased().map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " })
        return cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func tokens(_ s: String) -> Set<String> { Set(norm(s).split(separator: " ").map(String.init)) }

    /// Searches differing only by leading or trailing articles run the same search.
    static func qnorm(_ s: String) -> String { Candidates.core(norm(s)) }

    static func host(_ url: String) -> String {
        let h = URLComponents(string: url)?.host?.lowercased() ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    public static func score(_ row: Row, _ plan: Plan) -> Scored {
        let gold = row.intent
        if gold == "none" {
            let ok = plan.route == .clarify
            return Scored(row: row, plan: plan, intentOK: ok, argsOK: true,
                          why: ok ? "" : "acted as \(plan.intent) (\(plan.route.rawValue))")
        }
        if plan.intent != gold {
            return Scored(row: row, plan: plan, intentOK: false, argsOK: false, why: "intent \(plan.intent)")
        }
        switch gold {
        case "play_music":
            // A mood cell may list acceptable alternatives: "something relaxing;relaxing"
            let song = row.field("song"), artist = row.field("artist")
            let wants: [Set<String>] = !song.isEmpty || !artist.isEmpty
                ? [tokens([song, artist].filter { !$0.isEmpty }.joined(separator: " "))]
                : row.field("mood").components(separatedBy: ";").map(tokens)
            let got = plan.args["query"].map { tokens($0.text ?? "") } ?? []
            let ok = wants.contains(got)
            return Scored(row: row, plan: plan, intentOK: true, argsOK: ok,
                          why: ok ? "" : "query \(plan.arg("query") ?? "nil")")

        case "open_site":
            let h = plan.urls.first.map(host) ?? ""
            let want = row.field("site")
            let ok = h == want || h.hasSuffix("." + want)
            return Scored(row: row, plan: plan, intentOK: true, argsOK: ok,
                          why: ok ? "" : "url \(plan.urls.first ?? "nil")")

        case "web_search":
            // Each query may list acceptable alternatives, separated by ";"
            let wants = row.field("queries").components(separatedBy: "|").map { Set($0.components(separatedBy: ";").map(qnorm)) }
            let got = (plan.args["queries"]?.list ?? []).map(qnorm)
            let engine = plan.arg("engine")
            let ok = got.count == wants.count && wants.allSatisfy { w in got.contains { w.contains($0) } } && engine == row.field("engine")
            return Scored(row: row, plan: plan, intentOK: true, argsOK: ok,
                          why: ok ? "" : "queries \(got) on \(engine ?? "nil")")

        default:
            let app = plan.arg("app")
            let ok = app == row.field("app")
            return Scored(row: row, plan: plan, intentOK: true, argsOK: ok, why: ok ? "" : "app \(app ?? "nil")")
        }
    }

    // MARK: thresholds

    /// Wilson score interval — a confidence interval that behaves sensibly on small samples.
    public static func wilson(_ k: Int, _ n: Int, z: Double = 1.96) -> (Double, Double) {
        guard n > 0 else { return (0, 1) }
        let p = Double(k) / Double(n), nd = Double(n)
        let d = 1 + z * z / nd
        let centre = (p + z * z / (2 * nd)) / d
        let half = z * ((p * (1 - p) / nd + z * z / (4 * nd * nd)).squareRoot()) / d
        return (max(0, centre - half), min(1, centre + half))
    }

    /// Would this plan run without a clarifying question at these thresholds?
    public static func automated(_ s: Scored, _ ti: Double, _ ta: Double) -> Bool {
        s.plan.intent != "none" && s.plan.intent != "app_task"
            && s.plan.intentConfidence >= ti && s.plan.argConfidence >= ta
    }

    public struct Sweep {
        public let intent: Double, args: Double
        public let automated: Int, correct: Int, accuracy: Double
        public let ci: (Double, Double)
        public let actedOnNone: Int
    }

    /// Every threshold pair reaching `target` accuracy without ever acting on a non-request,
    /// best (most automated) first.
    public static func sweep(_ scored: [Scored], target: Double) -> [Sweep] {
        var rows: [Sweep] = []
        let grid = (0..<20).map { Double($0) * 0.05 }
        for ti in grid {
            for ta in grid {
                let auto = scored.filter { automated($0, ti, ta) }
                let k = auto.filter(\.ok).count
                let ci = wilson(k, auto.count)
                rows.append(Sweep(intent: (ti * 100).rounded() / 100, args: (ta * 100).rounded() / 100,
                                  automated: auto.count, correct: k,
                                  accuracy: auto.isEmpty ? 1 : Double(k) / Double(auto.count), ci: ci,
                                  actedOnNone: auto.filter { $0.row.intent == "none" }.count))
            }
        }
        return rows.filter { $0.accuracy >= target && $0.actedOnNone == 0 }
            .sorted { a, b in
                if a.automated != b.automated { return a.automated > b.automated }
                if a.intent != b.intent { return a.intent > b.intent }
                return a.args > b.args
            }
    }

    // MARK: input

    /// Minimal CSV reader: a header row, then rows, with "quoted,fields" supported.
    public static func rows(csv: String) throws -> [Row] {
        var lines = csv.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return [] }
        let header = fields(lines.removeFirst())
        guard let cmd = header.firstIndex(of: "command"), let intent = header.firstIndex(of: "intent") else {
            throw JevError(description: "the CSV needs 'command' and 'intent' columns")
        }
        return lines.compactMap { line in
            let f = fields(line)
            guard f.count > max(cmd, intent) else { return nil }
            var dict: [String: String] = [:]
            for (i, name) in header.enumerated() where i < f.count { dict[name] = f[i] }
            return Row(id: dict["id"] ?? "", command: f[cmd], intent: f[intent], fields: dict)
        }
    }

    public static func fields(_ line: String) -> [String] {
        var out: [String] = [], field = "", inQuotes = false
        for c in line {
            if c == "\"" { inQuotes.toggle() } else if c == "," && !inQuotes { out.append(field); field = "" } else { field.append(c) }
        }
        out.append(field)
        return out
    }

    // MARK: report

    public static func report(_ scored: [Scored], target: Double) -> String {
        var out = ""
        let n = scored.count
        var order: [String] = []
        var groups: [String: [Scored]] = [:]
        for s in scored {
            if groups[s.row.intent] == nil { order.append(s.row.intent) }
            groups[s.row.intent, default: []].append(s)
        }
        out += "\n  intent        n   intent right   plan right\n"
        out += "  ───────────────────────────────────────────────\n"
        for name in order {
            let g = groups[name]!
            out += String(format: "  %-12s %3d   %8s      %8s\n", (name as NSString).utf8String!, g.count,
                          ("\(g.filter(\.intentOK).count)/\(g.count)" as NSString).utf8String!,
                          ("\(g.filter(\.ok).count)/\(g.count)" as NSString).utf8String!)
        }
        let ki = scored.filter(\.intentOK).count, kp = scored.filter(\.ok).count
        out += String(format: "  %-12s %3d   %8s      %8s\n", ("all" as NSString).utf8String!, n,
                      ("\(ki)/\(n) (\(Int((Double(ki) / Double(n) * 100).rounded()))%)" as NSString).utf8String!,
                      ("\(kp)/\(n) (\(Int((Double(kp) / Double(n) * 100).rounded()))%)" as NSString).utf8String!)

        let wrong = scored.filter { !$0.ok }.sorted { $0.plan.intentConfidence > $1.plan.intentConfidence }
        if !wrong.isEmpty {
            out += "\n  wrong plans (most confident first)\n"
            for s in wrong {
                out += String(format: "  %-5s %-46s %-11s %-34s intent %.2f  args %.2f  %@\n",
                              (s.row.id as NSString).utf8String!, (String(s.row.command.prefix(46)) as NSString).utf8String!,
                              (s.row.intent as NSString).utf8String!, (String(s.why.prefix(34)) as NSString).utf8String!,
                              s.plan.intentConfidence, s.plan.argConfidence, s.plan.route.rawValue)
            }
        }

        let current = scored.filter { automated($0, Router.fastIntent, Router.fastArg) }
        let ck = current.filter(\.ok).count
        let cci = wilson(ck, current.count)
        out += String(format: "\n  current thresholds intent ≥ %.2f, args ≥ %.2f: runs %d/%d, %d/%d right (%.1f%%, 95%% CI %.0f–%.0f%%)\n",
                      Router.fastIntent, Router.fastArg, current.count, n, ck, current.count,
                      current.isEmpty ? 0 : Double(ck) / Double(current.count) * 100, cci.0 * 100, cci.1 * 100)
        if let best = sweep(scored, target: target).first {
            out += String(format: "  best at ≥ %.0f%% accuracy: intent ≥ %.2f, args ≥ %.2f: runs %d/%d, %d/%d right (%.1f%%, 95%% CI %.0f–%.0f%%), never acts on a non-request\n",
                          target * 100, best.intent, best.args, best.automated, n, best.correct, best.automated,
                          best.accuracy * 100, best.ci.0 * 100, best.ci.1 * 100)
        } else {
            out += String(format: "  no threshold pair reaches %.0f%% without acting on a non-request\n", target * 100)
        }
        return out
    }
}
