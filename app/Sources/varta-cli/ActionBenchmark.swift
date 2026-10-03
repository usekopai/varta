import Foundation
import VartaCore
import WhisperKit

/// Synthetic audio through the production transcriber and pipeline, with bounded real actions.
enum ActionBenchmark {
    static let commands = [("calculator", "open Calculator", "open_app", "Calculator"), ("downloads", "open Downloads", "finder_control", "downloads"), ("notes", "open Notes", "open_app", "Notes")]
    static func run(arguments: [String], client: () -> Jev) async -> Int32 {
        guard arguments.count == 2, let repeats = Int(arguments[1]), (1...20).contains(repeats) else {
            FileHandle.standardError.write(Data("usage: benchmark-actions <audio-directory> <repetitions 1...20>; opens Calculator, Downloads and Notes\n".utf8)); return 2
        }
        let speech = LocalSpeech(), jev = client()
        func notice(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
        do { try await speech.prepare(vocabulary: ["Calculator", "Downloads", "Notes"], progress: notice) }
        catch { notice("Speech preparation failed"); return 1 }
        var samples: [[String: Any]] = []
        let started = ISO8601DateFormatter().string(from: Date())
        let hold = HoldTranscriber(speech: speech)
        for repetition in 1...repeats {
            for (id, expected, intent, target) in commands {
                let path = URL(fileURLWithPath: arguments[0]).appendingPathComponent(id + ".aiff").path
                guard let audio = try? AudioProcessor.loadAudioAsFloatArray(fromPath: path) else { notice("Missing benchmark clip: " + id); return 2 }
                let padded = audio + [Float](repeating: 0, count: Int(0.4 * LocalSpeech.sampleRate))
                final class Feed: @unchecked Sendable { let lock = NSLock(); var count = 0 }
                let feed = Feed(), began = ProcessInfo.processInfo.systemUptime
                hold.begin(snapshot: { feed.lock.withLock { Array(padded.prefix(feed.count)) } }, onPartial: { _ in })
                while feed.lock.withLock({ feed.count }) < padded.count {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    let count = min(padded.count, Int((ProcessInfo.processInfo.systemUptime-began)*LocalSpeech.sampleRate))
                    feed.lock.withLock { feed.count = count }
                }
                let timing = CommandTiming()
                let text = await hold.end(padded)
                timing.transcribed(source: hold.lastSource)
                var final: CommandTiming.Sample?, routedCorrectly = false, doneOK = false
                var executionOK: Bool?, verificationStatus: String?
                // Reject any unexpected plan before it can dispatch; classify using public candidates.
                let pipeline = Pipeline(jev: jev, route: { transcript in
                    let routeStart = ProcessInfo.processInfo.systemUptime
                    let prep = Router.prepare(transcript, apps: ["Calculator", "Notes"], sites: [])
                    var plan = Router.interpret(prep, try await jev.ask(state: prep.state, questions: prep.questions))
                    plan.latencyMs = (ProcessInfo.processInfo.systemUptime - routeStart) * 1000
                    let correct = plan.intent == intent && plan.route == .fastpath && (intent == "open_app" ? plan.arg("app") == target : plan.arg("operation") == "folder" && plan.arg("target") == target)
                    routedCorrectly = correct
                    if !correct { plan.route = .clarify; plan.args = [:]; plan.urls = [] }
                    return plan
                })
                await pipeline.run(text) { event in
                    if let sample = timing.observe(event) { final = sample }
                    if case let .done(ok, _) = event { doneOK = ok }
                    if case let .ran(result) = event { executionOK = result.ok }
                    if case let .check(verdict, _) = event { verificationStatus = verdict.status.rawValue }
                }
                guard let final, let data = try? JSONEncoder().encode(final), var row = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { notice("Missing timing sample"); return 1 }
                row["executionReportedSuccess"] = executionOK
                row["verificationStatus"] = verificationStatus
                row["commandID"] = id; row["repetition"] = repetition
                row["transcriptCorrect"] = text.caseInsensitiveCompare(expected) == .orderedSame
                row["routeCorrect"] = routedCorrectly; row["reportedSuccess"] = doneOK
                row["completionBoundary"] = intent == "finder_control" ? "folder_open_dispatch" : "app_pipeline_status_after_verification"
                samples.append(row)
                notice("Completed \(id) \(repetition)/\(repeats): \(Int(final.releaseToStatusMs)) ms; success=\(doneOK)")
            }
        }
        let report: [String: Any] = ["benchmark":"synthetic-audio-to-status-v1", "startedAt":started, "releaseDelaySeconds":0.4, "model":LocalSpeech.model,
                                     "language":LocalSpeech.language, "compute":"WhisperKit default", "vartaVersion":Varta.version,
                                     "osVersion":ProcessInfo.processInfo.operatingSystemVersionString, "samples":samples,
                                     "notes":["Synthetic audio replayed in real time; no microphone. Prepared model; one Jev client reused.", "Real app/folder actions; fixed public routing candidates. Wrong plans blocked before dispatch.", "Final pipeline status is not a measurement of visible completion. App checks may include a one-second settle delay.", "No Notes content, reminders or events created. Permission flows excluded."]]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), let json = String(data:data,encoding:.utf8) { print(json) }
        return samples.allSatisfy { ($0["reportedSuccess"] as? Bool) == true && ($0["transcriptCorrect"] as? Bool) == true && ($0["routeCorrect"] as? Bool) == true } ? 0 : 1
    }
}
