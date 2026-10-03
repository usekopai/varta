import Foundation
import VartaCore

/// Routing only: explicit public candidates avoid reading installed apps or browser data.
enum RoutingBenchmark {
    static let apps = ["Notes", "Safari", "Calculator", "Spotify"]
    static let sites = [Site(url: "https://github.com", title: "GitHub")!,
                        Site(url: "https://www.wikipedia.org", title: "Wikipedia")!]
    static let labels = """
    id,command,intent,app,site,engine,queries
    notes,open Notes,open_app,Notes,,,
    calculator,open Calculator,open_app,Calculator,,,
    github,open GitHub,open_site,,github.com,,
    search,search for lunar eclipses,web_search,,,google,lunar eclipses
    none,hello there,none,,,,
    """

    struct Sample: Encodable {
        let index: Int
        let repetition: Int
        let commandID: String
        let command: String
        let phase: String
        let routeTotalMs: Double
        var jevSuccessfulAttemptMs: Double?
        var model: String?
        var inputTokens: Int?
        var intent: String?
        var route: String?
        var labelCorrect: Bool?
        var expectedRouteCorrect: Bool?
        var correct: Bool?
        var error: String?
    }

    struct Distribution: Encodable {
        let count: Int
        let p50: Double?
        let p95: Double?
        let minimum: Double?
        let maximum: Double?
        init(_ values: [Double]) {
            let sorted = values.sorted()
            count = sorted.count
            func percentile(_ p: Double) -> Double? {
                guard !sorted.isEmpty else { return nil }
                // Nearest rank: includes the tail instead of interpolating tiny samples.
                return sorted[max(0, Int(ceil(p * Double(sorted.count))) - 1)]
            }
            p50 = percentile(0.5); p95 = percentile(0.95)
            minimum = sorted.first; maximum = sorted.last
        }
    }

    struct Summary: Encodable {
        let attempts: Int
        let successes: Int
        let errors: Int
        let correct: Int
        let incorrect: Int
        let routeTotalAllAttemptsMs: Distribution
        let routeTotalSuccessfulRequestsMs: Distribution
        let jevSuccessfulAttemptMs: Distribution
        init(_ samples: [Sample]) {
            attempts = samples.count
            let successful = samples.filter { $0.error == nil }
            successes = successful.count
            errors = attempts - successes
            correct = successful.filter { $0.correct == true }.count
            incorrect = successes - correct
            routeTotalAllAttemptsMs = Distribution(samples.map(\.routeTotalMs))
            routeTotalSuccessfulRequestsMs = Distribution(successful.map(\.routeTotalMs))
            jevSuccessfulAttemptMs = Distribution(successful.compactMap(\.jevSuccessfulAttemptMs))
        }
    }

    struct Report: Encodable {
        let schemaVersion = 1
        let benchmark = "public-routing-v1"
        let vartaVersion = Varta.version
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let startedAt: String
        let repetitions: Int
        let plannedRequests: Int
        let dryRun: Bool
        let samples: [Sample]
        let all: Summary
        let firstRequest: Summary
        let subsequentRequests: Summary
        let notes = [
            "No actions executed; explicit public candidates only; no microphone or local browser/app inventory.",
            "First request uses a new Jev client; subsequent requests reuse it. Connection reuse is not guaranteed; this is not proof of server cold/warm state.",
            "Route total includes candidate preparation, auth, retries/backoff and interpretation. Jev timing covers only the successful HTTP attempt.",
            "Percentiles use nearest rank. Accuracy requires labelled intent/arguments AND fastpath for actions or clarify for the non-command.",
            "These are routing timings, not voice-to-action measurements. Small sample tails are unstable."
        ]
    }

    static func run(arguments: [String], client: () -> Jev) async -> Int32 {
        var repetitions = 3, dryRun = false, seenRepetitions = false
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--repetitions":
                guard !seenRepetitions, i + 1 < arguments.count,
                      let n = Int(arguments[i + 1]), (1...100).contains(n) else {
                    return usage()
                }
                repetitions = n; seenRepetitions = true; i += 2
            case "--dry-run":
                guard !dryRun else { return usage() }
                dryRun = true; i += 1
            default: return usage()
            }
        }
        guard let rows = try? Eval.rows(csv: labels), rows.count == 5 else { return 1 }
        let started = ISO8601DateFormatter().string(from: Date())
        var samples: [Sample] = []
        if !dryRun {
            let jev = client()
            for repetition in 1...repetitions {
                for row in rows {
                    let index = samples.count + 1
                    let phase = index == 1 ? "first_request" : "subsequent_request"
                    let start = DispatchTime.now().uptimeNanoseconds
                    func elapsed() -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
                    do {
                        let prepared = Router.prepare(row.command, apps: apps, sites: sites)
                        let reply = try await jev.ask(state: prepared.state, questions: prepared.questions)
                        let plan = Router.interpret(prepared, reply)
                        let total = elapsed()
                        let score = Eval.score(row, plan)
                        let routeOK = row.intent == "none" ? plan.route == .clarify : plan.route == .fastpath
                        samples.append(Sample(index: index, repetition: repetition, commandID: row.id,
                            command: row.command, phase: phase, routeTotalMs: total,
                            jevSuccessfulAttemptMs: reply.latencyMs, model: reply.model,
                            inputTokens: reply.inputTokens, intent: plan.intent, route: plan.route.rawValue,
                            labelCorrect: score.ok, expectedRouteCorrect: routeOK, correct: score.ok && routeOK))
                    } catch {
                        // JevError can contain the server response body. Never serialize it.
                        samples.append(Sample(index: index, repetition: repetition, commandID: row.id,
                            command: row.command, phase: phase, routeTotalMs: elapsed(), error: "request_failed"))
                    }
                    FileHandle.standardError.write(Data("benchmark request \(index)/\(rows.count * repetitions) complete\n".utf8))
                }
            }
        }
        let report = Report(startedAt: started, repetitions: repetitions,
                            plannedRequests: rows.count * repetitions, dryRun: dryRun, samples: samples,
                            all: Summary(samples), firstRequest: Summary(samples.filter { $0.index == 1 }),
                            subsequentRequests: Summary(samples.filter { $0.index > 1 }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else { return 1 }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return samples.contains { $0.error != nil || $0.correct != true } ? 1 : 0
    }

    static func usage() -> Int32 {
        FileHandle.standardError.write(Data("usage: varta-cli benchmark [--repetitions 1...100] [--dry-run]\n".utf8))
        return 2
    }
}
