import AppKit
import ApplicationServices
import Foundation

public struct FinderRequest: Equatable {
    public let operation: String
    public let target: String
    public init(_ operation: String, _ target: String = "") { self.operation = operation; self.target = target }

    public static func parse(_ transcript: String) -> FinderRequest? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 500 else { return nil }
        if ReminderParsing.groups(#"^(?:please\s+)?(?:show|reveal)\s+(?:this|the current)\s+file\s+in\s+Finder[.!]?$"#, text) != nil {
            return FinderRequest("current")
        }
        if let p = ReminderParsing.groups(#"^(?:please\s+)?(?:open|show)\s+(?:my\s+|the\s+)?(downloads|documents|desktop|pictures|movies|music|home)(?:\s+folder)?(?:\s+in\s+Finder)?[.!]?$"#, text) {
            // Bare "open Music" is an application request.
            if p[0].lowercased() == "music" && !text.lowercased().contains("folder") && !text.lowercased().contains("finder") { return nil }
            return FinderRequest("folder", p[0].lowercased())
        }
        if let p = ReminderParsing.groups(#"^(?:please\s+)?(?:find|search for)\s+files?\s+(?:named|called|containing)\s+(.+?)(?:\s+in\s+Finder)?$"#, text) {
            var name = p[0].trimmingCharacters(in: .whitespacesAndNewlines)
            // Speech transcription commonly adds sentence punctuation to the final name.
            if name.hasSuffix(".") || name.hasSuffix("!") { name.removeLast() }
            return validName(name).map { FinderRequest("search", $0) }
        }
        if let p = ReminderParsing.groups(#"^(?:please\s+)?(?:show|reveal)\s+(?:the\s+file\s+(?:named\s+|called\s+)?)?(.+?)\s+in\s+Finder[.!]?$"#, text) {
            return validName(p[0]).map { FinderRequest("reveal", $0) }
        }
        return nil
    }
    public static func validName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 1, (name.hasPrefix("\"") && name.hasSuffix("\"")) || (name.hasPrefix("“") && name.hasSuffix("”")) {
            name = String(name.dropFirst().dropLast())
        }
        guard !name.isEmpty, name.count <= 255,
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              !name.contains("/"), !name.contains("*"), !name.contains("?") else { return nil }
        return name
    }
    public static func query(_ name: String, exact: Bool) -> String? {
        guard let name = validName(name) else { return nil }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "kMDItemFSName == \"" + (exact ? escaped : "*" + escaped + "*") + "\"cd"
    }
}

public protocol FinderDriving {
    func currentDocument() -> URL?
    func openFolder(_ url: URL) -> Bool
    func reveal(_ urls: [URL])
}
public struct NativeFinderDriver: FinderDriving {
    public init() {}
    public func currentDocument() -> URL? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let value = AXTier.attr(root, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement
        guard AXTier.attr(window, kAXModalAttribute) as? Bool != true,
              let path = AXTier.attr(window, kAXDocumentAttribute) as? String,
              let url = URL(string: path), url.isFileURL else { return nil }
        return url
    }
    public func openFolder(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
    public func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
}

public final class FinderController {
    private let driver: FinderDriving
    private let runner: Runner
    private let home: URL
    private let manager = FileManager.default
    public init(driver: FinderDriving = NativeFinderDriver(), runner: Runner = SystemRunner(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.driver = driver; self.runner = runner; self.home = home.standardizedFileURL
    }
    public func captureDocument() -> URL? { driver.currentDocument() }
    private func file(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var directory: ObjCBool = false
        return manager.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }
    public func execute(_ request: FinderRequest, document: URL? = nil, cancel: CancelFlag = CancelFlag()) -> ExecResult {
        func result(_ ok: Bool, _ message: String) -> ExecResult { var r = ExecResult(); r.ok = ok; r.note = message; return r }
        func stopped() -> Bool { cancel.isSet || Task.isCancelled }
        guard !stopped() else { return result(false, "Stopped") }
        if request.operation == "folder" {
            let folders = ["downloads":"Downloads", "documents":"Documents", "desktop":"Desktop", "pictures":"Pictures", "movies":"Movies", "music":"Music", "home":""]
            guard let folder = folders[request.target] else { return result(false, "Name a common folder, such as Downloads") }
            let url = folder.isEmpty ? home : home.appendingPathComponent(folder, isDirectory: true)
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return result(false, "That folder is unavailable") }
            guard !stopped() else { return result(false, "Stopped") }
            return driver.openFolder(url) ? result(true, "Opened \(folder.isEmpty ? "Home" : folder) in Finder") : result(false, "Could not open that folder")
        }
        if request.operation == "current" {
            guard let document, file(document) else { return result(false, "No saved document path is available. Say show filename in Finder") }
            guard !stopped() else { return result(false, "Stopped") }
            driver.reveal([document])
            return result(true, "Asked Finder to reveal \(document.lastPathComponent)")
        }
        guard ["search", "reveal"].contains(request.operation), let query = FinderRequest.query(request.target, exact: request.operation == "reveal") else {
            return result(false, "Use a filename without paths or wildcards")
        }
        let output = runner.run(["/usr/bin/mdfind", "-0", "-onlyin", home.path, query], timeout: 10)
        guard !stopped() else { return result(false, "Stopped") }
        guard output.code == 0 else { return result(false, "File search failed. Check Spotlight and folder access") }
        guard output.stdout.utf8.count < 1_000_000 else { return result(false, "Too many matches. Use a more specific filename") }
        let urls = Set(output.stdout.split(separator: "\0").map { URL(fileURLWithPath: String($0)).standardizedFileURL }).filter { url in
            let relative = url.path.dropFirst(home.path.count + 1)
            guard url.path.hasPrefix(home.path + "/"), !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }), file(url) else { return false }
            // Recheck the actual filename so query syntax cannot broaden a reveal.
            if request.operation == "reveal" { return url.lastPathComponent.compare(request.target, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            return url.lastPathComponent.range(of: request.target, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.sorted { $0.path < $1.path }
        guard !urls.isEmpty else { return result(false, "No indexed files matched. Check the name and Spotlight indexing") }
        if request.operation == "reveal", urls.count != 1 { return result(false, "More than one file has that name. Use a unique filename") }
        guard !stopped() else { return result(false, "Stopped") }
        driver.reveal(Array(urls.prefix(10)))
        return result(true, request.operation == "reveal" ? "Asked Finder to reveal \(urls[0].lastPathComponent)" : "Asked Finder to show \(min(urls.count, 10)) of \(urls.count) matching files")
    }
}
