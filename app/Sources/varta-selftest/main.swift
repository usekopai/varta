import Foundation
import VartaCore

/// Plain-executable unit checks (the Command Line Tools ship neither XCTest nor Testing).
var failures = 0
var passed = 0

func expect(_ cond: @autoclosure () -> Bool, _ what: String, file: String = #file, line: Int = #line) {
    if cond() { passed += 1 } else { failures += 1; print("✗ \(what)  (\(URL(fileURLWithPath: file).lastPathComponent):\(line))") }
}

// Fuzzy: values checked against rapidfuzz 3.x.
expect(Fuzzy.ratio("chrome", "chrome") == 100, "ratio identical")
expect(abs(Fuzzy.ratio("google chrome", "chrome") - 63.1578947) < 0.001, "ratio partial")
expect(Fuzzy.tokenSetRatio("hacker news", "hacker news") == 100, "token set identical")
expect(Fuzzy.tokenSetRatio("the verge", "the verge - tech news") == 100, "token set subset")

// Candidates
expect(Candidates.words("Uh, play, um, Blinding Lights.") == ["play", ",", "Blinding", "Lights"], "words drop fillers, keep commas")
let s = Candidates.spans(Candidates.words("play the weeknd"))
expect(s.contains("the weeknd") && s.contains("weeknd") && !s.contains("the"), "spans skip stopword runs")
expect(Candidates.spans(Candidates.words((0..<40).map { "w\($0)" }.joined(separator: " "))).count <= 240, "spans fit the option limit")
expect(Candidates.domainCandidates(Candidates.words("go to github dot com")).contains("github.com"), "spoken domain candidate")
expect(Candidates.spokenDomain("docs dot typesafe dot ai") == "docs.typesafe.ai", "spoken domain")
expect(Candidates.spokenDomain("the verge") == "the verge", "not a domain")
let cl = Candidates.clauses(Candidates.words("search for flights to tokyo, and then hotels in kyoto and salt and pepper"))
expect(cl.parts == ["search for flights to tokyo", "hotels in kyoto", "salt", "pepper"] && cl.separators.count == 3, "clauses")
let apps = ["Google Chrome", "Spotify", "Notes", "Xcode", "Visual Studio Code"]
expect(Candidates.shortlistApps(Candidates.words("open chrome"), apps).first == "Google Chrome", "app alias")
expect(Candidates.shortlistApps(Candidates.words("launch vs code"), apps).first == "Visual Studio Code", "app alias 2")
expect(Candidates.core("the weather in paris") == "weather in paris", "core strips articles")

// URL quoting
expect(URLQuote.quote("blinding lights the weeknd") == "blinding%20lights%20the%20weeknd", "quote")
expect(URLQuote.quotePlus("what's the weather/today") == "what%27s+the+weather%2Ftoday", "quote_plus")

// JSON keeps order
expect(obj(("b", 1), ("a", "x")).description == #"{"b":1,"a":"x"}"#, "ordered json")

// Computer use is switched off
expect(!Features.computerUse && !Pipeline(jev: Jev { "" }).useComputerUse, "computer use is disabled by default")

// Accessibility tier guards
expect(AXTier.isAllowed(bundleID: "com.apple.Notes", menuPath: ["File", "New Note"], role: "AXMenuItem", enabled: true, fromMenuBar: true), "Notes new-note menu is supported")
for bundle in ["com.apple.Safari", "com.google.Chrome"] {
    for name in ["Zoom In", "Zoom Out"] {
        expect(AXTier.isAllowed(bundleID: bundle, menuPath: ["View", name], role: "AXMenuItem", enabled: true, fromMenuBar: true), "supported browser zoom menu")
    }
}
for path in [["File", "Delete Note"], ["File", "Send"], ["File", "Confirm"], ["File", "OK"], ["File", "New Note…"], ["Datei", "Neue Notiz"], ["Other", "File", "New Note"]] {
    expect(!AXTier.isAllowed(bundleID: "com.apple.Notes", menuPath: path, role: "AXMenuItem", enabled: true, fromMenuBar: true), "unknown or destructive menu denied")
}
expect(!AXTier.isAllowed(bundleID: "example.impostor", menuPath: ["File", "New Note"], role: "AXMenuItem", enabled: true, fromMenuBar: true), "unknown application denied despite familiar label")
expect(!AXTier.isAllowed(bundleID: "com.apple.Notes", menuPath: ["File", "New Note"], role: "AXButton", enabled: true, fromMenuBar: true), "button with allowed label denied")
expect(!AXTier.isAllowed(bundleID: "com.apple.Notes", menuPath: ["File", "New Note"], role: "AXMenuItem", enabled: false, fromMenuBar: true), "disabled command denied")
expect(!AXTier.isAllowed(bundleID: "com.apple.Notes", menuPath: ["File", "New Note"], role: "AXMenuItem", enabled: true, fromMenuBar: false), "window content posing as menu denied")

// Router prepare is deterministic and fits Jev's option limit
let prep = Router.prepare("search for flights to tokyo, hotels in kyoto and salt and pepper shakers", apps: apps, sites: [])
expect(prep.questions.map(\.0).prefix(3) == ["intent", "app", "app_for_task"], "question order")
expect(prep.questions.contains { $0.0 == "search_split_2" } && !prep.questions.contains { $0.0 == "search_split_3" }, "one split question per separator")
for (_, q) in prep.questions { expect((q["criteria"]?.object?.count ?? 0) <= 255, "choice option limit") }

await audioControlTests()
await browserControlTests()
noteTests()
appendNoteTests()

let pipelineFailures = await PipelineSelfTests.run()
expect(pipelineFailures.isEmpty, "pipeline cancellation and replacement regressions: \(pipelineFailures.joined(separator: "; "))")

expect(!AXTier.isAllowed(bundleID: "com.apple.Notes", menuPath: ["File › New Note"], role: "AXMenuItem", enabled: true, fromMenuBar: true), "menu path delimiter spoof denied")

print("\(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
