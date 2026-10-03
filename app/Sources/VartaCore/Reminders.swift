import EventKit
import Foundation

public struct ReminderList: Equatable {
    public let id: String, title: String
    public let writable: Bool, isDefault: Bool
    public init(id: String, title: String, writable: Bool = true, isDefault: Bool = false) {
        self.id = id; self.title = title; self.writable = writable; self.isDefault = isDefault
    }
}
public struct ReminderWrite {
    public let title: String, listID: String
    public let due: Date?
    public let allDay: Bool
    public let timeZone: TimeZone
}
public struct ReminderSaved {
    public let id: String, title: String, listID: String
    public let due: Date?
    public let allDay: Bool
    public let alarms: [Date]
    public init(id: String, title: String, listID: String, due: Date?, allDay: Bool, alarms: [Date]) {
        self.id = id; self.title = title; self.listID = listID; self.due = due; self.allDay = allDay; self.alarms = alarms
    }
}
@MainActor public protocol ReminderStoring {
    func authorize() async throws -> Bool
    func lists() -> [ReminderList]
    /// One save attempt, followed by readback of that ID. Never retries a write.
    func save(_ request: ReminderWrite, cancel: CancelFlag) throws -> ReminderSaved?
}

@MainActor public final class NativeReminderStore: ReminderStoring {
    private let store = EKEventStore()
    public init() {}
    public func authorize() async throws -> Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess { return true }
        guard status == .notDetermined,
              Bundle.main.object(forInfoDictionaryKey: "NSRemindersFullAccessUsageDescription") != nil else { return false }
        return try await store.requestFullAccessToReminders()
    }
    public func lists() -> [ReminderList] {
        let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return store.calendars(for: .reminder).map {
            ReminderList(id: $0.calendarIdentifier, title: $0.title, writable: $0.allowsContentModifications, isDefault: $0.calendarIdentifier == defaultID)
        }
    }
    public func save(_ request: ReminderWrite, cancel: CancelFlag) throws -> ReminderSaved? {
        guard !cancel.isSet, !Task.isCancelled else { throw CancellationError() }
        guard let list = store.calendar(withIdentifier: request.listID), list.allowsContentModifications else { throw ReminderFailure.listChanged }
        let reminder = EKReminder(eventStore: store)
        reminder.title = request.title; reminder.calendar = list
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = request.timeZone
        if let due = request.due {
            let fields: Set<Calendar.Component> = request.allDay ? [.year, .month, .day] : [.year, .month, .day, .hour, .minute, .second]
            var parts = calendar.dateComponents(fields, from: due); parts.timeZone = request.timeZone; parts.calendar = calendar
            reminder.dueDateComponents = parts
            if !request.allDay { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        guard !cancel.isSet, !Task.isCancelled else { throw CancellationError() }
        try store.save(reminder, commit: true)
        guard let saved = store.calendarItem(withIdentifier: reminder.calendarItemIdentifier) as? EKReminder else { return nil }
        let due = saved.dueDateComponents.flatMap { calendar.date(from: $0) }
        return ReminderSaved(id: saved.calendarItemIdentifier, title: saved.title ?? "", listID: saved.calendar.calendarIdentifier,
                             due: due, allDay: saved.dueDateComponents != nil && saved.dueDateComponents?.hour == nil,
                             alarms: (saved.alarms ?? []).compactMap(\.absoluteDate))
    }
}
private enum ReminderFailure: Error { case listChanged }

public actor ReminderController {
    private var store: ReminderStoring?
    private let clock: () -> Date
    private let timeZone: TimeZone
    private var pending: (draft: ReminderDraft, expires: Date)?
    public init(store: ReminderStoring? = nil, timeZone: TimeZone = .current, clock: @escaping () -> Date = Date.init) {
        self.store = store; self.timeZone = timeZone; self.clock = clock
    }
    public func clearPending() { pending = nil }
    private func result(_ ok: Bool, _ text: String, clarify: Bool = false) -> ExecResult { var r = ExecResult(); r.ok = ok; r.note = text; r.needsClarification = clarify; return r }

    /// Only a short temporal answer continues the pending request. A different command
    /// replaces it, and expiry/Esc prevent an unrelated future time from making a reminder.
    public func followup(_ text: String, cancel: CancelFlag) async -> ExecResult? {
        guard !cancel.isSet, !Task.isCancelled else { return nil }
        guard let saved = pending else { return nil }
        pending = nil
        guard saved.expires > clock(), ReminderParsing.looksLikeTime(text), text.split(separator: " ").count <= 12 else { return nil }
        var schedule = text
        if let hint = ReminderParsing.dayHint(saved.draft.schedule),
           ReminderParsing.groups(#"^(?:at\s+)?(?:[a-z]+|\d{1,2})(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)\.?$|^(?:noon|midnight)$"#, ReminderParsing.clean(text)) != nil {
            let time = text.lowercased().hasPrefix("at ") ? String(text.dropFirst(3)) : text
            schedule = hint + " at " + time
        }
        return await create(ReminderDraft(title: saved.draft.title, list: saved.draft.list, schedule: schedule), cancel: cancel)
    }
    public func create(_ draft: ReminderDraft, cancel: CancelFlag) async -> ExecResult {
        guard !cancel.isSet, !Task.isCancelled else { return result(false, "Stopped") }
        pending = nil
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, draft.title.count <= 300,
              !draft.title.contains("\0") else { return result(false, "Say what you want to be reminded about") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let resolution = ReminderParsing.resolve(draft.schedule, now: clock(), calendar: calendar)
        let due: Date?, allDay: Bool
        switch resolution {
        case let .ready(date, isAllDay): due = date; allDay = isAllDay
        case let .clarify(question):
            pending = (draft, clock().addingTimeInterval(90))
            return result(false, question, clarify: true)
        }
        if store == nil { store = await NativeReminderStore() }
        guard let store else { return result(false, "Could not open Reminders") }
        do {
            guard try await store.authorize() else {
                return result(false, "Allow Varta in System Settings → Privacy & Security → Reminders, then repeat the command")
            }
        } catch { return result(false, "Could not get Reminders access. Check System Settings") }
        guard !cancel.isSet, !Task.isCancelled else { return result(false, "Stopped") }
        let lists = await store.lists()
        let matches: [ReminderList]
        if let name = draft.list { matches = lists.filter { $0.title.caseInsensitiveCompare(name) == .orderedSame } }
        else { matches = lists.filter(\.isDefault) }
        guard matches.count == 1, let list = matches.first else {
            return result(false, draft.list == nil ? "Choose a default list in Apple Reminders first" : "Use one unique existing Reminders list name")
        }
        guard list.writable else { return result(false, "That Reminders list is read-only") }
        guard !cancel.isSet, !Task.isCancelled else { return result(false, "Stopped") }
        if let due, !allDay, due <= clock() { return result(false, "That time passed while waiting. Please give a new time") }
        let request = ReminderWrite(title: draft.title, listID: list.id, due: due, allDay: allDay, timeZone: timeZone)
        let saved: ReminderSaved?
        do { saved = try await store.save(request, cancel: cancel) }
        catch is CancellationError { return result(false, "Stopped") }
        catch { return result(false, "Could not confirm reminder creation. Check Reminders before retrying") }
        guard !cancel.isSet, !Task.isCancelled else { return result(false, "Stopped") }
        func sameDate(_ a: Date?, _ b: Date?) -> Bool {
            if a == nil && b == nil { return true }
            guard let a, let b else { return false }; return abs(a.timeIntervalSince(b)) < 1.1
        }
        guard let saved, !saved.id.isEmpty, saved.title == draft.title, saved.listID == list.id,
              saved.allDay == allDay, sameDate(saved.due, due),
              (due == nil || allDay ? saved.alarms.isEmpty : saved.alarms.count == 1 && sameDate(saved.alarms.first, due)) else {
            return result(false, "Reminder may have been created, but verification failed. Check Reminders before retrying")
        }
        let when: String
        if let due {
            let formatter = DateFormatter(); formatter.locale = .current; formatter.timeZone = timeZone
            formatter.dateStyle = .medium; formatter.timeStyle = allDay ? .none : .short
            when = formatter.string(from: due) + (allDay ? " (all day)" : " (\(timeZone.abbreviation(for: due) ?? timeZone.identifier))")
        } else { when = "no due date" }
        return result(true, "Reminder: \(draft.title) — \(when), in \(list.title)")
    }
}
