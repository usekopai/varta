import Foundation
import VartaCore
import WhisperKit

/// varta-cli questions "<command>"        print the Jev request the router would send (no network)
/// varta-cli route "<command>"            plan it with live Jev
/// varta-cli interpret <answers.jsonl>    replay recorded Jev answers through the Swift router
///                                           and check them against the expected plans
/// varta-cli run "<command>"              plan and do it, like the notch app would
/// varta-cli transcribe <audio files…>    local Whisper speech-to-text, with timings
/// varta-cli hold <release-after-s> <audio files…>
///                                           replay each file in real time as if ⌥Space were held,
///                                           let go `release-after-s` after the audio ends, and time
///                                           the transcript from the moment of release
let args = Array(CommandLine.arguments.dropFirst())
guard let mode = args.first else {
    print("""
    varta \(Varta.version)
    usage: varta-cli <mode> …
      questions "<command>"            print the Jev request (no network)
      route "<command>"                plan it with live Jev
      benchmark-actions <audio-dir> <N> synthetic speech through real app/folder actions
      benchmark [--repetitions N]      public routing timings and accuracy (live API)
      run "<command>"                  plan and do it
      interpret <fixture.jsonl>        replay recorded Jev answers through the router
      eval <commands.csv> [fixture]    score plans against the labels and sweep the thresholds
      transcribe <audio files…>        local Whisper, with timings
      hold <release-after-s> <files…>  simulate push-to-talk, time from release
    """)
    exit(2)
}
if mode == "--version" || mode == "version" {
    print(Varta.version)
    exit(0)
}
let rest = args.dropFirst().joined(separator: " ")

func jev() -> Jev {
    Jev { guard let k = Credentials.get(.typesafe) else { throw JevError(description: "TYPESAFE_API_KEY not set") }; return k }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Stable text for comparing two JSON values: object keys sorted, same number formatting.
func canonical(_ j: JSON) -> String {
    switch j {
    case let .object(pairs): return "{" + pairs.sorted { $0.0 < $1.0 }.map { "\($0.0):\(canonical($0.1))" }.joined(separator: ",") + "}"
    case let .array(items): return "[" + items.map(canonical).joined(separator: ",") + "]"
    default: return j.description
    }
}

enum Fixture {
    /// The part of a plan the fixture pins: what the router decided, not how long it took.
    static func summary(of plan: Plan) -> JSON {
        let keys = ["intent", "intent_confidence", "route", "arg_confidence", "args", "urls"]
        let j = plan.json
        return .object(keys.compactMap { k in j[k].map { (k, $0) } })
    }

    /// Keep only the probabilities the router reads: `none` (presence) and every option sharing the
    /// chosen option's core (the span-confidence sum). Drops ~99% of the bytes, same behaviour.
    static func prune(_ answer: JSON) -> JSON {
        guard let pairs = answer.object else { return answer }
        guard let probs = answer["probabilities"]?.object, let chosen = answer["choice"]?.string else { return answer }
        let core = Candidates.core(chosen)
        let kept = probs.filter { $0.0 == chosen || $0.0 == Candidates.none || Candidates.core($0.0) == core }
        return .object(pairs.map { $0.0 == "probabilities" ? ($0.0, .object(kept)) : $0 })
    }

    static func line(command: String, prep: Router.Prepared, answers: [String: JSON], plan: Plan) -> JSON {
        obj(("command", .string(command)),
            ("apps", .array(prep.apps.map { .string($0) })),
            ("sites", .array(prep.siteList.map { obj(("url", .string($0.url)), ("title", .string($0.title))) })),
            ("answers", .object(answers.keys.sorted().map { ($0, prune(answers[$0]!)) })),
            ("expect", summary(of: plan)))
    }

    /// Minimal CSV field split with "quoted,fields" support.
    static func csvFields(_ line: String) -> [String] {
        var out: [String] = [], field = "", inQuotes = false
        for c in line {
            if c == "\"" { inQuotes.toggle() } else if c == "," && !inQuotes { out.append(field); field = "" } else { field.append(c) }
        }
        out.append(field)
        return out
    }
}

switch mode {
case "benchmark-actions":
    exit(await ActionBenchmark.run(arguments: Array(args.dropFirst()), client: jev))

case "benchmark":
    exit(await RoutingBenchmark.run(arguments: Array(args.dropFirst()), client: jev))

case "questions":
    let p = Router.prepare(rest)
    print(obj(("state", p.state), ("questions", .object(p.questions))))

case "route":
    do { print(try await Router.route(jev: jev(), transcript: rest).json) } catch { fail("\(error)") }

case "interpret":
    // Replay recorded Jev answers through the router, with no network and no key. The fixture carries
    // the apps and sites the questions were built from, so the result doesn't depend on this Mac.
    guard let text = try? String(contentsOfFile: rest, encoding: .utf8) else { fail("can't read \(rest)") }
    var checked = 0, failed = 0
    for line in text.split(separator: "\n") where !line.isEmpty {
        guard let row = try? JSON.parse(Data(line.utf8)), let cmd = row["command"]?.string, let answers = row["answers"]?.object else { continue }
        let apps = row["apps"]?.array?.compactMap(\.string) ?? MacSources.installedApps
        let sites = row["sites"]?.array?.compactMap { s -> Site? in
            guard let url = s["url"]?.string, let title = s["title"]?.string else { return nil }
            return Site(url: url, title: title)
        } ?? MacSources.knownSites
        let prep = Router.prepare(cmd, apps: apps, sites: sites)
        let reply = JevReply(answers: Dictionary(answers, uniquingKeysWith: { a, _ in a }), model: "replay", inputTokens: 0, latencyMs: 0)
        let plan = Router.interpret(prep, reply)
        guard let expect = row["expect"] else {
            print(obj(("command", .string(cmd)), ("plan", plan.json)))
            continue
        }
        checked += 1
        let got = Fixture.summary(of: plan)
        if canonical(got) != canonical(expect) {
            failed += 1
            print("FAIL  \(cmd)\n  expected \(canonical(expect))\n  got      \(canonical(got))")
        }
    }
    if checked > 0 {
        print("\(checked - failed)/\(checked) plans match the recorded answers")
        exit(failed == 0 ? 0 : 1)
    }

case "eval":
    // Whole-plan accuracy against the hand-written labels, plus a threshold sweep.
    // With a fixture it needs no key; without one it asks Jev live, one request per command.
    let parts = Array(args.dropFirst())
    guard let path = parts.first, let csv = try? String(contentsOfFile: path, encoding: .utf8) else {
        fail("usage: varta-cli eval <commands.csv> [fixture.jsonl]")
    }
    guard let rows = try? Eval.rows(csv: csv), !rows.isEmpty else { fail("no labelled rows in \(path)") }

    var scored: [Eval.Scored] = []
    if parts.count > 1 {
        guard let text = try? String(contentsOfFile: parts[1], encoding: .utf8) else { fail("can't read \(parts[1])") }
        var recorded: [String: JSON] = [:]
        for line in text.split(separator: "\n") where !line.isEmpty {
            if let row = try? JSON.parse(Data(line.utf8)), let cmd = row["command"]?.string { recorded[cmd] = row }
        }
        for row in rows {
            guard let rec = recorded[row.command], let answers = rec["answers"]?.object else {
                FileHandle.standardError.write(Data("not in the fixture, skipped: \(row.command)\n".utf8))
                continue
            }
            let apps = rec["apps"]?.array?.compactMap(\.string) ?? MacSources.installedApps
            let sites = rec["sites"]?.array?.compactMap { s -> Site? in
                guard let url = s["url"]?.string, let title = s["title"]?.string else { return nil }
                return Site(url: url, title: title)
            } ?? MacSources.knownSites
            let prep = Router.prepare(row.command, apps: apps, sites: sites)
            let reply = JevReply(answers: Dictionary(answers, uniquingKeysWith: { a, _ in a }), model: "replay", inputTokens: 0, latencyMs: 0)
            scored.append(Eval.score(row, Router.interpret(prep, reply)))
        }
    } else {
        let j = jev()
        for row in rows {
            do { scored.append(Eval.score(row, try await Router.route(jev: j, transcript: row.command))) }
            catch { fail("\(row.command): \(error)") }
        }
    }
    print(Eval.report(scored, target: 0.95))

case "record":
    // Record live Jev answers as a fixture for `interpret`. Costs one Jev request per command.
    let parts = args.dropFirst()
    guard parts.count == 2, let csv = try? String(contentsOfFile: parts.first!, encoding: .utf8) else {
        fail("usage: varta-cli record <commands.csv> <out.jsonl>")
    }
    let out = Array(parts)[1]
    var lines = csv.split(separator: "\n").map(String.init)
    let header = lines.removeFirst().split(separator: ",").map(String.init)
    guard let col = header.firstIndex(of: "command") else { fail("no 'command' column") }
    let j = jev()
    var recorded: [String] = []
    for line in lines {
        let fields = Fixture.csvFields(line)
        guard fields.count > col else { continue }
        let cmd = fields[col]
        let prep = Router.prepare(cmd)
        do {
            let reply = try await j.ask(state: prep.state, questions: prep.questions)
            let plan = Router.interpret(prep, reply)
            recorded.append(Fixture.line(command: cmd, prep: prep, answers: reply.answers, plan: plan).description)
            FileHandle.standardError.write(Data("recorded \(cmd)\n".utf8))
        } catch {
            fail("\(cmd): \(error)")
        }
    }
    try? (recorded.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    print("wrote \(recorded.count) rows to \(out)")

case "run":
    let pipeline = Pipeline(jev: jev())
    await pipeline.run(rest) { event in print(event.line) }

case "transcribe":
    let speech = LocalSpeech()
    let t0 = Date()
    do {
        try await speech.prepare(vocabulary: Array(MacSources.installedApps.prefix(40)) + MacSources.builtinSites.map(\.1)) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    } catch { fail("\(error)") }
    print(String(format: "model %@ ready in %.1f s", LocalSpeech.model, Date().timeIntervalSince(t0)))
    for file in args.dropFirst() {
        let t = Date()
        do {
            let text = try await speech.transcribe(file: file)
            print(String(format: "%5.0f ms  %@  →  %@", Date().timeIntervalSince(t) * 1000, URL(fileURLWithPath: file).lastPathComponent, text))
        } catch { print("error \(file): \(error)") }
    }

case "hold":
    let rel = Double(args.dropFirst().first ?? "0.4") ?? 0.4
    let speech = LocalSpeech()
    do { try await speech.prepare(vocabulary: Array(MacSources.installedApps.prefix(40)) + MacSources.builtinSites.map(\.1)) } catch { fail("\(error)") }
    let hold = HoldTranscriber(speech: speech)
    for file in args.dropFirst(2) {
        guard let audio = try? AudioProcessor.loadAudioAsFloatArray(fromPath: file) else { print("can't read \(file)"); continue }
        final class Feed: @unchecked Sendable { var n = 0; let lock = NSLock() }
        let feed = Feed()
        let total = audio.count + Int(rel * LocalSpeech.sampleRate)
        let padded = audio + [Float](repeating: 0, count: total - audio.count)
        hold.begin(snapshot: { feed.lock.withLock { Array(padded.prefix(feed.n)) } }, onPartial: { _ in })
        let t0 = Date()
        while feed.lock.withLock({ feed.n }) < total {   // real-time playback
            try? await Task.sleep(nanoseconds: 20_000_000)
            let n = min(total, Int(Date().timeIntervalSince(t0) * LocalSpeech.sampleRate))
            feed.lock.withLock { feed.n = n }
        }
        let released = Date()
        let text = await hold.end(padded)
        print(String(format: "%5.0f ms after release  %-22@  %@  →  %@", Date().timeIntervalSince(released) * 1000, hold.lastSource,
                     URL(fileURLWithPath: file).lastPathComponent, text))
    }

default:
    fail("unknown mode \(mode)")
}
