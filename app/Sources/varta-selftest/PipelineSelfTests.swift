import Foundation
import VartaCore

/// Offline regressions: no network, installed-app lookup, permissions, or subprocess execution.
enum PipelineSelfTests {
    static func run() async -> [String] {
        var failures: [String] = []
        var plan = Plan(transcript: "open example", intent: "open_site", intentConfidence: 1)
        plan.route = .fastpath
        plan.urls = ["https://example.com", "https://example.org"]
        let jev = Jev(auth: { throw CancellationError() })

        let entryCancel = CancelFlag()
        entryCancel.cancel()
        let entryRunner = RecordingRunner()
        var routeCalls = 0
        var entryEvents: [PipelineEvent] = []
        let entry = Pipeline(jev: jev, executor: Executor(runner: entryRunner, apps: []), runner: entryRunner,
                             route: { _ in routeCalls += 1; return plan })
        await entry.run("open example", cancel: entryCancel) { entryEvents.append($0) }
        if routeCalls != 0 || !entryRunner.commands.isEmpty || !endedStopped(entryEvents) {
            failures.append("entry cancellation must skip routing and execution and report Stopped")
        }

        let routeCancel = CancelFlag()
        let routeRunner = RecordingRunner()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var routeEvents: [PipelineEvent] = []
        let suspended = Pipeline(jev: jev, executor: Executor(runner: routeRunner, apps: []), runner: routeRunner,
            route: { _ in
                started.continuation.yield(())
                for await _ in release.stream { break }
                return plan
            })
        suspended.check = false
        let task = Task { await suspended.run("open example", cancel: routeCancel) { routeEvents.append($0) } }
        for await _ in started.stream { break }
        routeCancel.cancel()
        release.continuation.yield(())
        release.continuation.finish()
        started.continuation.finish()
        await task.value
        if !routeRunner.commands.isEmpty || !endedStopped(routeEvents) {
            failures.append("cancellation while route is suspended must prevent returned plan execution")
        }

        let oldCancel = CancelFlag()
        let replacementRunner = RecordingRunner()
        let oldStarted = AsyncStream<Void>.makeStream()
        let oldRelease = AsyncStream<Void>.makeStream()
        var oldEvents: [PipelineEvent] = []
        var replacementEvents: [PipelineEvent] = []
        var replacementPlan = plan
        replacementPlan.urls = ["https://example.net"]
        let replacing = Pipeline(jev: jev, executor: Executor(runner: replacementRunner, apps: []), runner: replacementRunner,
            route: { text in
                if text == "old command" {
                    oldStarted.continuation.yield(())
                    for await _ in oldRelease.stream { break }
                    return plan
                }
                return replacementPlan
            })
        replacing.check = false
        let oldTask = Task { await replacing.run("old command", cancel: oldCancel) { oldEvents.append($0) } }
        for await _ in oldStarted.stream { break }
        oldCancel.cancel()
        await replacing.run("replacement command", cancel: CancelFlag()) { replacementEvents.append($0) }
        oldRelease.continuation.yield(())
        oldRelease.continuation.finish()
        oldStarted.continuation.finish()
        await oldTask.value
        if replacementRunner.commands != [["open", "https://example.net"]] || !endedStopped(oldEvents) {
            failures.append("replacement command must run while cancelled older route never dispatches")
        }
        if case let .done(ok, _)? = replacementEvents.last {
            if !ok { failures.append("replacement command must complete successfully") }
        } else {
            failures.append("replacement command must report completion")
        }

        let between = CancelFlag()
        let multiRunner = RecordingRunner(onRun: { between.cancel() })
        let result = Executor(runner: multiRunner, apps: []).execute(plan, cancel: between)
        if multiRunner.commands.count != 1 || result.ran.count != 1 || result.ok || result.note != "Stopped" {
            failures.append("cancellation after first URL dispatch must prevent remaining subprocesses")
        }

        let normalRunner = RecordingRunner()
        let normal = Executor(runner: normalRunner, apps: []).execute(plan)
        if normalRunner.commands.count != 2 || !normal.ok {
            failures.append("uncancelled multi-URL execution must still dispatch both URLs")
        }
        return failures
    }

    private static func endedStopped(_ events: [PipelineEvent]) -> Bool {
        guard case let .done(ok, summary)? = events.last else { return false }
        return !ok && summary == "Stopped"
    }

    private final class RecordingRunner: Runner {
        var commands: [[String]] = []
        let onRun: () -> Void
        init(onRun: @escaping () -> Void = {}) { self.onRun = onRun }
        func run(_ cmd: [String], timeout: TimeInterval) -> ProcessResult {
            commands.append(cmd)
            onRun()
            return ProcessResult(code: 0, stdout: "", stderr: "")
        }
    }
}
