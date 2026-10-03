import Foundation
import VartaCore

func phrasingTests() async {
    for prefix in ["Could you ", "Can you please ", "Would you ", "Please "] {
        expect(FinderRequest.parse(prefix + "open my Downloads folder?") == FinderRequest("folder", "downloads"), "polite folder request: \(prefix)")
        expect(ReminderParsing.draft(prefix + "remind me to check the build in twenty minutes?") == ReminderDraft(title:"check the build",schedule:"in twenty minutes"), "polite reminder preserves task and time")
        expect(CalendarParsing.parse(prefix + "schedule review tomorrow at 3 PM for 30 minutes?") == .create(CalendarDraft(title:"review",schedule:"tomorrow at 3 PM",duration:"30 minutes")), "polite event preserves fields")
        let note = NoteText(prefix + "append can you please check this? to my Launch Ideas note?").explicitAppend
        expect(note?.title == "Launch Ideas" && note?.body == "can you please check this?", "only leading politeness removed, literal note body preserved")
    }
    expect(CommandText.body("Could you not open Downloads?") == "not open Downloads?" && FinderRequest.parse("Could you not open Downloads?") == nil, "negation is retained and cannot execute folder grammar")
    expect(FinderRequest.parse("Take me to my Documents folder") == FinderRequest("folder", "documents"), "take me to common folder")
    expect(FinderRequest.parse("Can you show launch.pdf in Finder?") == FinderRequest("reveal", "launch.pdf"), "polite reveal with question punctuation")
    expect(ReminderParsing.draft("Set a reminder to call mom tomorrow at 9 AM") == ReminderDraft(title:"call mom",schedule:"tomorrow at 9 AM"), "set a reminder alias retains schedule")
    expect(CalendarParsing.parse("Put review on my calendar tomorrow at 3 PM for half an hour") == .create(CalendarDraft(title:"review",schedule:"tomorrow at 3 PM",duration:"half an hour")), "put on calendar retains duration")
    expect(CalendarParsing.parse("What's on my calendar for tomorrow?") == .agenda(day:"tomorrow",calendar:nil), "agenda for tomorrow")
    expect(ReminderParsing.meridianFollowup("PM",original:"tomorrow at six") == "tomorrow at six pm", "bare PM completes existing clock")
    expect(ReminderParsing.meridianFollowup("PM",original:"tomorrow") == nil, "bare PM cannot invent missing hour")
    for text in ["Could you delete launch.pdf?", "Please open Downloads and delete everything"] {
        expect(FinderRequest.parse(text) == nil, "polite wrapper cannot bypass Finder scope")
    }
    func answer(_ value: String, _ confidence: Double) -> JSON {
        obj(("choice", .string(value)), ("confidence", .number(confidence)))
    }
    for command in ["Please do not mute my Mac", "Could you not open Downloads?", "Don't open Safari", "I don't want you to pause Spotify"] {
        let prep = Router.prepare(command, apps: [], sites: [])
        let reply = JevReply(answers: ["intent":answer("audio_control",1), "audio_action":answer("unmute",1)],model:"test",inputTokens:0,latencyMs:0)
        let plan = Router.interpret(prep,reply)
        expect(plan.route == .clarify && plan.args.isEmpty && plan.urls.isEmpty && CommandFeedback.unsupported(plan) == "No action taken", "leading negation blocks even a confident opposite action")
    }
    expect(!CommandText.isNegated("Create a note called Do not forget with don't mute the microphone"), "negation inside dictated content is not a negative command")
    // The grammar is only argument extraction: model support and confidence still decide dispatch.
    for (intent, support, command) in [("finder_control","finder_supported","Could you open Downloads?"), ("create_reminder","reminder_supported","Set a reminder to call mom tomorrow"), ("calendar_control","calendar_supported","Put review on my calendar tomorrow at 3 PM for 30 minutes")] {
        let prep = Router.prepare(command,apps:[],sites:[])
        for (intentConfidence, supported, supportConfidence) in [(1.0,"none",1.0),(0.4,"yes",1.0),(1.0,"yes",0.4)] {
            let reply = JevReply(answers:["intent":answer(intent,intentConfidence), support:answer(supported,supportConfidence)],model:"test",inputTokens:0,latencyMs:0)
            expect(Router.interpret(prep,reply).route != .fastpath, "polite parsing retains semantic and confidence gates for \(intent)")
        }
        let positive = JevReply(answers:["intent":answer(intent,1), support:answer("yes",1)],model:"test",inputTokens:0,latencyMs:0)
        expect(Router.interpret(prep,positive).route == .fastpath, "valid phrase still dispatches with confident support")
        var p = Plan(transcript:command,intent:intent,intentConfidence:1)
        p.route = .computerUse
        expect(CommandFeedback.unsupported(p).contains("Try:"), "unsupported command has a concrete example")
    }
    expect(ReminderParsing.draft("Could you add buy milk to my reminders?") == ReminderDraft(title: "buy milk"), "polite undated reminder accepts question punctuation")
    var rejected = Plan(transcript: "test", intent: "finder_control", intentConfidence: 1)
    rejected.route = .computerUse
    let pipeline = Pipeline(jev: Jev { throw CancellationError() }, route: { _ in rejected })
    var messages: [String] = []
    await pipeline.run("test") { if case let .done(_, summary) = $0 { messages.append(summary) } }
    expect(messages == [CommandFeedback.unsupported(rejected)], "pipeline surfaces a feature-specific recovery example")

}
