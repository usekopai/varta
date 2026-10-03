import Foundation

public struct ReminderDraft: Equatable {
    public let title: String
    public let list: String?
    public let schedule: String?
    public init(title: String, list: String? = nil, schedule: String? = nil) {
        self.title = title; self.list = list; self.schedule = schedule
    }
}

public enum ReminderTime {
    case ready(date: Date?, allDay: Bool)
    case clarify(String)
}

public enum ReminderParsing {
    static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }
    static func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Supported grammar is deliberately bounded. Unsupported requests cannot silently
    /// lose a date, list, recurrence, or location constraint.
    public static func draft(_ transcript: String) -> ReminderDraft? {
        guard transcript.utf8.count <= 16_000 else { return nil }
        var text = CommandText.body(transcript), list: String?
        if let request = groups(#"^(?:set|create|add)\s+(?:a\s+)?reminder\s+(.+)$"#, text) {
            text = "remind me " + request[0]
        }
        if let parts = groups(#"^(.*?)\s+in\s+(?:my\s+|the\s+)?(.+?)\s+list[.!?]?$"#, text) {
            text = clean(parts[0]); list = clean(parts[1])
        }
        var title: String, schedule: String?
        if let parts = groups(#"^(?:please\s+)?remind\s+me(?:\s+(.*?))?\s+to\s+(.+)$"#, text) {
            schedule = clean(parts[0]).isEmpty ? nil : clean(parts[0])
            title = clean(parts[1])
            if schedule == nil, let trailing = groups(#"^(.+?)\s+((?:today|tomorrow|in\s+[a-z0-9 -]+\s+(?:minutes?|hours?|days?)|at\s+|on\s+).*)$"#, title) {
                title = clean(trailing[0]); schedule = clean(trailing[1])
            }
        } else if let parts = groups(#"^(?:please\s+)?add\s+(.+?)\s+to\s+(?:my\s+|the\s+)?reminders[.!?]?$"#, text) {
            title = clean(parts[0])
        } else { return nil }
        if let raw = schedule { schedule = clean(raw).trimmingCharacters(in: CharacterSet(charactersIn: ".!?")) }
        guard !title.isEmpty, title.count <= 300, !title.contains("\0"), (list?.count ?? 0) <= 100 else { return nil }
        return ReminderDraft(title: title, list: list, schedule: schedule)
    }

    static let words = ["one":1, "two":2, "three":3, "four":4, "five":5, "six":6, "seven":7, "eight":8, "nine":9, "ten":10, "eleven":11, "twelve":12, "thirteen":13, "fourteen":14, "fifteen":15, "sixteen":16, "seventeen":17, "eighteen":18, "nineteen":19, "twenty":20, "thirty":30, "forty":40, "fifty":50, "sixty":60]
    static func number(_ text: String) -> Int? {
        if let n = Int(text) { return n }
        let pieces = text.replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init)
        if pieces.count == 1 { return words[text] }
        if pieces.count == 2, let tens = words[pieces[0]], [20,30,40,50,60].contains(tens), let unit = words[pieces[1]], unit < 10 { return tens + unit }
        return nil
    }
    public static func looksLikeTime(_ text: String) -> Bool {
        let t = clean(text).lowercased()
        return groups(#"^(am\b|pm\b|a\.m\.|p\.m\.|today|tomorrow|on\b|in\b|at\b|no date\b|without a date\b|\d|one\b|two\b|three\b|four\b|five\b|six\b|seven\b|eight\b|nine\b|ten\b|eleven\b|twelve\b|noon\b|midnight\b).*"#, t) != nil
    }
    /// A bare AM/PM answer may only complete an already specified clock hour.
    public static func meridianFollowup(_ answer: String, original: String?) -> String? {
        let reply = clean(answer).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        guard ["am", "pm", "a.m", "p.m"].contains(reply), let original,
              groups(#"^(?:.*\s+)?at\s+(?:[a-z]+|\d{1,2})(?::\d{2})?[.!?]?$"#, original) != nil else { return nil }
        return original.trimmingCharacters(in: CharacterSet(charactersIn: ".!?")) + " " + reply
    }
    public static func dayHint(_ schedule: String?) -> String? {
        guard let schedule, let split = groups(#"^(.+?)\s+at\s+.+$"#, schedule) else { return nil }
        return split[0]
    }
    public static func resolve(_ raw: String?, now: Date, calendar: Calendar) -> ReminderTime {
        guard let raw, !clean(raw).isEmpty else { return .ready(date: nil, allDay: false) }
        let text = clean(raw).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        if ["no date", "without a date"].contains(text) { return .ready(date: nil, allDay: false) }
        let clarify = "Say a date and time, like tomorrow at 6 PM, or say no date"
        if let relative = groups(#"^in\s+([a-z0-9 -]+)\s+(minutes?|hours?|days?)$"#, text) {
            guard let count = number(relative[0]), (1...10000).contains(count) else { return .clarify("Use a positive duration, such as in 20 minutes") }
            let unit: Calendar.Component = relative[1].hasPrefix("minute") ? .minute : relative[1].hasPrefix("hour") ? .hour : .day
            guard let date = calendar.date(byAdding: unit, value: count, to: now) else { return .clarify(clarify) }
            return .ready(date: date, allDay: false)
        }
        var datePart = "today", timePart: String?
        if let split = groups(#"^(.+?)\s+at\s+(.+)$"#, text) { datePart = split[0]; timePart = split[1] }
        else if text.hasPrefix("at ") { timePart = String(text.dropFirst(3)) }
        else if groups(#"^(?:[a-z]+|\d{1,2})(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)$|^(?:[01]?\d|2[0-3]):\d{2}$|^(?:noon|midnight)$"#, text) != nil { timePart = text }
        else { datePart = text }
        if datePart.hasPrefix("on ") { datePart = String(datePart.dropFirst(3)) }
        let today = calendar.startOfDay(for: now)
        var day: Date?
        switch datePart {
        case "today": day = today
        case "tomorrow": day = calendar.date(byAdding: .day, value: 1, to: today)
        default:
            var year = calendar.component(.year, from: now), month: Int?, dateNumber: Int?
            if let iso = groups(#"^(\d{4})-(\d{2})-(\d{2})$"#, datePart) {
                year = Int(iso[0]) ?? 0; month = Int(iso[1]); dateNumber = Int(iso[2])
            } else if let named = groups(#"^([a-z]+)\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?$"#, datePart) {
                let months = ["january","february","march","april","may","june","july","august","september","october","november","december"]
                month = months.firstIndex(of: named[0]).map { $0 + 1 }; dateNumber = Int(named[1])
                if !named[2].isEmpty { year = Int(named[2]) ?? 0 }
            }
            if let month, let dateNumber, (1...9999).contains(year), (1...12).contains(month), (1...31).contains(dateNumber) {
                let c = DateComponents(timeZone: calendar.timeZone, year: year, month: month, day: dateNumber)
                if let d = calendar.date(from: c), calendar.component(.year, from: d) == year,
                   calendar.component(.month, from: d) == month, calendar.component(.day, from: d) == dateNumber { day = d }
            }
        }
        guard let day else { return .clarify(clarify) }
        guard let timePart else {
            guard day >= today else { return .clarify("That date has passed. Say a future date including the year") }
            return .ready(date: day, allDay: true)
        }
        var hour: Int?, minute = 0
        if timePart == "noon" { hour = 12 }
        else if timePart == "midnight" { hour = 0 }
        else if let clock = groups(#"^([a-z]+|\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?$"#, timePart) {
            hour = number(clock[0]); minute = clock[1].isEmpty ? 0 : (Int(clock[1]) ?? -1)
            if !clock[2].isEmpty {
                guard let h = hour, (1...12).contains(h) else { return .clarify("Use an hour from 1 to 12 with AM or PM") }
                hour = h % 12 + (clock[2].hasPrefix("p") ? 12 : 0)
            } else if clock[1].isEmpty { return .clarify("AM or PM? Say a time such as 6 PM") }
        }
        guard let hour, (0...23).contains(hour), (0...59).contains(minute) else { return .clarify(clarify) }
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour; components.minute = minute; components.second = 0; components.timeZone = calendar.timeZone
        guard let candidate = calendar.date(from: components), calendar.component(.hour, from: candidate) == hour,
              calendar.component(.minute, from: candidate) == minute else { return .clarify("That local time does not exist. Choose another time") }
        // Reject a repeated wall-clock hour rather than choose a daylight-saving occurrence.
        let start = day.addingTimeInterval(-1)
        let first = calendar.nextDate(after: start, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .first)
        let last = calendar.nextDate(after: start, matching: components, matchingPolicy: .strict, repeatedTimePolicy: .last)
        if let first, let last, first != last { return .clarify("That local time occurs twice. Choose an unambiguous time") }
        guard candidate > now else { return .clarify("That time has passed. Say a future date and time") }
        return .ready(date: candidate, allDay: false)
    }
}
