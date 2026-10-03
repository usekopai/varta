import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// The computer-use "hands": screenshots (ScreenCaptureKit) and synthetic input (CGEvent).
///
/// Coordinates: Claude sees one display, downscaled to fit its image limits. `Screen` keeps that
/// display's origin (global points) and the scale, so every coordinate maps back to a global point.
public enum Permissions {
    public static var accessibility: Bool { AXIsProcessTrusted() }
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Show the system prompt (first time) or nothing (already decided).
    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func requestScreenRecording() { _ = CGRequestScreenCaptureAccess() }
}

public struct InputError: Error, CustomStringConvertible { public let description: String }

public final class Screen {
    static let maxLongEdge = 1568.0
    static let maxPixels = 1_150_000.0

    public let displayID: CGDirectDisplayID
    public let origin: CGPoint // display top-left, global points
    public let size: CGSize    // display size, points
    public let scale: Double   // screenshot px per point

    public init(forApp app: String) {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        let displays = ids.prefix(Int(n)).map { ($0, CGDisplayBounds($0)) }
        var target = displays.first ?? (CGMainDisplayID(), CGDisplayBounds(CGMainDisplayID()))
        if let win = Screen.appWindow(app) {
            let c = CGPoint(x: win.midX, y: win.midY)
            target = displays.first { $0.1.contains(c) } ?? target
        }
        displayID = target.0
        origin = target.1.origin
        size = target.1.size
        scale = min(1.0, Screen.maxLongEdge / max(size.width, size.height), (Screen.maxPixels / (size.width * size.height)).squareRoot())
    }

    public var shotSize: (Int, Int) { (Int((size.width * scale).rounded()), Int((size.height * scale).rounded())) }

    public func toGlobal(_ xy: [Double]) -> CGPoint { CGPoint(x: origin.x + xy[0] / scale, y: origin.y + xy[1] / scale) }
    public func toShot(_ p: CGPoint) -> (Int, Int) { (Int(((p.x - origin.x) * scale).rounded()), Int(((p.y - origin.y) * scale).rounded())) }

    /// Largest on-screen normal window of the app, in global points.
    static func appWindow(_ app: String) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var best: CGRect?
        for w in list where w[kCGWindowOwnerName as String] as? String == app && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let b = w[kCGWindowBounds as String] as? [String: Double] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if best == nil || r.width * r.height > best!.width * best!.height { best = r }
        }
        return best
    }

    /// PNG of the whole display at `shotSize`, or of a display-local region (points) scaled to fit it.
    public func capture(region: CGRect? = nil) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw InputError(description: "display not found") }
        // Keep Varta's own notch panel out of what the model sees.
        let own = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let cfg = SCStreamConfiguration()
        cfg.showsCursor = true
        let (w, h) = shotSize
        if let region {
            cfg.sourceRect = region
            let s = min(Double(w) / region.width, Double(h) / region.height)
            cfg.width = max(1, Int(region.width * s))
            cfg.height = max(1, Int(region.height * s))
        } else {
            cfg.width = w
            cfg.height = h
        }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return try Screen.png(image)
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw InputError(description: "png encoder") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw InputError(description: "png encode failed") }
        return data as Data
    }
}

public enum Input {
    static let modifiers: [String: CGEventFlags] = [
        "shift": .maskShift, "ctrl": .maskControl, "control": .maskControl, "alt": .maskAlternate, "option": .maskAlternate,
        "super": .maskCommand, "cmd": .maskCommand, "command": .maskCommand, "meta": .maskCommand,
    ]

    // US-layout virtual key codes (Carbon kVK_*).
    static let keycodes: [String: CGKeyCode] = {
        var k: [String: CGKeyCode] = [:]
        for (i, c) in "asdfhgzxcv".enumerated() { k[String(c)] = CGKeyCode(i) }
        for (i, c) in "bqweryt".enumerated() { k[String(c)] = CGKeyCode(11 + i) }
        let more: [(String, CGKeyCode)] = [
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28), ("0", 29),
            ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("'", 39), ("k", 40), (";", 41),
            ("\\", 42), (",", 43), ("/", 44), ("n", 45), ("m", 46), (".", 47), ("`", 50),
            ("return", 36), ("enter", 36), ("kp_enter", 76), ("tab", 48), ("space", 49), ("backspace", 51), ("delete", 117),
            ("escape", 53), ("esc", 53), ("left", 123), ("right", 124), ("down", 125), ("up", 126),
            ("home", 115), ("end", 119), ("page_up", 116), ("pageup", 116), ("prior", 116), ("page_down", 121), ("pagedown", 121), ("next", 121),
        ]
        for (name, code) in more { k[name] = code }
        for (i, code) in [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].enumerated() { k["f\(i + 1)"] = CGKeyCode(code) }
        return k
    }()

    static let keyAliases = ["back_space": "backspace", "arrowup": "up", "arrowdown": "down", "arrowleft": "left", "arrowright": "right",
                             "minus": "-", "plus": "=", "comma": ",", "period": "."]

    static func flags(_ text: String?) throws -> CGEventFlags {
        var f: CGEventFlags = []
        for part in (text ?? "").lowercased().split(separator: "+") {
            let p = part.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            guard let m = modifiers[p] else { throw InputError(description: "unknown modifier '\(p)'") }
            f.insert(m)
        }
        return f
    }

    static func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
    static func pause(_ s: Double) { usleep(useconds_t(s * 1_000_000)) }

    public static func cursor() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    public static func move(_ p: CGPoint) {
        post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
    }

    public static func click(_ p: CGPoint, button: String = "left", count: Int = 1, modifiers: String? = nil) throws {
        let f = try flags(modifiers)
        let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) = {
            switch button {
            case "right": return (.rightMouseDown, .rightMouseUp, .right)
            case "middle": return (.otherMouseDown, .otherMouseUp, .center)
            default: return (.leftMouseDown, .leftMouseUp, .left)
            }
        }()
        move(p)
        pause(0.03)
        for n in 1...max(1, count) {
            for type in [down, up] {
                let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: btn)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                if !f.isEmpty { e?.flags = f }
                post(e)
                pause(0.02)
            }
        }
    }

    public static func mouseButton(down: Bool) {
        post(CGEvent(mouseEventSource: nil, mouseType: down ? .leftMouseDown : .leftMouseUp, mouseCursorPosition: cursor(), mouseButton: .left))
    }

    public static func drag(from a: CGPoint, to b: CGPoint, modifiers: String? = nil) throws {
        let f = try flags(modifiers)
        move(a)
        var events = [CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left)]
        for i in 1...10 {
            let t = Double(i) / 10
            events.append(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                                  mouseCursorPosition: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), mouseButton: .left))
        }
        events.append(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left))
        for e in events {
            if !f.isEmpty { e?.flags = f }
            post(e)
            pause(0.015)
        }
    }

    public static func scroll(_ direction: String, amount: Int, modifiers: String? = nil) throws {
        let dy = Int32(direction == "up" ? amount : direction == "down" ? -amount : 0)
        let dx = Int32(direction == "left" ? amount : direction == "right" ? -amount : 0)
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        if let m = modifiers { e?.flags = try flags(m) }
        post(e)
    }

    public static func key(_ combo: String, repeat times: Int = 1, hold: Double = 0) throws {
        let parts = combo.split(separator: "+").map(String.init)
        let f = try flags(parts.dropLast().joined(separator: "+"))
        var name = (parts.last ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        name = keyAliases[name] ?? name
        guard let code = keycodes[name] else { throw InputError(description: "unknown key '\(parts.last ?? "")'") }
        for _ in 0..<min(max(times, 1), 100) {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                if !f.isEmpty { e?.flags = f }
                post(e)
                if down && hold > 0 { pause(hold) }
                pause(0.01)
            }
        }
    }

    /// Literal text, any Unicode, independent of keyboard layout; newlines press Return.
    public static func type(_ text: String) throws {
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if i > 0 { try key("return") }
            let utf16 = Array(line.utf16)
            var start = 0
            while start < utf16.count {
                let chunk = Array(utf16[start..<min(start + 16, utf16.count)])
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                    chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                    post(e)
                }
                pause(0.01)
                start += 16
            }
        }
    }

    /// True if keyboard focus is a password field; typing refuses to run there.
    public static func focusIsSecure() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success, let el = focused else { return false }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String) == (kAXSecureTextFieldSubrole as String)
    }
}
