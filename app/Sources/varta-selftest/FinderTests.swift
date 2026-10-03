import Foundation
import VartaCore

func finderTests() async {
    expect(FinderRequest.parse("Open my Downloads folder") == FinderRequest("folder", "downloads"), "Finder common folder grammar")
    expect(FinderRequest.parse("open Music") == nil, "Music app is not a folder command")
    expect(FinderRequest.parse("open my music folder") == FinderRequest("folder", "music"), "explicit music folder supported")
    expect(FinderRequest.parse("Find files named launch") == FinderRequest("search", "launch"), "filename search extraction")
    expect(FinderRequest.parse("Find files named launch.") == FinderRequest("search", "launch"), "speech sentence punctuation removed from search")
    expect(FinderRequest.parse("Show launch.pdf in Finder") == FinderRequest("reveal", "launch.pdf"), "reveal filename preserves extension")
    expect(FinderRequest.parse("Show this file in Finder") == FinderRequest("current"), "current document grammar")
    for text in ["Delete launch.pdf", "Open ../../etc", "Find files named *", "Find files named ../secret", "Open Downloads and delete everything"] {
        expect(FinderRequest.parse(text) == nil, "unsupported Finder grammar: \(text)")
    }
    expect(FinderRequest.query("a\"b", exact: true) == "kMDItemFSName == \"a\\\"b\"cd", "metadata quotes escaped")
    expect(FinderRequest.query("a\\b", exact: true) == "kMDItemFSName == \"a\\\\b\"cd", "metadata backslashes escaped")
    final class Driver: FinderDriving {
        var opened: [URL] = [], revealed: [[URL]] = [], document: URL?
        func currentDocument() -> URL? { document }
        func openFolder(_ url: URL) -> Bool { opened.append(url); return true }
        func reveal(_ urls: [URL]) { revealed.append(urls) }
    }
    final class Stub: Runner {
        var output = ProcessResult(code: 0, stdout: "", stderr: "")
        var calls: [[String]] = []
        var after: (() -> Void)?
        func run(_ cmd: [String], timeout: TimeInterval) -> ProcessResult { calls.append(cmd); after?(); return output }
    }
    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("varta-finder-test-" + UUID().uuidString)
    do {
        try fm.createDirectory(at: root.appendingPathComponent("Downloads"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Other"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let one = root.appendingPathComponent("Downloads/launch.pdf"), two = root.appendingPathComponent("Other/launch.pdf")
        try Data().write(to: one); try Data().write(to: two)
        let driver = Driver(), runner = Stub(), controller = FinderController(driver: driver, runner: runner, home: root)
        expect(controller.execute(FinderRequest("folder", "downloads")).ok && driver.opened.count == 1 && runner.calls.isEmpty, "common folder opens without search")
        expect(!controller.execute(FinderRequest("folder", "documents")).ok, "missing common folder does not get created")
        expect(!controller.execute(FinderRequest("current")).ok && driver.revealed.isEmpty, "missing current document never guesses")
        expect(controller.execute(FinderRequest("current"), document: one).ok && driver.revealed.last == [one], "captured saved document revealed")
        runner.output = ProcessResult(code:0, stdout: one.path + "\0" + two.path + "\0", stderr: "")
        let before = driver.revealed.count
        expect(!controller.execute(FinderRequest("reveal", "launch.pdf")).ok && driver.revealed.count == before, "duplicate exact names never select arbitrary file")
        expect(controller.execute(FinderRequest("search", "launch")).ok && driver.revealed.last?.count == 2, "filename search reveals matching files")
        expect(runner.calls.last == ["/usr/bin/mdfind", "-0", "-onlyin", root.path, "kMDItemFSName == \"*launch*\"cd"], "search uses argv and home scope")
        runner.output = ProcessResult(code:0, stdout: one.path + "\0" + one.path + "\0" + "/etc/hosts\0", stderr: "")
        expect(controller.execute(FinderRequest("reveal", "launch.pdf")).ok && driver.revealed.last == [one], "results deduplicated and out-of-scope paths rejected")
        expect(!controller.execute(FinderRequest("reveal", "wrong.pdf")).ok, "actual basename rechecked after metadata search")
        let flag = CancelFlag(); runner.after = { flag.cancel() }
        let dispatches = driver.revealed.count
        expect(!controller.execute(FinderRequest("search", "launch"), cancel: flag).ok && driver.revealed.count == dispatches, "cancellation during search prevents reveal")
        runner.after = nil
        runner.output = ProcessResult(code:124, stdout:one.path + "\0", stderr:"timeout")
        expect(!controller.execute(FinderRequest("search", "launch")).ok && driver.revealed.count == dispatches, "failed search does not use partial results")
        var events: [PipelineEvent] = []
        driver.document = one
        let pipeline = Pipeline(jev: Jev { throw CancellationError() }, executor: Executor(apps: [], finderController: controller), route: { _ in
            driver.document = two
            var p = Plan(transcript:"test",intent:"finder_control",intentConfidence:1); p.route = .fastpath
            p.args = ["operation":Arg(.text("current"),1)]
            return p
        })
        await pipeline.run("show this file in Finder") { events.append($0) }
        expect(driver.revealed.last == [one] && events.contains { if case let .done(ok, _) = $0 { return ok }; return false }, "pipeline reveals captured document and preserves dispatch result")
    } catch { expect(false, "Finder temporary fixture failed: \(error)") }
}
