import Foundation
import Security

/// Where API keys come from (bring your own key): environment variables, then the login Keychain
/// (the Setup window saves there), then ~/.varta/dev.env for development.
public enum KeyName: String, CaseIterable {
    case typesafe = "TYPESAFE_API_KEY"
    case anthropic = "ANTHROPIC_API_KEY"
    case gateway = "AI_GATEWAY_API_KEY"

    public var label: String {
        switch self {
        case .typesafe: return "TypeSafe (Jev)"
        case .anthropic: return "Anthropic (computer use)"
        case .gateway: return "Vercel AI Gateway (computer use, alternative)"
        }
    }
}

public enum Credentials {
    static let service = "com.usekopai.varta"
    public static let devFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".varta/dev.env")

    public static func get(_ key: KeyName) -> String? {
        if let v = ProcessInfo.processInfo.environment[key.rawValue], !v.isEmpty { return v }
        if let v = keychain(key), !v.isEmpty { return v }
        return devEnv()[key.rawValue]
    }

    public static func has(_ key: KeyName) -> Bool { get(key) != nil }

    /// Store in the login Keychain (the setup window uses this).
    @discardableResult
    public static func set(_ key: KeyName, _ value: String?) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: key.rawValue]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func keychain(_ key: KeyName) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key.rawValue,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func devEnv() -> [String: String] {
        guard let text = try? String(contentsOf: devFile, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.hasPrefix("#"), let eq = l.firstIndex(of: "=") else { continue }
            out[String(l[..<eq]).trimmingCharacters(in: .whitespaces)] =
                String(l[l.index(after: eq)...]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        return out
    }
}
