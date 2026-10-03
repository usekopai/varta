import AppKit
import Carbon

/// Global hotkeys through Carbon's RegisterEventHotKey: no Accessibility permission needed,
/// and it reports both press and release, which push-to-talk needs.
final class HotKey {
    private static var handlers: [UInt32: (Bool) -> Void] = [:]
    private static var installed = false
    private static var nextID: UInt32 = 1

    private var ref: EventHotKeyRef?
    private let id: UInt32
    /// False when another app already holds this combination.
    let registered: Bool

    /// `handler(true)` on press, `handler(false)` on release.
    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping (Bool) -> Void) {
        HotKey.installHandler()
        id = HotKey.nextID
        HotKey.nextID += 1
        let hkID = EventHotKeyID(signature: OSType(0x4E_4F_54_43), id: id) // 'NOTC'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr
        if registered { HotKey.handlers[id] = handler }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            HotKey.handlers[hkID.id]?(pressed)
            return noErr
        }, types.count, &types, nil, nil)
    }
}

enum Keys {
    static let escape = UInt32(kVK_Escape)
}

/// The push-to-talk shortcut the user chose (default ⌥Space), stored in user defaults.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32 // Carbon modifier mask
    var keyLabel: String

    static let standard = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), keyLabel: "Space")
    static let changed = Notification.Name("VartaShortcutChanged")
    private static let defaultsKey = "Shortcut"

    /// Apps known to claim a shortcut by default. macOS gives apps no way to see each other's global
    /// shortcuts, so this is a heads-up for common cases, not detection.
    static let knownDefaults: [(app: String, shortcut: Shortcut)] = [
        ("ChatGPT", .standard), // ChatGPT's desktop app opens its chat bar with ⌥Space by default
    ]

    /// A likely clash with an installed app, for the Setup window.
    var likelyConflict: String? {
        for (app, s) in Shortcut.knownDefaults where s.keyCode == keyCode && s.modifiers == modifiers {
            if FileManager.default.fileExists(atPath: "/Applications/\(app).app") { return app }
        }
        return nil
    }

    static var current: Shortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let s = try? JSONDecoder().decode(Shortcut.self, from: data) else { return .standard }
            return s
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    static let functionKeys: [UInt16: String] = [
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5",
        UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10",
        UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12", UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
        UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19",
    ]
    static let namedKeys: [UInt16: String] = [
        UInt16(kVK_Space): "Space", UInt16(kVK_Return): "Return", UInt16(kVK_Tab): "Tab", UInt16(kVK_Delete): "Delete",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→", UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
    ]

    /// A shortcut from a key press, or nil if it isn't usable: it needs ⌃, ⌥ or ⌘ (⇧ alone would
    /// swallow ordinary typing), unless it's a function key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        let isFunction = Shortcut.functionKeys[event.keyCode] != nil
        guard isFunction || !flags.intersection([.control, .option, .command]).isEmpty else { return nil }
        let label = Shortcut.functionKeys[event.keyCode] ?? Shortcut.namedKeys[event.keyCode]
            ?? (event.charactersIgnoringModifiers?.uppercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "Key \(event.keyCode)"
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, keyLabel: label)
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }
}
