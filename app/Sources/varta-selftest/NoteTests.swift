import Foundation
import VartaCore

func noteTests() {
    let text = NoteText("Create a note called Groceries with eggs, milk, and bread.")
    expect(text.slice(start: "6", end: "10") == "eggs, milk, and bread.", "note extraction preserves punctuation")
    expect(text.slice(start: "-1", end: "3") == nil && text.slice(start: "4", end: "2") == nil && text.slice(start: "0", end: "999") == nil, "invalid note boundaries rejected")
    let long = NoteText((0...200).map { "word\($0)" }.joined(separator: " "))
    expect(!long.supported && long.slice(start: "0", end: "10") == nil, "long requests reject rather than truncate")
    expect(NoteText.html("<script>&\"'\ntext") == "&lt;script&gt;&amp;&quot;&#39;<br>text", "dictated HTML is escaped")
    final class RunnerStub: Runner {
        var calls: [[String]] = []
        var outputs: [ProcessResult]
        var callback: (() -> Void)?
        init(_ responses: [String]) { outputs = responses.map { ProcessResult(code: 0, stdout: $0, stderr: "") } }
        func run(_ cmd: [String], timeout: TimeInterval) -> ProcessResult {
            calls.append(cmd); callback?()
            return outputs.isEmpty ? ProcessResult(code: 1, stdout: "", stderr: "denied") : outputs.removeFirst()
        }
    }
    func plan(_ title: String = "Groceries", _ body: String = "eggs, milk, and bread.") -> Plan {
        var p = Plan(transcript: "test", intent: "create_note", intentConfidence: 1)
        p.route = .fastpath; p.args = ["title": Arg(.text(title), 1), "body": Arg(.text(body), 1)]
        return p
    }
    let runner = RunnerStub(["note-id", "Groceries\neggs, milk, and bread.\n"])
    let result = Executor(runner: runner, apps: ["Notes"]).execute(plan())
    expect(result.ok && result.note == "Created note: Groceries" && runner.calls.count == 2, "saved note read back by identifier")
    expect(runner.calls[1].last == "note-id" && !runner.calls[0][2].contains("Groceries"), "content and identifier travel as script arguments")
    let unreadable = RunnerStub(["note-id"])
    let unreadableResult = Executor(runner: unreadable, apps: ["Notes"]).execute(plan())
    expect(!unreadableResult.ok && unreadableResult.note.contains("Note created") && unreadable.calls.count == 2, "failed readback reports existing creation without retry")
    let mismatch = RunnerStub(["note-id", "Different text"])
    expect(!Executor(runner: mismatch, apps: ["Notes"]).execute(plan()).ok && mismatch.calls.count == 2, "mismatch never retries creation")
    let failure = RunnerStub([])
    expect(!Executor(runner: failure, apps: ["Notes"]).execute(plan()).ok && failure.calls.count == 1, "uncertain create is not retried")
    let cancelled = CancelFlag(); let stopped = RunnerStub(["note-id"]); stopped.callback = { cancelled.cancel() }
    expect(!Executor(runner: stopped, apps: ["Notes"]).execute(plan(), cancel: cancelled).ok && stopped.calls.count == 1, "cancel after creation prevents next dispatch")
    for p in [plan(""), plan(String(repeating: "x", count: 201)), plan("Title", "bad\0text")] {
        let r = RunnerStub([])
        expect(!Executor(runner: r, apps: ["Notes"]).execute(p).ok && r.calls.isEmpty, "invalid note rejected before creation")
    }
    func routed(_ transcript: String, _ fields: [String: String]) -> Plan {
        var answers = fields.mapValues { obj(("choice", .string($0)), ("confidence", 1)) }
        answers["intent"] = obj(("choice", "create_note"), ("confidence", 1))
        return Router.interpret(Router.prepare(transcript, apps: ["Notes"], sites: []), JevReply(answers: answers, model: "test", inputTokens: 0, latencyMs: 0))
    }
    var fields = ["note_supported": "yes", "note_title_start": "4", "note_title_end": "5", "note_body_start": "6", "note_body_end": "10"]
    let routedPlan = routed(text.text, fields)
    expect(routedPlan.route == .fastpath && routedPlan.arg("title") == "Groceries" && routedPlan.arg("body") == "eggs, milk, and bread.", "note routing keeps title and body separate")
    fields["note_body_start"] = "4"
    expect(routed(text.text, fields).route != .fastpath, "overlapping fields cannot execute")
    fields["note_supported"] = "none"
    expect(routed(text.text, fields).route != .fastpath, "unsupported note operation cannot execute")
    let blank = routed("make a new note", ["note_supported":"yes", "note_title_start":"none", "note_title_end":"none", "note_body_start":"none", "note_body_end":"none"])
    expect(blank.route == .fastpath && blank.arg("title") == "Quick note" && blank.arg("body") == "", "blank note remains supported")
    let bodyOnly = routed("Take a note: investigate the installer", ["note_supported":"yes", "note_title_start":"none", "note_title_end":"none", "note_body_start":"3", "note_body_end":"6"])
    expect(bodyOnly.route == .fastpath && bodyOnly.arg("title") == "Quick note" && bodyOnly.arg("body") == "investigate the installer", "untitled dictation gets default title")
}
