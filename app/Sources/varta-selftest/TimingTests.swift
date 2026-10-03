import Foundation
import VartaCore

func timingTests() {
    var now = 10.0
    let timing = CommandTiming(clock: { now })
    now = 10.25; timing.transcribed(source: "cached")
    now = 10.75
    var plan = Plan(transcript: "private transcript", intent: "create_note", intentConfidence: 1)
    plan.args = ["title":Arg(.text("private title"),1)]; plan.latencyMs = 490; plan.jevMs = 450
    _ = timing.observe(.plan(plan))
    now = 11
    let sample = timing.observe(.done(ok: true, summary: "private title"))
    expect(sample?.transcriptMs == 250 && sample?.transcriptToPlanMs == 500 && sample?.planToStatusMs == 250 && sample?.releaseToStatusMs == 1000, "monotonic stages partition total command time")
    expect(sample?.routingReportedMs == 490 && sample?.jevSuccessfulAttemptMs == 450, "timing keeps provider and end-to-end route boundaries separate")
    expect(timing.finish("cancelled") == nil, "completed timing cannot be counted again")
    if let sample, let data = try? JSONEncoder().encode(sample), let text = String(data:data,encoding:.utf8) {
        expect(!text.contains("private") && !text.contains("summary") && !text.contains("args"), "timing output excludes command payload and result text")
    } else { expect(false, "timing record encodes") }
    let followup = CommandTiming(clock: { now }); now += 0.1; followup.transcribed(source:"inflight"); now += 0.2
    let clarified = followup.observe(.clarification("private question"))
    expect(clarified?.outcome == "clarification" && clarified?.transcriptToPlanMs == nil && clarified?.planToStatusMs == nil, "follow-up without routing does not invent a route duration")
    let cancelled = CommandTiming(clock: { now }); now += 0.5
    let stopped = cancelled.finish("cancelled")
    expect(stopped?.transcriptMs == nil && stopped?.releaseToStatusMs == 500, "cancelled transcription still produces an attempt record")
}
