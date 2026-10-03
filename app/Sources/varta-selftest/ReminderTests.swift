import Foundation
import VartaCore

@MainActor func reminderTests() async {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 14, minute: 0))!
    func date(_ raw: String?) -> (Date?, Bool)? {
        if case let .ready(d, allDay) = ReminderParsing.resolve(raw, now: now, calendar: cal) { return (d, allDay) }; return nil
    }
    expect(date(nil)?.0 == nil && date(nil) != nil, "undated reminder remains undated")
    expect(date("in 20 minutes")?.0 == now.addingTimeInterval(1200), "relative minutes resolve exactly")
    expect(date("in twenty five minutes")?.0 == now.addingTimeInterval(1500), "spoken relative duration")
    expect(date("tomorrow at 9 AM")?.0 == cal.date(from: DateComponents(year:2026,month:10,day:4,hour:9)), "tomorrow time respects local zone")
    expect(date("tomorrow at six PM")?.0 == cal.date(from: DateComponents(year:2026,month:10,day:4,hour:18)), "spoken hour with PM")
    expect(date("on October 10 2026 at 15:30")?.0 == cal.date(from: DateComponents(year:2026,month:10,day:10,hour:15,minute:30)), "explicit date and 24-hour time")
    expect(date("on 2026-10-10 at noon")?.0 == cal.date(from: DateComponents(year:2026,month:10,day:10,hour:12)), "ISO date and noon")
    expect(date("tomorrow")?.1 == true, "date-only reminders are all day")
    for invalid in ["tomorrow at six", "at 6", "tomorrow morning", "on February 30 2027", "in zero minutes", "in -2 hours", "today at 9 AM", "tomorrow at 25:00", "every Monday", "when I get home"] {
        expect(date(invalid) == nil, "ambiguous, past or invalid time requires clarification: \(invalid)")
    }
    var pacific = cal; pacific.timeZone = TimeZone(identifier:"America/Los_Angeles")!
    for raw in ["on March 14 2027 at 02:30", "on November 1 2026 at 01:30"] {
        if case .clarify = ReminderParsing.resolve(raw, now: now, calendar: pacific) { expect(true, "DST ambiguity rejected") }
        else { expect(false, "DST ambiguity rejected: \(raw)") }
    }
    expect(ReminderParsing.draft("Remind me tomorrow at 9 AM to review the release") == ReminderDraft(title:"review the release",schedule:"tomorrow at 9 AM"), "prefix timing separated from task")
    expect(ReminderParsing.draft("Remind me to check the build in twenty five minutes") == ReminderDraft(title:"check the build",schedule:"in twenty five minutes"), "suffix timing separated from task")
    expect(ReminderParsing.draft("Add buy milk to my reminders") == ReminderDraft(title:"buy milk"), "no-date task grammar")
    expect(ReminderParsing.draft("Remind me tomorrow to buy milk in my Shopping list") == ReminderDraft(title:"buy milk",list:"Shopping",schedule:"tomorrow"), "named list extraction")
    expect(ReminderParsing.draft("Delete my reminders") == nil, "destructive request not parsed as creation")

    final class Store: ReminderStoring {
        var access = true, saves = 0, wrong = false, fail = false
        var entries = [ReminderList(id:"default", title:"Tasks", isDefault:true)]
        var writes: [ReminderWrite] = []
        var onAccess: (() -> Void)?
        func authorize() async throws -> Bool { onAccess?(); return access }
        func lists() -> [ReminderList] { entries }
        func save(_ request: ReminderWrite, cancel: CancelFlag) throws -> ReminderSaved? {
            guard !cancel.isSet else { throw CancellationError() }
            saves += 1; writes.append(request)
            if fail { throw NSError(domain:"test",code:1) }
            return ReminderSaved(id:"saved",title:wrong ? "wrong" : request.title,listID:request.listID,due:request.due,allDay:request.allDay,alarms:request.due != nil && !request.allDay ? [request.due!] : [])
        }
    }
    let store = Store(), service = ReminderController(store: Store(),timeZone:cal.timeZone,clock:{now})
    let normal = ReminderController(store:store,timeZone:cal.timeZone,clock:{now})
    let saved = await normal.create(ReminderDraft(title:"review release",schedule:"tomorrow at 9 AM"),cancel:CancelFlag())
    expect(saved.ok && store.saves == 1 && store.writes.first?.due == date("tomorrow at 9 AM")?.0, "reminder saves once with resolved date")
    let question = await normal.create(ReminderDraft(title:"call mom",schedule:"tomorrow at six"),cancel:CancelFlag())
    expect(question.needsClarification && store.saves == 1, "ambiguous time saves nothing")
    let followup = await normal.followup("PM",cancel:CancelFlag())
    expect(followup?.ok == true && store.writes.last?.title == "call mom" && store.writes.last?.due == date("tomorrow at 6 PM")?.0, "follow-up retains task and original day")
    _ = await service.create(ReminderDraft(title:"test",schedule:"at six"),cancel:CancelFlag())
    await service.clearPending()
    let cleared = await service.followup("6 PM",cancel:CancelFlag())
    expect(cleared == nil, "Esc clears pending reminder")
    _ = await service.create(ReminderDraft(title:"test",schedule:"at six"),cancel:CancelFlag())
    let replacement = await service.followup("open Chrome",cancel:CancelFlag())
    let stale = await service.followup("6 PM",cancel:CancelFlag())
    expect(replacement == nil && stale == nil, "unrelated command replaces pending reminder")
    let denied = Store(); denied.access = false
    let denial = await ReminderController(store:denied,clock:{now}).create(ReminderDraft(title:"test"),cancel:CancelFlag())
    expect(!denial.ok && denied.saves == 0, "denied access saves nothing")
    let flag = CancelFlag(), cancelled = Store(); cancelled.onAccess = { flag.cancel() }
    let stopped = await ReminderController(store:cancelled,clock:{now}).create(ReminderDraft(title:"test"),cancel:flag)
    expect(!stopped.ok && cancelled.saves == 0, "cancellation during permission prompt prevents save")
    for entries in [[], [ReminderList(id:"1",title:"Work"),ReminderList(id:"2",title:"Work")], [ReminderList(id:"1",title:"Work",writable:false)]] {
        let s = Store(); s.entries = entries
        let r = await ReminderController(store:s,clock:{now}).create(ReminderDraft(title:"test",list:"Work"),cancel:CancelFlag())
        expect(!r.ok && s.saves == 0, "missing, duplicate and read-only lists rejected")
    }
    for shouldThrow in [false,true] {
        let s = Store(); s.wrong = !shouldThrow; s.fail = shouldThrow
        let r = await ReminderController(store:s,clock:{now}).create(ReminderDraft(title:"test"),cancel:CancelFlag())
        expect(!r.ok && s.saves == 1, "uncertain reminder write never retries")
    }
    let pipelineStore = Store()
    var routes = 0, events: [PipelineEvent] = []
    let pipeline = Pipeline(jev: Jev { throw CancellationError() }, route: { _ in
        routes += 1
        var p = Plan(transcript: "test", intent: "create_reminder", intentConfidence: 1)
        p.route = .fastpath
        p.args = ["title": Arg(.text("review release"), 1), "schedule": Arg(.text("tomorrow at six"), 1)]
        return p
    }, reminders: ReminderController(store: pipelineStore, timeZone: cal.timeZone, clock: { now }))
    await pipeline.run("Remind me tomorrow at six to review release") { events.append($0) }
    expect(events.contains { if case .clarification = $0 { return true }; return false } && pipelineStore.saves == 0, "pipeline emits clarification without saving")
    await pipeline.run("six PM") { events.append($0) }
    expect(routes == 1 && pipelineStore.saves == 1 && events.contains { if case let .done(ok, _) = $0 { return ok }; return false }, "follow-up saves once without another routing request")
    var later = now
    let expiringStore = Store()
    let expiring = ReminderController(store: expiringStore, timeZone: cal.timeZone, clock: { later })
    _ = await expiring.create(ReminderDraft(title: "test", schedule: "at six"), cancel: CancelFlag())
    later = now.addingTimeInterval(91)
    let expired = await expiring.followup("six PM", cancel: CancelFlag())
    expect(expired == nil && expiringStore.saves == 0, "expired clarification cannot create a reminder")

}
