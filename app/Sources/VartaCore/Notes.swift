import Foundation

/// Original-text boundaries keep dictated punctuation and long bodies out of the short
/// fuzzy candidate spans used for music and searches. Offsets are token indices.
public struct NoteText {
    public let text: String
    let ranges: [Range<String.Index>]
    public init(_ text: String) {
        self.text = text
        let regex = try! NSRegularExpression(pattern: #"\S+"#)
        ranges = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }
    public var supported: Bool { !ranges.isEmpty && ranges.count <= 200 && text.utf8.count <= 16_000 }
    public var tokens: JSON { .array(ranges.prefix(200).enumerated().map { obj(("index", .number(Double($0.offset))), ("text", .string(String(text[$0.element])))) }) }
    public var starts: [(String, JSON)] { ranges.indices.prefix(200).map { (String($0), .string(String(text[ranges[$0]]))) } }
    public var ends: [(String, JSON)] { ranges.indices.prefix(200).map { (String($0 + 1), .string("After: " + String(text[ranges[$0]]))) } }
    public func slice(start: String?, end: String?) -> String? {
        guard supported, let start, let end, let a = Int(start), let b = Int(end), a >= 0, a < b, b <= ranges.count else { return nil }
        return String(text[ranges[a].lowerBound..<ranges[b - 1].upperBound])
    }
    public static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;").replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "<br>")
    }
    public static func normalized(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension Executor {
    func createNote(_ plan: Plan, _ res: inout ExecResult, cancel: CancelFlag?) {
        guard let title = plan.arg("title"), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.count <= 200, let body = plan.arg("body"), body.utf8.count <= 16_000,
              !title.contains("\0"), !body.contains("\0") else {
            res.ok = false; res.note = "Give the note a short title and up to 200 words of content"; return
        }
        guard apps.contains("Notes") else { res.ok = false; res.note = "Apple Notes is not installed"; return }
        let html = "<h1>" + NoteText.html(title) + "</h1><div>" + NoteText.html(body) + "</div>"
        let create = """
        on run argv
            tell application "Notes"
                set destination to default folder of default account
                set createdNote to make new note at destination with properties {body:item 1 of argv}
                set createdID to id of createdNote
                try
                    show createdNote
                    activate
                end try
                return createdID
            end tell
        end run
        """
        guard let id = osascript(&res, create, html, cancel: cancel), !id.isEmpty else {
            if cancel?.isSet != true && !Task.isCancelled {
                res.note = "Could not confirm note creation. Check Notes and Automation permission before retrying. " + res.note
            }
            res.ok = false; return
        }
        let read = """
        on run argv
            tell application "Notes"
                set savedNote to note id (item 1 of argv)
                return plaintext of savedNote
            end tell
        end run
        """
        guard let saved = osascript(&res, read, id, cancel: cancel) else {
            if cancel?.isSet != true && !Task.isCancelled { res.note = "Note created, but could not verify it. Check Notes before retrying" }
            return
        }
        guard NoteText.normalized(saved) == NoteText.normalized(title + "\n" + body) else {
            res.ok = false; res.note = "Note created, but its content could not be verified. Check Notes before retrying"; return
        }
        res.note = "Created note: \(title)"
    }
}
