import Foundation

/// Remove only a leading polite request wrapper. Literal titles and dictated content
/// remain intact, and the router still classifies the complete original transcript.
public enum CommandText {
    public static func isNegated(_ text: String) -> Bool {
        ReminderParsing.groups(#"^(?:(?:do\s+not|don['’]t|never|not)\b|I\s+(?:do\s+not|don['’]t)\s+want\b)"#, body(text)) != nil
    }
    public static func body(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReminderParsing.groups(#"^(?:please\s+)?(?:(?:can|could|would|will)\s+you\s+)?(?:please\s+)?(.+)$"#, trimmed)?.first ?? trimmed
    }
}

public enum CommandFeedback {
    public static func unsupported(_ plan: Plan) -> String {
        if CommandText.isNegated(plan.transcript) { return "No action taken" }
        switch plan.intent {
        case "finder_control": return "Try: open Downloads, find files named launch, or show launch.pdf in Finder"
        case "create_reminder": return "Try: remind me tomorrow at 9 AM to call mom. One nonrecurring task at a time"
        case "calendar_control": return "Try: schedule review tomorrow at 3 PM for 30 minutes, or show my calendar tomorrow"
        case "create_note": return "Try: create a note called Ideas with your text. Use plain text in Apple Notes"
        case "append_note": return "Try: add your text to the Launch Ideas note. Name one existing plain-text note"
        case "browser_control": return "Name one Chrome or Safari action, such as next tab in Chrome"
        case "audio_control": return "Try: set volume to 30 percent. Only Mac output volume is supported"
        case "playback_control": return "Name Spotify or Apple Music and one action: pause, resume, next or previous"
        case "play_music": return "Name the song or artist and player, such as play jazz in Spotify"
        case "open_app": return "Say open followed by an installed app name, such as open Calculator"
        case "open_site": return "Say open followed by a website name or address"
        case "web_search": return "Say what to search for, such as search YouTube for Swift tutorials"
        case "app_task":
            switch plan.arg("app") {
            case "Calendar": return "Calendar supports one-time event creation and day agendas; edits and invites aren't supported"
            case "Reminders": return "Reminders supports creating one task. Try: remind me tomorrow to call mom"
            case "Notes": return "Notes supports creating a note or appending plain text to a named note"
            case "Finder": return "Finder supports opening common folders, filename searches and revealing files"
            default: return "That app action isn't supported. Try one action such as open Downloads"
            }
        default: return "Say one action, such as open Downloads or pause Spotify"
        }
    }
}
