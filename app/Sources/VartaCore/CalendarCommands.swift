import EventKit
import Foundation

public struct CalendarDraft: Equatable {
    public var title: String
    public var schedule: String?
    public var duration: String?
    public var calendar: String?
    public init(title: String, schedule: String? = nil, duration: String? = nil, calendar: String? = nil) {
        self.title = title; self.schedule = schedule; self.duration = duration; self.calendar = calendar
    }
}
public enum CalendarRequest: Equatable {
    case create(CalendarDraft)
    case agenda(day: String, calendar: String?)
}
public enum CalendarParsing {
    public static func parse(_ raw: String) -> CalendarRequest? {
        guard raw.count <= 1000, !raw.contains("\0") else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        var calendar: String?
        if let p = ReminderParsing.groups(#"^(.+?)\s+in\s+(?:my\s+|the\s+)?(.+?)\s+calendar$"#, text) {
            text = p[0]; calendar = p[1]
            guard !p[1].isEmpty, p[1].count <= 100 else { return nil }
        }
        if let p = ReminderParsing.groups(#"^(?:what(?:'s|’s| is) on (?:my |the )?calendar|show (?:me )?(?:my |the )?(?:calendar|schedule))(?:\s+(today|tomorrow|on .+))?$"#, text) {
            return .agenda(day: p[0].isEmpty ? "today" : p[0], calendar: calendar)
        }
        guard let p = ReminderParsing.groups(#"^(?:please\s+)?(?:schedule|add|create)\s+(.+)$"#, text) else { return nil }
        text = p[0]
        if let prefix = ReminderParsing.groups(#"^(?:an?\s+)?event\s+(?:called\s+)?(.+)$"#, text) { text = prefix[0] }
        let (body, duration) = splitDuration(text)
        guard ReminderParsing.groups(#"^(?:today|tomorrow|on|at)\b"#, body) == nil else { return nil }
        var title = body, schedule: String?
        if let p = ReminderParsing.groups(#"^(.+?)\s+((?:today\b|tomorrow\b|on\s+|at\s+|in\s+\d).*)$"#, body) { title = p[0]; schedule = p[1] }
        guard !title.isEmpty, title.count <= 300 else { return nil }
        return .create(CalendarDraft(title: title, schedule: schedule, duration: duration, calendar: calendar))
    }
    static func splitDuration(_ text: String) -> (String, String?) {
        if let p = ReminderParsing.groups(#"^(.+)\s+for\s+(.+\s+(?:minutes?|hours?|days?))$"#, text) { return (p[0], p[1]) }
        return (text, nil)
    }
    public static func minutes(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        var text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        if text.hasPrefix("for ") { text = String(text.dropFirst(4)) }
        if ["an hour", "one hour", "a hour"].contains(text) { return 60 }
        if ["half an hour", "half hour"].contains(text) { return 30 }
        guard let p = ReminderParsing.groups(#"^(?:for\s+)?([a-z0-9 -]+)\s+(minutes?|hours?)$"#, text), let n = ReminderParsing.number(p[0]), n > 0 else { return nil }
        let value = p[1].hasPrefix("hour") ? n.multipliedReportingOverflow(by: 60) : (partialValue: n, overflow: false)
        guard !value.overflow, (1...1440).contains(value.partialValue) else { return nil }
        return value.partialValue
    }
}

public struct CalendarDestination {
    public let id: String, title: String
    public let writable: Bool, isDefault: Bool
    public init(id: String, title: String, writable: Bool = true, isDefault: Bool = false) {
        self.id = id; self.title = title; self.writable = writable; self.isDefault = isDefault
    }
}
public struct CalendarEntry {
    public let id: String, title: String, calendarID: String, calendarName: String
    public let start: Date, end: Date
    public let allDay: Bool
    public init(id: String, title: String, calendarID: String, calendarName: String, start: Date, end: Date, allDay: Bool = false) {
        self.id = id; self.title = title; self.calendarID = calendarID; self.calendarName = calendarName; self.start = start; self.end = end; self.allDay = allDay
    }
}
public struct CalendarWrite {
    public let title: String, calendarID: String
    public let start: Date, end: Date
    public let timeZone: TimeZone
}
public struct CalendarAgenda {
    public let day: Date, timeZone: TimeZone
    public let entries: [CalendarEntry]
    public let total: Int
}
public struct CalendarOutcome {
    public var result: ExecResult
    public var agenda: CalendarAgenda?
}
@MainActor public protocol CalendarStoring {
    func authorize() async throws -> Bool
    func calendars() -> [CalendarDestination]
    func save(_ write: CalendarWrite, cancel: CancelFlag) throws -> CalendarEntry?
    func events(start: Date, end: Date, calendarID: String?) throws -> [CalendarEntry]
}
@MainActor public final class NativeCalendarStore: CalendarStoring {
    private let store = EKEventStore()
    public init() {}
    public func authorize() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { return true }
        guard [.notDetermined, .writeOnly].contains(status), Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil else { return false }
        return try await store.requestFullAccessToEvents()
    }
    public func calendars() -> [CalendarDestination] {
        let defaultID = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event).map { CalendarDestination(id: $0.calendarIdentifier, title: $0.title, writable: $0.allowsContentModifications, isDefault: $0.calendarIdentifier == defaultID) }
    }
    private func entry(_ event: EKEvent) -> CalendarEntry {
        CalendarEntry(id: event.eventIdentifier ?? "", title: event.title ?? "Untitled event", calendarID: event.calendar.calendarIdentifier, calendarName: event.calendar.title, start: event.startDate, end: event.endDate, allDay: event.isAllDay)
    }
    public func save(_ write: CalendarWrite, cancel: CancelFlag) throws -> CalendarEntry? {
        guard !cancel.isSet, !Task.isCancelled else { throw CancellationError() }
        guard let calendar = store.calendar(withIdentifier: write.calendarID), calendar.allowsContentModifications else { throw CalendarFailure.unavailable }
        let event = EKEvent(eventStore: store)
        event.title = write.title; event.calendar = calendar; event.startDate = write.start; event.endDate = write.end
        event.timeZone = write.timeZone; event.isAllDay = false
        guard !cancel.isSet, !Task.isCancelled else { throw CancellationError() }
        try store.save(event, span: .thisEvent, commit: true)
        guard let id = event.eventIdentifier, let saved = store.event(withIdentifier: id) else { return nil }
        return entry(saved)
    }
    public func events(start: Date, end: Date, calendarID: String?) throws -> [CalendarEntry] {
        var calendars: [EKCalendar]?
        if let calendarID {
            guard let calendar = store.calendar(withIdentifier: calendarID) else { throw CalendarFailure.unavailable }
            calendars = [calendar]
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).filter { $0.status != .canceled }.map(entry)
    }
}
private enum CalendarFailure: Error { case unavailable }

public actor CalendarController {
    private var store: CalendarStoring?
    private let clock: () -> Date
    private let timeZone: TimeZone
    private struct Pending { var draft: CalendarDraft; var start: Date?; var expires: Date }
    private var pending: Pending?
    public init(store: CalendarStoring? = nil, timeZone: TimeZone = .current, clock: @escaping () -> Date = Date.init) {
        self.store = store; self.timeZone = timeZone; self.clock = clock
    }
    public func clearPending() { pending = nil }
    private func outcome(_ ok: Bool, _ message: String, clarify: Bool = false) -> CalendarOutcome {
        var result = ExecResult(); result.ok = ok; result.note = message; result.needsClarification = clarify
        return CalendarOutcome(result: result)
    }
    public func followup(_ text: String, cancel: CancelFlag) async -> CalendarOutcome? {
        guard let saved = pending else { return nil }; pending = nil
        guard !cancel.isSet, !Task.isCancelled, saved.expires > clock(), text.split(separator: " ").count <= 16 else { return nil }
        var draft = saved.draft
        if saved.start != nil {
            guard CalendarParsing.minutes(text) != nil else { return nil }
            draft.duration = text
            return await create(draft, startOverride: saved.start, cancel: cancel)
        }
        guard ReminderParsing.looksLikeTime(text) else { return nil }
        let answer = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        let (schedule, duration) = CalendarParsing.splitDuration(answer)
        draft.schedule = schedule
        if let duration { draft.duration = duration }
        if let original = saved.draft.schedule {
            let hint = ReminderParsing.dayHint(original) ?? original
            // Preserve a known day when the answer supplies just a time.
            if ReminderParsing.groups(#"^(?:at\s+)?(?:[a-z]+|\d{1,2})(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)\.?$|^(?:noon|midnight)$"#, schedule) != nil,
               !hint.lowercased().hasPrefix("at ") {
                draft.schedule = hint + " at " + (schedule.lowercased().hasPrefix("at ") ? String(schedule.dropFirst(3)) : schedule)
            }
        }
        return await create(draft, cancel: cancel)
    }
    public func perform(_ request: CalendarRequest, cancel: CancelFlag) async -> CalendarOutcome {
        pending = nil
        switch request {
        case let .create(draft): return await create(draft, cancel: cancel)
        case let .agenda(day, name): return await agenda(day: day, name: name, cancel: cancel)
        }
    }
    private func access(cancel: CancelFlag) async -> CalendarStoring? {
        guard !cancel.isSet, !Task.isCancelled else { return nil }
        if store == nil { store = await NativeCalendarStore() }
        guard let store, (try? await store.authorize()) == true, !cancel.isSet, !Task.isCancelled else { return nil }
        return store
    }
    private func create(_ draft: CalendarDraft, startOverride: Date? = nil, cancel: CancelFlag) async -> CalendarOutcome {
        guard !cancel.isSet, !Task.isCancelled else { return outcome(false, "Stopped") }
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.title.count <= 300, !draft.title.contains("\0") else { return outcome(false, "Name the event you want to create") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        func ask(_ message: String, start: Date? = nil) -> CalendarOutcome {
            pending = Pending(draft: draft, start: start, expires: clock().addingTimeInterval(90))
            return outcome(false, message, clarify: true)
        }
        let start: Date
        if let startOverride { start = startOverride }
        else {
            guard let schedule = draft.schedule, !schedule.isEmpty else { return ask("When? Say tomorrow at 3 PM") }
            guard ReminderParsing.groups(#"^(?:today\b|tomorrow\b|on\s+|\d{4}-\d{2}-\d{2})"#, schedule) != nil else { return ask("Include the day and time, like tomorrow at 3 PM") }
            switch ReminderParsing.resolve(schedule, now: clock(), calendar: calendar) {
            case let .ready(date, allDay):
                guard let date, !allDay else { return ask("What time? Say tomorrow at 3 PM") }; start = date
            case .clarify: return ask("Say an unambiguous future date and time, like tomorrow at 3 PM")
            }
        }
        guard let minutes = CalendarParsing.minutes(draft.duration) else { return ask("How long? Say 30 minutes or one hour", start: start) }
        let end = start.addingTimeInterval(Double(minutes) * 60)
        guard let store = await access(cancel: cancel) else { return outcome(false, cancel.isSet ? "Stopped" : "Allow full Calendar access in System Settings → Privacy & Security → Calendars") }
        let calendars = await store.calendars()
        // Resolve an explicit destination without falling back to the default calendar.
        let destinations = calendars.filter { item in draft.calendar.map { item.title.caseInsensitiveCompare($0) == .orderedSame } ?? item.isDefault }
        guard destinations.count == 1, let destination = destinations.first, destination.writable else { return outcome(false, "Choose one unique writable calendar, or set a default in Calendar") }
        guard !cancel.isSet, !Task.isCancelled else { return outcome(false, "Stopped") }
        guard start > clock() else { return outcome(false, "That time has passed. Repeat with a future date and time") }
        let saved: CalendarEntry?
        do { saved = try await store.save(CalendarWrite(title: draft.title, calendarID: destination.id, start: start, end: end, timeZone: timeZone), cancel: cancel) }
        catch { return outcome(false, cancel.isSet ? "Stopped" : "Could not confirm event creation. Check Calendar before retrying") }
        guard !cancel.isSet, !Task.isCancelled else { return outcome(false, "Stopped") }
        guard let saved, !saved.id.isEmpty, saved.title == draft.title, saved.calendarID == destination.id, !saved.allDay,
              abs(saved.start.timeIntervalSince(start)) < 1, abs(saved.end.timeIntervalSince(end)) < 1 else { return outcome(false, "Event may exist, but verification failed. Check Calendar before retrying") }
        let f = DateFormatter(); f.timeZone = timeZone; f.dateStyle = .medium; f.timeStyle = .short
        return outcome(true, "Created \(draft.title): \(f.string(from: start)), \(minutes) min, in \(destination.title) (\(timeZone.abbreviation(for: start) ?? timeZone.identifier))")
    }
    private func agenda(day: String, name: String?, cancel: CancelFlag) async -> CalendarOutcome {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        guard case let .ready(date, allDay) = ReminderParsing.resolve(day, now: clock(), calendar: calendar), let start = date, allDay,
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return outcome(false, "Ask for today, tomorrow, or a future date such as on October 12 2027") }
        guard let store = await access(cancel: cancel) else { return outcome(false, cancel.isSet ? "Stopped" : "Allow full Calendar access in System Settings → Privacy & Security → Calendars") }
        var calendarID: String?
        if let name {
            let matches = await store.calendars().filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
            guard matches.count == 1 else { return outcome(false, "Use one unique calendar name") }; calendarID = matches[0].id
        }
        guard !cancel.isSet, !Task.isCancelled else { return outcome(false, "Stopped") }
        let entries: [CalendarEntry]
        do { entries = try await store.events(start: start, end: end, calendarID: calendarID).filter { $0.start < end && $0.end > start }.sorted { $0.start < $1.start } }
        catch { return outcome(false, "Could not read Calendar events") }
        guard !cancel.isSet, !Task.isCancelled else { return outcome(false, "Stopped") }
        var result = outcome(true, entries.isEmpty ? "No calendar events for that day" : "\(entries.count) calendar events for that day")
        result.agenda = CalendarAgenda(day: start, timeZone: timeZone, entries: Array(entries.prefix(50)), total: entries.count)
        return result
    }
}
