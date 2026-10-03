import Foundation
import VartaCore

func audioControlTests() async {
    final class Stub: Runner {
        var calls: [[String]] = []
        var responses: [ProcessResult]
        var afterCall: (() -> Void)?
        init(_ outputs: [String]) { responses = outputs.map { ProcessResult(code: 0, stdout: $0, stderr: "") } }
        func run(_ cmd: [String], timeout: TimeInterval) -> ProcessResult {
            calls.append(cmd); afterCall?()
            return responses.isEmpty ? ProcessResult(code: 1, stdout: "", stderr: "unexpected call") : responses.removeFirst()
        }
    }
    func plan(_ intent: String, _ args: [String: ArgValue]) -> Plan {
        var p = Plan(transcript: "test", intent: intent, intentConfidence: 1)
        p.route = .fastpath
        p.args = args.mapValues { Arg($0, 1) }
        return p
    }
    let volume = plan("audio_control", ["operation": .text("set"), "amount": .number(30)])
    let volumeRunner = Stub(["Volume set to 30%"])
    let result = Executor(runner: volumeRunner, apps: []).execute(volume)
    expect(result.ok && result.note == "Volume set to 30%", "volume reports executor readback")
    expect(Array(volumeRunner.calls[0].suffix(2)) == ["set", "30"], "volume values passed as arguments")
    let pipelineRunner = Stub(["Volume set to 30%"])
    var events: [PipelineEvent] = []
    let pipeline = Pipeline(jev: Jev { throw CancellationError() }, executor: Executor(runner: pipelineRunner, apps: []), runner: pipelineRunner, route: { _ in volume })
    await pipeline.run("set volume to 30 percent") { events.append($0) }
    let completed = events.contains { if case let .done(ok, summary) = $0 { return ok && summary == "Volume set to 30%" }; return false }
    expect(completed && pipelineRunner.calls.count == 1, "pipeline preserves audio result without another verification request")
    for n in [-1.0, 101.0, 30.5, Double.infinity, Double.nan] {
        let runner = Stub([])
        let p = plan("audio_control", ["operation": .text("set"), "amount": .number(n)])
        expect(!Executor(runner: runner, apps: []).execute(p).ok && runner.calls.isEmpty, "invalid volume cannot dispatch")
    }
    let denied = Stub([])
    denied.responses = [ProcessResult(code: 1, stdout: "", stderr: "Permission denied")]
    expect(!Executor(runner: denied, apps: []).execute(volume).ok, "audio failure is not reported as success")
    for player in ["Spotify", "Music"] {
        for operation in ["pause", "resume", "next", "previous"] {
            let runner = Stub(["playing", ["pause", "resume"].contains(operation) ? "verified" : "dispatched"])
            let p = plan("playback_control", ["operation": .text(operation), "player": .text(player)])
            expect(Executor(runner: runner, apps: ["Spotify", "Music"]).execute(p).ok && runner.calls.count == 2, "explicit player supports \(operation)")
            expect(runner.calls.allSatisfy { $0[2].contains("application \"\(player)\"") }, "only named player queried and controlled")
        }
    }
    let automatic = plan("playback_control", ["operation": .text("pause"), "player": .text("automatic")])
    for states in [["playing", "playing"], ["paused", "stopped"], ["not_running", "not_running"]] {
        let runner = Stub(states)
        expect(!Executor(runner: runner, apps: ["Spotify", "Music"]).execute(automatic).ok && runner.calls.count == 2, "ambiguous or absent player never receives a command")
    }
    let active = Stub(["paused", "playing", "verified"])
    expect(Executor(runner: active, apps: ["Spotify", "Music"]).execute(automatic).ok && active.calls.last![2].contains("application \"Music\""), "only playing player wins")
    let flag = CancelFlag()
    let cancelled = Stub(["playing"])
    cancelled.afterCall = { flag.cancel() }
    expect(!Executor(runner: cancelled, apps: ["Spotify", "Music"]).execute(automatic, cancel: flag).ok && cancelled.calls.count == 1, "cancellation after observation prevents playback dispatch")
    let malicious = Stub([])
    let bad = plan("playback_control", ["operation": .text("pause"), "player": .text("Spotify\" & do shell script")])
    expect(!Executor(runner: malicious, apps: []).execute(bad).ok && malicious.calls.isEmpty, "unknown player cannot become script source")

    func routed(_ intent: String, _ answers: [String: String], confidence: Double = 1) -> Plan {
        var values = answers.mapValues { obj(("choice", .string($0)), ("confidence", .number(confidence))) }
        values["intent"] = obj(("choice", .string(intent)), ("confidence", 1))
        return Router.interpret(Router.prepare("test", apps: ["Spotify", "Music"], sites: []), JevReply(answers: values, model: "test", inputTokens: 0, latencyMs: 0))
    }
    let absolute = routed("audio_control", ["audio_action": "set", "audio_amount": "30"])
    expect(absolute.route == .fastpath && absolute.args["amount"]?.number == 30, "absolute volume routes with numeric argument")
    let relative = routed("audio_control", ["audio_action": "increase", "audio_amount": "default"])
    expect(relative.route == .fastpath && relative.args["amount"]?.number == 10, "relative volume defaults to ten points")
    for answers in [["audio_action": "set", "audio_amount": "default"], ["audio_action": "increase", "audio_amount": "none"]] {
        expect(routed("audio_control", answers).route != .fastpath, "missing or invalid volume never routes automatically")
    }
    expect(routed("playback_control", ["playback_action": "pause", "control_player": "unsupported"]).route != .fastpath, "unsupported player does not fall back")
    expect(routed("playback_control", ["playback_action": "pause", "control_player": "Spotify"], confidence: 0.3).route != .fastpath, "uncertain player cannot dispatch")
}
