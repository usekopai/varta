import AppKit
import ApplicationServices
import Foundation

public enum BrowserAction: String, CaseIterable {
    case nextTab = "next_tab", previousTab = "previous_tab", newTab = "new_tab"
    case closeTab = "close_tab", reopenTab = "reopen_tab"
    case back, forward, reload, zoomIn = "zoom_in", zoomOut = "zoom_out"

    public var description: String {
        switch self {
        case .nextTab: return "Select the next tab"
        case .previousTab: return "Select the previous tab"
        case .newTab: return "Open one new tab"
        case .closeTab: return "Close only the current tab"
        case .reopenTab: return "Reopen the last closed tab"
        case .back: return "Go back one page"
        case .forward: return "Go forward one page"
        case .reload: return "Reload the current page"
        case .zoomIn: return "Zoom in one step"
        case .zoomOut: return "Zoom out one step"
        }
    }

    /// Only exact direct menu leaves are eligible; never substitute a window operation.
    public func menuPath(bundleID: String) -> [String]? {
        guard ["com.google.Chrome", "com.apple.Safari"].contains(bundleID) else { return nil }
        let chrome = bundleID == "com.google.Chrome"
        switch self {
        case .nextTab: return chrome ? ["Tab", "Select Next Tab"] : ["Window", "Show Next Tab"]
        case .previousTab: return chrome ? ["Tab", "Select Previous Tab"] : ["Window", "Show Previous Tab"]
        case .newTab: return ["File", "New Tab"]
        case .closeTab: return ["File", "Close Tab"]
        case .reopenTab: return chrome ? ["File", "Reopen Closed Tab"] : ["History", "Reopen Last Closed Tab"]
        case .back: return ["History", "Back"]
        case .forward: return ["History", "Forward"]
        case .reload: return ["View", chrome ? "Reload This Page" : "Reload Page"]
        case .zoomIn: return ["View", "Zoom In"]
        case .zoomOut: return ["View", "Zoom Out"]
        }
    }
}

public struct BrowserTarget: Equatable {
    public let bundleID: String
    public let pid: Int32
    public let launched: Date?
    public init(bundleID: String, pid: Int32, launched: Date?) {
        self.bundleID = bundleID; self.pid = pid; self.launched = launched
    }
    public var name: String { bundleID == "com.google.Chrome" ? "Chrome" : "Safari" }
}

public protocol BrowserDriving {
    func frontmost() -> BrowserTarget?
    func running(bundleID: String) -> BrowserTarget?
    func activate(_ target: BrowserTarget) -> Bool
    func press(_ action: BrowserAction, target: BrowserTarget, cancel: CancelFlag) -> Bool
}

public struct NativeBrowserDriver: BrowserDriving {
    public init() {}
    private func target(_ app: NSRunningApplication?) -> BrowserTarget? {
        guard let app, !app.isTerminated, let id = app.bundleIdentifier,
              ["com.google.Chrome", "com.apple.Safari"].contains(id) else { return nil }
        return BrowserTarget(bundleID: id, pid: app.processIdentifier, launched: app.launchDate)
    }
    public func frontmost() -> BrowserTarget? { target(NSWorkspace.shared.frontmostApplication) }
    public func running(bundleID: String) -> BrowserTarget? {
        target(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first)
    }
    public func activate(_ target: BrowserTarget) -> Bool {
        guard running(bundleID: target.bundleID) == target,
              let app = NSRunningApplication(processIdentifier: target.pid) else { return false }
        return app.activate(options: [])
    }
    public func press(_ action: BrowserAction, target: BrowserTarget, cancel: CancelFlag) -> Bool {
        guard AXIsProcessTrusted(), !cancel.isSet, !Task.isCancelled,
              frontmost() == target, running(bundleID: target.bundleID) == target,
              let path = action.menuPath(bundleID: target.bundleID) else { return false }
        let root = AXUIElementCreateApplication(target.pid)
        // Leave sheets and modal dialogs for the user; do not dismiss them or send keys.
        if let v = AXTier.attr(root, kAXFocusedWindowAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() {
            let window = v as! AXUIElement
            if (AXTier.attr(window, kAXModalAttribute) as? Bool) == true ||
                AXTier.children(window).contains(where: { AXTier.string($0, kAXRoleAttribute) == kAXSheetRole as String }) { return false }
        }
        let app = target.bundleID == "com.google.Chrome" ? "Google Chrome" : "Safari"
        let matches = AXTier.controls(app: app, includeBrowserControls: true).filter { $0.label == path.joined(separator: " › ") }
        guard matches.count == 1, frontmost() == target else { return false }
        return AXTier.press(matches[0], cancel: cancel)
    }
}

public final class BrowserController {
    let driver: BrowserDriving
    public init(driver: BrowserDriving = NativeBrowserDriver()) { self.driver = driver }
    public func captureForeground() -> BrowserTarget? { driver.frontmost() }

    public func execute(operation: String?, browser: String?, origin: BrowserTarget?, cancel: CancelFlag) -> ExecResult {
        var result = ExecResult()
        func failed(_ message: String) -> ExecResult {
            var r = result; r.ok = false; r.note = message; return r
        }
        guard !cancel.isSet, !Task.isCancelled else { return failed("Stopped") }
        guard let operation, let action = BrowserAction(rawValue: operation), let browser,
              ["foreground", "Google Chrome", "Safari"].contains(browser) else {
            return failed("Specify a browser control for Chrome or Safari")
        }
        let target: BrowserTarget
        if browser == "foreground" {
            guard let origin, action.menuPath(bundleID: origin.bundleID) != nil else {
                return failed("Say Chrome or Safari to choose a browser")
            }
            guard driver.frontmost() == origin, driver.running(bundleID: origin.bundleID) == origin else {
                return failed("The foreground browser changed. Please try again")
            }
            target = origin
        } else {
            let id = browser == "Google Chrome" ? "com.google.Chrome" : "com.apple.Safari"
            guard let running = driver.running(bundleID: id) else { return failed("Open \(browser) first, then repeat the command") }
            target = running
            if driver.frontmost() != target {
                guard !cancel.isSet, !Task.isCancelled else { return failed("Stopped") }
                guard driver.activate(target) else { return failed("Could not bring \(target.name) forward") }
                for _ in 0..<20 {
                    if cancel.isSet || Task.isCancelled { return failed("Stopped") }
                    if driver.frontmost() == target { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
        guard !cancel.isSet, !Task.isCancelled else { return failed("Stopped") }
        guard driver.frontmost() == target, driver.running(bundleID: target.bundleID) == target else {
            return failed("The browser changed before the action. Please try again")
        }
        guard driver.press(action, target: target, cancel: cancel) else {
            if cancel.isSet || Task.isCancelled { return failed("Stopped") }
            return failed("\(target.name): command unavailable. Check Accessibility access, open tabs, and dialogs")
        }
        result.ran = ["\(target.name): \(action.description)"]
        result.note = "Requested: \(action.description.lowercased()) in \(target.name)"
        return result
    }
}
