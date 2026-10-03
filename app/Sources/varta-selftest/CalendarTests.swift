import Foundation
import VartaCore

@MainActor func calendarTests() async {
    let expected = CalendarDraft(title:"a launch review", schedule:"tomorrow at 3 PM", duration:"30 minutes")
    expect(CalendarParsing.parse("Schedule a launch review tomorrow at 3 PM for 30 minutes.") == .create(expected), "calendar title, start and duration extracted")
    expect(CalendarParsing.parse("Add a dentist appointment on October 12 at 10 AM for an hour") == .create(CalendarDraft(title:"a dentist appointment", schedule:"on October 12 at 10 AM", duration:"an hour")), "calendar explicit date grammar")
    expect(CalendarParsing.parse("Create an event called Review tomorrow at 3 PM for one hour in my Work calendar") == .create(CalendarDraft(title:"Review",schedule:"tomorrow at 3 PM",duration:"one hour",calendar:"Work")), "named calendar extraction")
    expect(CalendarParsing.parse("What's on my calendar tomorrow?") == .agenda(day:"tomorrow",calendar:nil), "agenda tomorrow grammar")
    expect(CalendarParsing.parse("What’s on my calendar?") == .agenda(day:"today",calendar:nil), "agenda defaults to today")
    expect(CalendarParsing.parse("Show my calendar tomorrow in my Work calendar") == .agenda(day:"tomorrow",calendar:"Work"), "named agenda grammar")
    expect(CalendarParsing.parse("Schedule plan for launch tomorrow at 3 PM for 30 minutes") == .create(CalendarDraft(title:"plan for launch",schedule:"tomorrow at 3 PM",duration:"30 minutes")), "for in event title preserved")
    expect(CalendarParsing.parse("Schedule an event tomorrow at 3 PM") == nil, "date cannot become a missing event title")
    expect(CalendarParsing.parse("Delete my events") == nil, "event deletion grammar rejected")
    for (text, minutes) in [("30 minutes",30),("for an hour",60),("half an hour",30),("twenty five minutes",25),("24 hours",1440)] {
        expect(CalendarParsing.minutes(text) == minutes, "duration resolves: \(text)")
    }
    for text in ["0 minutes", "-1 hours", "25 hours", "1.5 hours", "999999999999 hours", "forever", "two days"] {
        expect(CalendarParsing.minutes(text) == nil, "invalid duration rejected: \(text)")
    }
    var calendar = Calendar(identifier:.gregorian); calendar.timeZone = TimeZone(identifier:"Asia/Kolkata")!
    let now = calendar.date(from: DateComponents(year:2026,month:10,day:3,hour:14))!
    let start = calendar.date(from: DateComponents(year:2026,month:10,day:4,hour:15))!
    final class Store: CalendarStoring {
        var granted = true, fail = false, mismatch = false
        var saves = 0, reads = 0
        var writes: [CalendarWrite] = []
        var calendarsValue = [CalendarDestination(id:"work",title:"Work",isDefault:true)]
        var eventsValue: [CalendarEntry] = []
        var interval: (Date, Date, String?)?
        var onAccess: (() -> Void)?
        func authorize() async throws -> Bool { onAccess?(); return granted }
        func calendars() -> [CalendarDestination] { calendarsValue }
        func save(_ write: CalendarWrite, cancel: CancelFlag) throws -> CalendarEntry? {
            saves += 1; writes.append(write)
            if fail { throw NSError(domain:"test",code:1) }
            return CalendarEntry(id:"event",title:mismatch ? "wrong" : write.title, calendarID:write.calendarID, calendarName:"Work",start:write.start,end:write.end)
        }
        func events(start: Date, end: Date, calendarID: String?) throws -> [CalendarEntry] {
            reads += 1; interval = (start,end,calendarID)
            if fail { throw NSError(domain:"test",code:2) }
            return eventsValue
        }
    }
    let store = Store()
    let controller = CalendarController(store:store,timeZone:calendar.timeZone,clock:{now})
    let created = await controller.perform(.create(expected), cancel:CancelFlag())
    expect(created.result.ok && store.saves == 1 && store.writes[0].start == start && store.writes[0].end == start.addingTimeInterval(1800), "event saves once with exact start and duration")
    let missing = await controller.perform(.create(CalendarDraft(title:"review")),cancel:CancelFlag())
    expect(missing.result.needsClarification && store.saves == 1, "missing event time asks without writing")
    let time = await controller.followup("tomorrow at 3 PM",cancel:CancelFlag())
    expect(time?.result.needsClarification == true && store.saves == 1, "missing duration asks without writing")
    let duration = await controller.followup("for an hour",cancel:CancelFlag())
    expect(duration?.result.ok == true && store.writes.last?.title == "review" && store.writes.last?.end == start.addingTimeInterval(3600), "duration follow-up retains original event and time")
    _ = await controller.perform(.create(CalendarDraft(title:"review",schedule:"tomorrow at three",duration:"30 minutes")),cancel:CancelFlag())
    let meridian = await controller.followup("PM",cancel:CancelFlag())
    expect(meridian?.result.ok == true && store.writes.last?.start == start, "time follow-up retains original event day")
    _ = await controller.perform(.create(CalendarDraft(title:"review",schedule:"tomorrow",duration:"30 minutes")),cancel:CancelFlag())
    let dayOnly = await controller.followup("three PM",cancel:CancelFlag())
    expect(dayOnly?.result.ok == true && store.writes.last?.start == start, "date-only creation asks for time instead of becoming all-day")
    _ = await controller.perform(.create(CalendarDraft(title:"review")),cancel:CancelFlag())
    await controller.clearPending()
    let cleared = await controller.followup("tomorrow at 3 PM",cancel:CancelFlag())
    expect(cleared == nil, "Esc discards pending event")
    _ = await controller.perform(.create(CalendarDraft(title:"review")),cancel:CancelFlag())
    let unrelated = await controller.followup("open Chrome",cancel:CancelFlag())
    let stale = await controller.followup("tomorrow at 3 PM",cancel:CancelFlag())
    expect(unrelated == nil && stale == nil, "unrelated command replaces pending event")
    var later = now
    let expiring = CalendarController(store:store,timeZone:calendar.timeZone,clock:{later})
    _ = await expiring.perform(.create(CalendarDraft(title:"review")),cancel:CancelFlag())
    later = now.addingTimeInterval(91)
    let expired = await expiring.followup("tomorrow at 3 PM",cancel:CancelFlag())
    expect(expired == nil, "event clarification expires")
    for calendars in [[], [CalendarDestination(id:"x",title:"Work",writable:false,isDefault:true)], [CalendarDestination(id:"a",title:"Work"), CalendarDestination(id:"b",title:"Work")]] {
        let s = Store(); s.calendarsValue = calendars
        let c = CalendarController(store:s,timeZone:calendar.timeZone,clock:{now})
        var d = expected; d.calendar = "Work"
        let r = await c.perform(.create(d),cancel:CancelFlag())
        expect(!r.result.ok && s.saves == 0, "missing, duplicate or read-only event calendar rejected")
    }
    let denied = Store(); denied.granted = false
    let deniedController = CalendarController(store:denied,timeZone:calendar.timeZone,clock:{now})
    let deniedWrite = await deniedController.perform(.create(expected),cancel:CancelFlag())
    let deniedRead = await deniedController.perform(.agenda(day:"tomorrow",calendar:nil),cancel:CancelFlag())
    expect(!deniedWrite.result.ok && !deniedRead.result.ok && denied.saves == 0 && denied.reads == 0, "denied Calendar access prevents reads and writes")
    let flag = CancelFlag(), cancelled = Store(); cancelled.onAccess = { flag.cancel() }
    let stopped = await CalendarController(store:cancelled,timeZone:calendar.timeZone,clock:{now}).perform(.create(expected),cancel:flag)
    expect(!stopped.result.ok && cancelled.saves == 0, "cancel during Calendar authorization prevents save")
    for fail in [false,true] {
        let s = Store(); s.fail = fail; s.mismatch = !fail
        let r = await CalendarController(store:s,timeZone:calendar.timeZone,clock:{now}).perform(.create(expected),cancel:CancelFlag())
        expect(!r.result.ok && s.saves == 1, "uncertain event save never retries")
    }
    store.eventsValue = [CalendarEntry(id:"later",title:"Private title",calendarID:"work",calendarName:"Work",start:start,end:start.addingTimeInterval(3600)), CalendarEntry(id:"early",title:"Early",calendarID:"work",calendarName:"Work",start:start.addingTimeInterval(-3600),end:start), CalendarEntry(id:"outside",title:"Outside",calendarID:"work",calendarName:"Work",start:now,end:now.addingTimeInterval(3600))]
    let agenda = await controller.perform(.agenda(day:"tomorrow",calendar:"Work"),cancel:CancelFlag())
    expect(agenda.result.ok && agenda.agenda?.entries.map(\.id) == ["early","later"] && store.interval?.2 == "work", "agenda filters day overlap, orders entries and selects named calendar")
    if let a = agenda.agenda { expect(!PipelineEvent.agenda(a).line.contains("Private title"), "agenda event logs omit existing titles") }
    var pacific = calendar; pacific.timeZone = TimeZone(identifier:"America/Los_Angeles")!
    let dstStore = Store()
    _ = await CalendarController(store:dstStore,timeZone:pacific.timeZone,clock:{now}).perform(.agenda(day:"on November 1 2026",calendar:nil),cancel:CancelFlag())
    expect(dstStore.interval.map { $0.1.timeIntervalSince($0.0) == 25 * 3600 } == true, "agenda day boundary respects daylight-saving change")
    let pipelineStore = Store(); var routes = 0, events: [PipelineEvent] = []
    let pipeline = Pipeline(jev:Jev { throw CancellationError() },route:{ _ in
        routes += 1
        var p = Plan(transcript:"test",intent:"calendar_control",intentConfidence:1); p.route = .fastpath
        p.args = ["operation":Arg(.text("create"),1),"title":Arg(.text("review"),1),"schedule":Arg(.text("tomorrow at 3 PM"),1)]
        return p
    },calendar:CalendarController(store:pipelineStore,timeZone:calendar.timeZone,clock:{now}))
    await pipeline.run("Schedule review tomorrow at 3 PM") { events.append($0) }
    await pipeline.run("30 minutes") { events.append($0) }
    expect(routes == 1 && pipelineStore.saves == 1 && events.contains { if case .clarification = $0 { return true }; return false }, "pipeline duration follow-up saves once without rerouting")
}
