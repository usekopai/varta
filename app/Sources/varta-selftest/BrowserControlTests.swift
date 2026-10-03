import Foundation
import VartaCore

func browserControlTests() async {
    let chrome = BrowserTarget(bundleID: "com.google.Chrome", pid: 101, launched: Date(timeIntervalSince1970: 1))
    let safari = BrowserTarget(bundleID: "com.apple.Safari", pid: 102, launched: Date(timeIntervalSince1970: 2))
    final class Driver: BrowserDriving {
        var current: BrowserTarget?
        var available: [String: BrowserTarget] = [:]
        var pressed: [(BrowserAction, BrowserTarget)] = []
        var activations = 0
        var allowPress = true
        var onActivate: (() -> Void)?
        init(_ current: BrowserTarget?, _ running: [BrowserTarget]) {
            self.current = current; available = Dictionary(uniqueKeysWithValues: running.map { ($0.bundleID, $0) })
        }
        func frontmost() -> BrowserTarget? { current }
        func running(bundleID: String) -> BrowserTarget? { available[bundleID] }
        func activate(_ target: BrowserTarget) -> Bool { activations += 1; current = target; onActivate?(); return true }
        func press(_ action: BrowserAction, target: BrowserTarget, cancel: CancelFlag) -> Bool {
            guard allowPress, !cancel.isSet, current == target else { return false }
            pressed.append((action, target)); return true
        }
    }
    for target in [chrome, safari] {
        for action in BrowserAction.allCases {
            let driver = Driver(target, [chrome, safari])
            let result = BrowserController(driver: driver).execute(operation: action.rawValue, browser: "foreground", origin: target, cancel: CancelFlag())
            expect(result.ok && driver.pressed.count == 1 && driver.pressed[0].0 == action && driver.activations == 0, "foreground \(target.name) \(action.rawValue)")
            expect(AXTier.isAllowed(bundleID: target.bundleID, menuPath: action.menuPath(bundleID: target.bundleID)!, role: "AXMenuItem", enabled: true, fromMenuBar: true), "exact browser menu allowed")
        }
        for path in [["File", "Close Window"], ["File", "Close All Tabs"], ["File", "Reopen Closed Window"], ["History", "Reopen Last Closed Window"], ["Window", "Other", "Show Next Tab"]] {
            expect(!AXTier.isAllowed(bundleID: target.bundleID, menuPath: path, role: "AXMenuItem", enabled: true, fromMenuBar: true), "window and nested operations cannot substitute for tab controls")
        }
    }
    let absent = Driver(nil, [chrome])
    expect(!BrowserController(driver: absent).execute(operation: "back", browser: "foreground", origin: nil, cancel: CancelFlag()).ok && absent.activations == 0 && absent.pressed.isEmpty, "unnamed command outside browser asks for target")
    let moved = Driver(safari, [chrome, safari])
    expect(!BrowserController(driver: moved).execute(operation: "close_tab", browser: "foreground", origin: chrome, cancel: CancelFlag()).ok && moved.pressed.isEmpty, "focus change during routing prevents close")
    let restarted = BrowserTarget(bundleID: chrome.bundleID, pid: chrome.pid, launched: Date(timeIntervalSince1970: 99))
    let stale = Driver(restarted, [restarted])
    expect(!BrowserController(driver: stale).execute(operation: "close_tab", browser: "foreground", origin: chrome, cancel: CancelFlag()).ok && stale.pressed.isEmpty, "restarted browser cannot inherit old command")
    let explicit = Driver(safari, [chrome, safari])
    expect(BrowserController(driver: explicit).execute(operation: "next_tab", browser: "Google Chrome", origin: safari, cancel: CancelFlag()).ok && explicit.activations == 1 && explicit.pressed.first?.1 == chrome, "named browser overrides foreground")
    let missing = Driver(chrome, [chrome])
    expect(!BrowserController(driver: missing).execute(operation: "new_tab", browser: "Safari", origin: chrome, cancel: CancelFlag()).ok && missing.pressed.isEmpty, "closed named browser does not fall back")
    for (operation, browser) in [("close_window", "Safari"), ("back", "Firefox"), ("back", "Safari\" & quit")] {
        let driver = Driver(chrome, [chrome, safari])
        expect(!BrowserController(driver: driver).execute(operation: operation, browser: browser, origin: chrome, cancel: CancelFlag()).ok && driver.activations == 0 && driver.pressed.isEmpty, "unknown operation or target rejected before activation")
    }
    let cancelled = CancelFlag()
    let activation = Driver(safari, [chrome, safari])
    activation.onActivate = { cancelled.cancel() }
    expect(!BrowserController(driver: activation).execute(operation: "close_tab", browser: "Google Chrome", origin: safari, cancel: cancelled).ok && activation.pressed.isEmpty, "cancel during activation prevents menu press")
    let unavailable = Driver(chrome, [chrome]); unavailable.allowPress = false
    expect(!BrowserController(driver: unavailable).execute(operation: "reload", browser: "foreground", origin: chrome, cancel: CancelFlag()).ok, "disabled or unavailable command cannot report success")

    func route(_ action: String, _ browser: String, confidence: Double = 1) -> Plan {
        let answers: [String: JSON] = ["intent": obj(("choice", "browser_control"), ("confidence", 1)), "browser_action": obj(("choice", .string(action)), ("confidence", .number(confidence))), "control_browser": obj(("choice", .string(browser)), ("confidence", .number(confidence)))]
        return Router.interpret(Router.prepare("test", apps: ["Google Chrome", "Safari"], sites: []), JevReply(answers: answers, model: "test", inputTokens: 0, latencyMs: 0))
    }
    for action in BrowserAction.allCases { expect(route(action.rawValue, "foreground").route == .fastpath, "browser action routes directly") }
    expect(route("none", "foreground").route != .fastpath && route("close_tab", "unsupported").route != .fastpath && route("back", "Safari", confidence: 0.3).route != .fastpath, "invalid and uncertain browser routes cannot dispatch")
    let pipelineDriver = Driver(chrome, [chrome, safari])
    let controller = BrowserController(driver: pipelineDriver)
    let pipeline = Pipeline(jev: Jev { throw CancellationError() }, executor: Executor(apps: [], browserController: controller), route: { _ in
        pipelineDriver.current = safari
        return route("close_tab", "foreground")
    })
    var events: [PipelineEvent] = []
    await pipeline.run("close this tab") { events.append($0) }
    expect(pipelineDriver.pressed.isEmpty && events.contains { if case let .done(ok, _) = $0 { return !ok }; return false }, "pipeline preserves foreground from before routing")
}
