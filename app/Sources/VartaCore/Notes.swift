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

/// Notes exposes body replacement, not an append API. Preserve the existing fragment and
/// restrict edits to simple text markup; rich objects cannot safely round-trip this way.
public enum NoteAppend {
    public static func supportsHTML(_ html: String) -> Bool {
        guard html.utf8.count <= 100_000 else { return false }
        let tags = try! NSRegularExpression(pattern: #"<[^>]*>"#)
        let allowed = try! NSRegularExpression(pattern: #"^</?(?:div|p|br|h[1-6]|b|strong|i|em|u|s|strike)\s*/?>$"#, options: .caseInsensitive)
        return tags.matches(in: html, range: NSRange(html.startIndex..., in: html)).allSatisfy {
            guard let range = Range($0.range, in: html) else { return false }
            let tag = String(html[range])
            return allowed.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) != nil
        }
    }
    public static func decode(_ line: String) -> String? {
        guard let data = Data(base64Encoded: line) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    // Foundation encoding makes the subprocess response unambiguous even for arbitrary
    // newlines and delimiter-like text inside a note. Existing content stays local.
    static let encoding = """
    use framework "Foundation"
    use scripting additions
    on encodeText(t)
        set s to current application's NSString's stringWithString:t
        set d to s's dataUsingEncoding:4
        return (d's base64EncodedStringWithOptions:0) as text
    end encodeText
    on sameText(a, b)
        set s to current application's NSString's stringWithString:a
        return (s's isEqualToString:b) as boolean
    end sameText
    """
    static let lookup = encoding + "\n" + """
    on run argv
        set requestedTitle to item 1 of argv
        tell application "Notes"
            set hits to every note whose name is requestedTitle
            if (count of hits) is 0 then return "missing"
            if (count of hits) is not 1 then return "ambiguous"
            set targetNote to item 1 of hits
            if password protected of targetNote or shared of targetNote then return "unsupported"
            if (count of attachments of targetNote) is not 0 then return "unsupported"
            set noteID to id of targetNote
            set oldHTML to body of targetNote
            set oldText to plaintext of targetNote
        end tell
        return "ok" & linefeed & my encodeText(noteID) & linefeed & my encodeText(oldHTML) & linefeed & my encodeText(oldText)
    end run
    """
    static let append = encoding + "\n" + """
    on run argv
        set requestedTitle to item 1 of argv
        set requestedID to item 2 of argv
        set originalHTML to item 3 of argv
        set extraHTML to item 4 of argv
        tell application "Notes"
            set hits to every note whose name is requestedTitle
            if (count of hits) is not 1 then return "changed"
            set targetNote to item 1 of hits
            if id of targetNote is not requestedID then return "changed"
            if password protected of targetNote or shared of targetNote then return "changed"
            if (count of attachments of targetNote) is not 0 then return "changed"
            if not my sameText(body of targetNote, originalHTML) then return "changed"
            set body of targetNote to originalHTML & extraHTML
            set savedText to plaintext of targetNote
            try
                show targetNote
                activate
            end try
        end tell
        return "ok" & linefeed & my encodeText(savedText)
    end run
    """
}

extension Executor {
    func appendNote(_ plan: Plan, _ res: inout ExecResult, cancel: CancelFlag?) {
        guard let title = plan.arg("title"), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 200,
              let content = plan.arg("body"), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.utf8.count <= 16_000, !title.contains("\0"), !content.contains("\0") else {
            res.ok = false; res.note = "Name the note and the text to add"; return
        }
        guard apps.contains("Notes") else { res.ok = false; res.note = "Apple Notes is not installed"; return }
        guard let found = osascript(&res, NoteAppend.lookup, title, cancel: cancel, redactArguments: true) else { return }
        let fields = found.components(separatedBy: "\n")
        guard fields.count == 4, fields[0] == "ok", let id = NoteAppend.decode(fields[1]), !id.isEmpty,
              let html = NoteAppend.decode(fields[2]), let originalText = NoteAppend.decode(fields[3]) else {
            res.ok = false
            switch found {
            case "missing": res.note = "No note titled \(title). Repeat the command with its exact title"
            case "ambiguous": res.note = "More than one note is titled \(title). Give the intended note a unique title, then repeat the command"
            case "unsupported": res.note = "Use a plain, unshared, unlocked note without attachments"
            default: res.note = "Could not read the target note safely"
            }
            return
        }
        guard NoteAppend.supportsHTML(html) else {
            res.ok = false; res.note = "This note has unsupported formatting. Add the text manually in Notes"; return
        }
        let extra = "<div>" + NoteText.html(content) + "</div>"
        guard let written = osascript(&res, NoteAppend.append, title, id, html, extra, cancel: cancel, redactArguments: true) else {
            if cancel?.isSet != true && !Task.isCancelled { res.note = "Could not confirm the addition. Check Notes before retrying" }
            return
        }
        if written == "changed" {
            res.ok = false; res.note = "The note changed before the addition. Please try again"; return
        }
        let saved = written.components(separatedBy: "\n")
        guard saved.count == 2, saved[0] == "ok", let text = NoteAppend.decode(saved[1]),
              NoteText.normalized(text) == NoteText.normalized(originalText + "\n" + content) else {
            res.ok = false; res.note = "The addition could not be verified. Check Notes before retrying"; return
        }
        res.note = "Added to note: \(title)"
    }
}
