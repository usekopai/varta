import AppKit
import ApplicationServices
import Foundation

/// A narrow accessibility tier for known, low-impact menu commands. Window controls and
/// arbitrary menu items are never exposed to the model or eligible for automatic presses.
public struct AXControl {
    public let label: String
    fileprivate let element: AXUIElement
    fileprivate let processID: pid_t
    fileprivate let bundleID: String
    fileprivate let launchDate: Date?
    fileprivate let menuPath: [String]
}

public enum AXTier {
    static let maxOptions = 200

    /// Exact English menu paths only. Unknown apps, localized labels, dialogs, buttons,
    /// submenus and disabled controls fail closed. Extend deliberately with per-app tests.
    public static func isAllowed(bundleID: String, menuPath: [String], role: String,
                                 enabled: Bool, fromMenuBar: Bool) -> Bool {
        guard fromMenuBar, enabled, role == kAXMenuItemRole as String else { return false }
        switch bundleID {
        case "com.apple.Notes":
            return menuPath == ["File", "New Note"]
        case "com.apple.Safari", "com.google.Chrome":
            return BrowserAction.allCases.contains { $0.menuPath(bundleID: bundleID) == menuPath }
        default:
            return false
        }
    }

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        (attr(el, name) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func canPress(_ el: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let list = names as? [String] else { return false }
        return list.contains(kAXPressAction as String)
    }

    static func belongs(_ el: AXUIElement, to pid: pid_t) -> Bool {
        var actual: pid_t = 0
        return AXUIElementGetPid(el, &actual) == .success && actual == pid
    }

    public static func pid(of app: String) -> pid_t? {
        NSWorkspace.shared.runningApplications.first { $0.localizedName == app }?.processIdentifier
    }

    public static func controls(app: String, includeBrowserControls: Bool = false) -> [AXControl] {
        guard let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == app }) else { return [] }
        return controls(in: running, includeBrowserControls: includeBrowserControls)
    }

    /// Read only direct leaf menu commands from the actual process's menu bar. A window
    /// button titled "File › New Note" cannot enter this list.
    static func controls(in running: NSRunningApplication, includeBrowserControls: Bool = false) -> [AXControl] {
        guard !running.isTerminated, let bundleID = running.bundleIdentifier,
              ["com.apple.Notes", "com.apple.Safari", "com.google.Chrome"].contains(bundleID) else { return [] }
        let pid = running.processIdentifier
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard let value = attr(root, kAXMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return [] }
        let bar = value as! AXUIElement
        guard string(bar, kAXRoleAttribute) == kAXMenuBarRole as String, belongs(bar, to: pid) else { return [] }
        var out: [AXControl] = []
        for top in children(bar) {
            guard string(top, kAXRoleAttribute) == kAXMenuBarItemRole as String,
                  belongs(top, to: pid), let title = attr(top, kAXTitleAttribute) as? String else { continue }
            for menu in children(top) {
                guard string(menu, kAXRoleAttribute) == kAXMenuRole as String, belongs(menu, to: pid) else { continue }
                for item in children(menu) {
                    guard let itemTitle = attr(item, kAXTitleAttribute) as? String else { continue }
                    let path = [title, itemTitle]
                    // The open-ended app-task selector retains its original narrow scope.
                    // Additional browser operations require an explicit browser_control plan.
                    if !includeBrowserControls, bundleID != "com.apple.Notes",
                       path != ["View", "Zoom In"], path != ["View", "Zoom Out"] { continue }
                    guard isAllowed(bundleID: bundleID, menuPath: path,
                                    role: string(item, kAXRoleAttribute) ?? "",
                                    enabled: (attr(item, kAXEnabledAttribute) as? Bool) == true,
                                    fromMenuBar: true),
                          belongs(item, to: pid), children(item).isEmpty, canPress(item) else { continue }
                    out.append(AXControl(label: path.joined(separator: " › "), element: item,
                                         processID: pid, bundleID: bundleID,
                                         launchDate: running.launchDate, menuPath: path))
                }
            }
        }
        // Ambiguous duplicate menu paths are not safe automatic actions.
        return out.filter { control in out.filter { $0.menuPath == control.menuPath }.count == 1 }
    }

    public struct Decision {
        public let control: AXControl?
        public let confidence: Double
        public let simple: Double
        public let completes: Double?
        public let reason: String

        /// Press only when every gate agrees; anything doubtful is left for the user.
        public var shouldPress: Bool {
            control != nil && confidence >= AXTier.minChoice && simple >= AXTier.minSimple && (completes ?? 0) >= AXTier.minCompletes
        }
    }

    // Tuned on 16 + 12 live cases (2026-09-28). The last gate rejected every wrong press (p <= 0.09)
    // while passing most real one-press commands (>= 0.50). These model gates do not replace the allowlist.
    static let minChoice = 0.60
    static let minSimple = 0.60
    static let minCompletes = 0.45

    /// Menu paths read literally ("File › …" sounds like the File menu must be opened first), so
    /// the confirmation question sees the control as a command.
    static func describe(_ label: String) -> JSON {
        if label.contains(" › ") {
            var parts = label.components(separatedBy: " › ")
            let name = parts.removeLast()
            return obj(("name", .string(name)), ("kind", "menu command"), ("menu", .string(parts.joined(separator: " › "))))
        }
        if let open = label.range(of: " (", options: .backwards), label.hasSuffix(")") {
            return obj(("name", .string(String(label[..<open.lowerBound]))), ("kind", .string(String(label[open.upperBound...].dropLast()))))
        }
        return obj(("name", .string(label)))
    }

    /// Two rounds of Jev. First, together: which control, and is the request one simple action?
    /// Then, only if both look good: does running *that* control finish the request?
    public static func decide(jev: Jev, command: String, app: String, controls: [AXControl], cancel: CancelFlag = CancelFlag()) async throws -> Decision {
        try checkCancellation(cancel)
        let controls = controls.filter { isAllowed(bundleID: $0.bundleID, menuPath: $0.menuPath, role: kAXMenuItemRole as String, enabled: true, fromMenuBar: true) }
        guard !controls.isEmpty else { return Decision(control: nil, confidence: 0, simple: 0, completes: nil, reason: "no supported menu commands") }
        let words = command.lowercased()
        // Keep the options relevant and under the 255-option limit.
        let ranked = controls.enumerated().sorted { a, b in
            let sa = Fuzzy.tokenSetRatio(words, a.element.label.lowercased()), sb = Fuzzy.tokenSetRatio(words, b.element.label.lowercased())
            return sa != sb ? sa > sb : a.offset < b.offset
        }.prefix(maxOptions).map(\.element)
        let criteria: [(String, JSON)] = ranked.map { ($0.label, JSON.null) } + [(Candidates.none, "None of these controls does it.")]
        let first = try await jev.ask(state: obj(("command", .string(command)), ("app", .string(app))), questions: [
            ("control", obj(("type", "choice"), ("instructions", "Which control in `app` should be pressed to do what `command` asks?"), ("criteria", .object(criteria)))),
            ("simple", obj(("type", "noul"),
                           ("instructions", "Does `command` ask for exactly one simple action that a single button or menu command performs completely, such as creating an empty note or zooming?"),
                           ("criteria", obj(("true", "One simple action, finished by one click."),
                                            ("false", "The user also gives text, names, times or other details to enter, or the task needs several steps or choices."))))),
        ])
        try checkCancellation(cancel)
        let pick = first.answers["control"]
        let label = pick?.choice ?? Candidates.none
        let control = ranked.first { $0.label == label }
        let confidence = pick?.confidence ?? 0
        let simple = first.answers["simple"]?.noul ?? 0
        guard let control, confidence >= minChoice, simple >= minSimple else {
            return Decision(control: control, confidence: confidence, simple: simple, completes: nil,
                            reason: control == nil ? "no control fits" : String(format: "not a one-press task (pick %.2f, simple %.2f)", confidence, simple))
        }
        let second = try await jev.ask(state: obj(("command", .string(command)), ("app", .string(app)), ("control", describe(control.label))), questions: [
            ("completes", obj(("type", "noul"),
                              ("instructions", "When the user runs `control` in `app` (it is triggered directly, the same as clicking it), is what `command` asks then completely done? A name ending in '…' opens a dialog that still needs a choice."),
                              ("criteria", obj(("true", "Running it finishes the request by itself."),
                                               ("false", "It only opens a page, dialog or menu, does something else, or the request needs more than this."))))),
        ])
        try checkCancellation(cancel)
        let completes = second.answers["completes"]?.noul ?? 0
        return Decision(control: control, confidence: confidence, simple: simple, completes: completes,
                        reason: String(format: "%@ (pick %.2f, simple %.2f, completes %.2f)", label, confidence, simple, completes))
    }

    static func checkCancellation(_ cancel: CancelFlag) throws {
        if cancel.isSet || Task.isCancelled { throw CancellationError() }
    }

    public static func press(_ control: AXControl, cancel: CancelFlag = CancelFlag()) -> Bool {
        guard !cancel.isSet, !Task.isCancelled,
              let running = NSRunningApplication(processIdentifier: control.processID),
              !running.isTerminated, running.bundleIdentifier == control.bundleID,
              running.launchDate == control.launchDate,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == control.processID,
              // Re-read the menu hierarchy after the network calls. Reject stale/replaced
              // elements, changed paths, disabled commands and controls from another process.
              controls(in: running, includeBrowserControls: true).contains(where: {
                  $0.menuPath == control.menuPath && CFEqual($0.element, control.element)
              }),
              belongs(control.element, to: control.processID),
              string(control.element, kAXRoleAttribute) == kAXMenuItemRole as String,
              (attr(control.element, kAXEnabledAttribute) as? Bool) == true,
              canPress(control.element),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == control.processID,
              !cancel.isSet, !Task.isCancelled else { return false }
        return AXUIElementPerformAction(control.element, kAXPressAction as CFString) == .success
    }

}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
