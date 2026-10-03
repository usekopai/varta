import Foundation
import VartaCore

func appendNoteTests() {
    let large = SystemRunner().run(["/usr/bin/awk", "BEGIN { for (i=0; i<20000; i++) { print \"abcdefgh\"; print \"ijklmnop\" > \"/dev/stderr\" } }"], timeout: 10)
    expect(large.code == 0 && large.stdout.count == 180000 && large.stderr.count == 180000, "runner drains both pipes without blocking on large note output")
    func b64(_ value: String) -> String { Data(value.utf8).base64EncodedString() }
    let oldHTML = "<h1>Launch Ideas</h1><div>First idea</div>"
    let oldText = "Launch Ideas\nFirst idea"
    let snapshot = "ok\n" + ["note-id", oldHTML, oldText].map(b64).joined(separator: "\n")
    let content = "Agentic Harness Evaluator"
    final class Stub: Runner {
        var replies: [String]; var calls: [[String]] = []; var callback: (() -> Void)?
        init(_ replies: [String]) { self.replies = replies }
        func run(_ cmd: [String], timeout: TimeInterval) -> ProcessResult {
            calls.append(cmd); callback?()
            return replies.isEmpty ? ProcessResult(code: 124, stdout: "", stderr: "timeout") : ProcessResult(code: 0, stdout: replies.removeFirst(), stderr: "")
        }
    }
    var plan = Plan(transcript: "test", intent: "append_note", intentConfidence: 1)
    plan.route = .fastpath; plan.args = ["title": Arg(.text("Launch Ideas"), 1), "body": Arg(.text(content), 1)]
    let good = Stub([snapshot, "ok\n" + b64(oldText + "\n" + content)])
    let result = Executor(runner: good, apps: ["Notes"]).execute(plan)
    expect(result.ok && good.calls.count == 2 && good.calls[1].suffix(2).first == oldHTML, "append preserves original HTML and verifies full prior text plus addition")
    expect(!result.ran.joined().contains("First idea"), "existing note content excluded from command logs")
    for response in ["missing", "ambiguous", "unsupported", "ok\nmalformed"] {
        let stub = Stub([response])
        expect(!Executor(runner: stub, apps: ["Notes"]).execute(plan).ok && stub.calls.count == 1, "lookup failure never writes or creates a note")
    }
    for response in ["changed", "ok\n" + b64(content)] {
        let stub = Stub([snapshot, response])
        expect(!Executor(runner: stub, apps: ["Notes"]).execute(plan).ok && stub.calls.count == 2, "concurrent edit or lost content cannot report success or retry")
    }
    let timeout = Stub([snapshot])
    expect(!Executor(runner: timeout, apps: ["Notes"]).execute(plan).ok && timeout.calls.count == 2, "uncertain append does not retry")
    let flag = CancelFlag(), stopped = Stub([snapshot]); stopped.callback = { flag.cancel() }
    expect(!Executor(runner: stopped, apps: ["Notes"]).execute(plan, cancel: flag).ok && stopped.calls.count == 1, "cancel after lookup prevents append")
    expect(NoteAppend.supportsHTML("<div><b><span style=\"font-size: 24px\">Launch Ideas</span></b><br></div>"), "native Notes heading markup remains appendable")
    expect(!NoteAppend.supportsHTML("<span style=\"font-size: 24px; background: url(x)\">x</span>"), "font-size exception cannot admit other styles")
    let explicit = NoteText("In the Launch Ideas Note, add an item called Eggs").explicitAppend
    expect(explicit?.title == "Launch Ideas" && explicit?.body == "Eggs", "explicit spoken delimiters identify both fields")
    expect(NoteText("Replace Launch Ideas with Eggs").explicitAppend == nil, "replacement has no append delimiter confirmation")
    expect(NoteAppend.supportsHTML(oldHTML), "simple note markup supported")
    for html in ["<table>data</table>", "<div><img src='x'></div>", "<ul><li>item</li></ul>", "<div data-checked='true'>task</div>", "<object>attachment</object>"] {
        expect(!NoteAppend.supportsHTML(html), "rich note markup cannot be rewritten")
    }
    func routed(_ fields: [String: String], boundaryConfidence: Double = 1, transcript: String = "Add Agentic Harness Evaluator to my Launch Ideas note") -> Plan {
        var answers = fields.mapValues { obj(("choice", .string($0)), ("confidence", .number(boundaryConfidence))) }
        answers["note_append_supported"] = obj(("choice", .string(fields["note_append_supported"] ?? "none")), ("confidence", 1))
        answers["intent"] = obj(("choice", "append_note"), ("confidence", 1))
        return Router.interpret(Router.prepare(transcript, apps: ["Notes"], sites: []), JevReply(answers: answers, model: "test", inputTokens: 0, latencyMs: 0))
    }
    var fields = ["note_append_supported":"yes", "note_title_start":"6", "note_title_end":"8", "note_body_start":"1", "note_body_end":"4"]
    expect(routed(fields, boundaryConfidence: 0.5).route == .fastpath, "explicit delimiters confirm correct low-confidence model boundaries")
    let noisy = ["note_append_supported":"yes", "note_title_start":"2", "note_title_end":"5", "note_body_start":"10", "note_body_end":"11"]
    let corrected = routed(noisy, boundaryConfidence: 0.5, transcript: "In the Launch Ideas Note, add an item called Eggs")
    expect(corrected.route == .fastpath && corrected.arg("title") == "Launch Ideas" && corrected.arg("body") == "Eggs", "explicit grammar excludes Note punctuation despite noisy model boundaries")
    var unsupported = noisy; unsupported["note_append_supported"] = "none"
    expect(routed(unsupported, transcript: "In the Launch Ideas Note, add an item called Eggs").route != .fastpath, "explicit extraction retains semantic support gate")
    let picked = routed(fields)
    expect(picked.route == .fastpath && picked.arg("title") == "Launch Ideas" && picked.arg("body") == content, "append extracts named target and literal new item")
    fields["note_title_start"] = "none"; fields["note_title_end"] = "none"
    expect(routed(fields, transcript: "Add Agentic Harness Evaluator to my note").route != .fastpath, "append cannot invent a default target title")
}
