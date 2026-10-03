import Foundation

/// One spoken command, end to end, as a stream of events:
///
///   route (Jev) -> fast path -> accessibility press or computer use (if needed) -> check -> one retry
public enum PipelineEvent {
    case agenda(CalendarAgenda)
    case thinking(String)
    case clarification(String)
    case plan(Plan)
    case ran(ExecResult)
    case axPress(label: String, ok: Bool)
    case cuStart([String])
    case cuAction(String)
    case cuDone(AgentResult)
    case check(Verdict, label: String)
    case retry
    case error(String)
    case done(ok: Bool, summary: String)

    public var line: String {
        switch self {
        case let .agenda(a): return "agenda    \(a.total) events (details omitted)"
        case let .clarification(t): return "clarify   \(t)"
        case let .thinking(t): return "heard     \(t)"
        case let .plan(p): return "plan      \(p.json)"
        case let .ran(r): return "ran       \(r.ok ? "✓" : "✗") \(r.ran.joined(separator: " ; ")) \(r.note)"
        case let .axPress(label, ok): return "press     \(ok ? "✓" : "✗") \(label)"
        case let .cuStart(apps): return "computer  use in \(apps.joined(separator: ", "))"
        case let .cuAction(a): return "  \(a)"
        case let .cuDone(r): return "computer  \(r.ok ? "✓" : "✗") \(r.summary)  (\(r.turns) turns, \(String(format: "%.1f", r.seconds))s, \(r.inputTokens) in / \(r.outputTokens) out tok)"
        case let .check(v, label): return "\(label.padding(toLength: 9, withPad: " ", startingAt: 0)) \(v.status.rawValue) \(v.detail)\(v.p.map { String(format: "  p=%.2f", $0) } ?? "")"
        case .retry: return "retry     once, with what went wrong"
        case let .error(m): return "error     \(m)"
        case let .done(ok, s): return "notch     \(ok ? "●" : "○") \(s)"
        }
    }
}

public final class Pipeline {
    let jev: Jev
    let executor: Executor
    let runner: Runner
    let calendar: CalendarController
    let reminders: ReminderController
    let route: (String) async throws -> Plan
    public var useComputerUse = Features.computerUse
    public var check = true
    static let runsDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".varta/runs")

    public init(jev: Jev, executor: Executor = Executor(), runner: Runner = SystemRunner(),
                route: ((String) async throws -> Plan)? = nil, reminders: ReminderController = ReminderController(), calendar: CalendarController = CalendarController()) {
        self.calendar = calendar
        self.reminders = reminders
        self.jev = jev
        self.executor = executor
        self.runner = runner
        self.route = route ?? { try await Router.route(jev: jev, transcript: $0) }
    }

    public func clearPendingReminder() async { await reminders.clearPending(); await calendar.clearPending() }

    public func run(_ text: String, cancel: CancelFlag = CancelFlag(), emit: @escaping (PipelineEvent) -> Void) async {
        guard !stopped(cancel, emit: emit) else { return }
        let browserOrigin = executor.browserController.captureForeground()
        let finderDocument = FinderRequest.parse(text)?.operation == "current" ? executor.finderController.captureDocument() : nil
        emit(.thinking(text))
        if let continued = await reminders.followup(text, cancel: cancel) {
            guard !stopped(cancel, emit: emit) else { return }
            emit(continued.needsClarification ? .clarification(continued.note) : .done(ok: continued.ok, summary: continued.note))
            return
        }
        if let continued = await calendar.followup(text, cancel: cancel) {
            guard !stopped(cancel, emit: emit) else { return }
            emit(continued.result.needsClarification ? .clarification(continued.result.note) : .done(ok: continued.result.ok, summary: continued.result.note))
            return
        }
        let plan: Plan
        do {
            plan = try await route(text)
        } catch {
            guard !stopped(cancel, emit: emit) else { return }
            emit(.error("\(error)"))
            emit(.done(ok: false, summary: "Jev is unreachable"))
            return
        }
        guard !stopped(cancel, emit: emit) else { return }
        emit(.plan(plan))
        if plan.route == .clarify {
            emit(.done(ok: false, summary: "Didn't catch that"))
            return
        }

        if plan.intent == "app_task" {
            await appTask(plan, cancel: cancel, emit: emit)
            return
        }

        // Low confidence, or an argument Jev couldn't resolve: with computer use off there's nothing to fall back to.
        if plan.route == .computerUse && !useComputerUse {
            emit(.done(ok: false, summary: "Not sure what you meant. Try again"))
            return
        }

        guard !stopped(cancel, emit: emit) else { return }
        if plan.intent == "calendar_control", plan.route == .fastpath {
            let request: CalendarRequest
            if plan.arg("operation") == "agenda", let day = plan.arg("day") {
                request = .agenda(day: day, calendar: plan.arg("calendar"))
            } else if plan.arg("operation") == "create", let title = plan.arg("title") {
                request = .create(CalendarDraft(title: title, schedule: plan.arg("schedule"), duration: plan.arg("duration"), calendar: plan.arg("calendar")))
            } else { emit(.done(ok: false, summary: "Say an event title, date and duration")); return }
            let outcome = await calendar.perform(request, cancel: cancel)
            guard !stopped(cancel, emit: emit) else { return }
            if let agenda = outcome.agenda { emit(.agenda(agenda)) }
            emit(outcome.result.needsClarification ? .clarification(outcome.result.note) : .done(ok: outcome.result.ok, summary: outcome.result.note))
            return
        }
        if plan.intent == "create_reminder", plan.route == .fastpath, let title = plan.arg("title") {
            let res = await reminders.create(ReminderDraft(title: title, list: plan.arg("list"), schedule: plan.arg("schedule")), cancel: cancel)
            guard !stopped(cancel, emit: emit) else { return }
            emit(res.needsClarification ? .clarification(res.note) : .done(ok: res.ok, summary: res.note))
            return
        }
        let res = executor.execute(plan, cancel: cancel, browserOrigin: browserOrigin, finderDocument: finderDocument)
        guard !stopped(cancel, emit: emit) else { return }
        emit(.ran(res))
        // Albums, playlists and catalogue searches need a click that only computer use could make.
        if !useComputerUse && !res.handoff.isEmpty {
            emit(.done(ok: res.ok, summary: res.note))
            return
        }
        var agent: AgentResult?
        if useComputerUse && !cancel.isSet, plan.intent == "play_music", !res.handoff.isEmpty, plan.arg("player") == "Spotify" {
            agent = await computerUse(task: res.handoff + " Stop as soon as it is playing.", apps: ["Spotify"], cancel: cancel, emit: emit)
        }

        if ["finder_control", "audio_control", "playback_control", "browser_control", "create_note", "append_note"].contains(plan.intent) {
            emit(.done(ok: res.ok, summary: res.note))
            return
        }

        var verdict: Verdict?
        if check && (res.ok || agent != nil) && !cancel.isSet {
            verdict = await Verifier(jev: jev, runner: runner).check(plan)
            guard !stopped(cancel, emit: emit) else { return }
            emit(.check(verdict!, label: "check"))
            if verdict!.status == .mismatch, useComputerUse, !cancel.isSet, let task = retryTask(plan, verdict!, cancel: cancel) {
                emit(.retry)
                agent = await computerUse(task: task, apps: ["Spotify"], cancel: cancel, emit: emit)
                guard !stopped(cancel, emit: emit) else { return }
                verdict = await Verifier(jev: jev, runner: runner).check(plan)
                guard !stopped(cancel, emit: emit) else { return }
                emit(.check(verdict!, label: "recheck"))
            }
        }
        guard !stopped(cancel, emit: emit) else { return }
        let (ok, line) = Pipeline.headline(plan, res, verdict)
        emit(.done(ok: ok, summary: line))
    }

    /// Tasks inside an app: try one accessibility press first; computer use when that isn't enough.
    func appTask(_ plan: Plan, cancel: CancelFlag, emit: @escaping (PipelineEvent) -> Void) async {
        guard !stopped(cancel, emit: emit) else { return }
        guard let app = plan.arg("app") else {
            emit(.done(ok: false, summary: "Which app should do that?"))
            return
        }
        var res = ExecResult()
        executor.exec(&res, ["open", "-a", app], cancel: cancel)
        guard !stopped(cancel, emit: emit) else { return }
        for _ in 0..<20 where Observe.frontmostApp() != app {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !stopped(cancel, emit: emit) else { return }
        }

        if Permissions.accessibility && !cancel.isSet {
            let command = Candidates.clean(plan.transcript)
            let controls = AXTier.controls(app: app)
            if let d = try? await AXTier.decide(jev: jev, command: command, app: app, controls: controls, cancel: cancel),
               d.shouldPress, let control = d.control {
                guard !stopped(cancel, emit: emit) else { return }
                let ok = AXTier.press(control, cancel: cancel)
                guard !stopped(cancel, emit: emit) else { return }
                emit(.axPress(label: control.label, ok: ok))
                if ok {
                    emit(.check(Verdict(status: .unverified, detail: "pressed \(control.label)"), label: "check"))
                    emit(.done(ok: true, summary: "Done: \(control.label.components(separatedBy: " › ").last ?? control.label)"))
                    return
                }
            }
        }
        guard !stopped(cancel, emit: emit) else { return }
        guard useComputerUse else {
            emit(.done(ok: false, summary: "That action isn't supported yet"))
            return
        }
        let agent = await computerUse(task: "The user said: \"\(plan.transcript)\". \(app) is open. Do exactly that in \(app), nothing more.",
                                      apps: [app], cancel: cancel, emit: emit)
        emit(.check(Verdict(status: .unverified, detail: "computer use reports: \(agent.summary)"), label: "check"))
        guard !stopped(cancel, emit: emit) else { return }
        let s = agent.summary
        emit(.done(ok: agent.ok, summary: s.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? s))
    }

    func computerUse(task: String, apps: [String], cancel: CancelFlag, emit: @escaping (PipelineEvent) -> Void) async -> AgentResult {
        if cancel.isSet || Task.isCancelled { return AgentResult(ok: false, summary: "Stopped") }
        guard Features.computerUse else {
            let r = AgentResult(ok: false, summary: "FAILED: computer use is turned off")
            emit(.cuDone(r))
            return r
        }
        var missing: [String] = []
        if !Permissions.accessibility { missing.append("Accessibility") }
        if !Permissions.screenRecording { missing.append("Screen Recording") }
        if !missing.isEmpty {
            let r = AgentResult(ok: false, summary: "FAILED: Varta needs \(missing.joined(separator: " and ")) permission")
            emit(.cuDone(r))
            return r
        }
        guard let route = ClaudeRoute.fromCredentials() else {
            let r = AgentResult(ok: false, summary: "FAILED: no Anthropic or AI Gateway key")
            emit(.cuDone(r))
            return r
        }
        var doneCheck: (() async -> String?)?
        if apps.contains("Spotify") {
            let before = Observe.spotify(runner)
            try? await Task.sleep(nanoseconds: 500_000_000) // let Spotify render the search results
            let runner = self.runner
            doneCheck = {
                // Something new started playing: stop and let the verifier judge it (saves a model turn).
                for _ in 0..<5 {
                    if let now = Observe.spotify(runner), now != before { return "playing \(now["track"]!) — \(now["artist"]!)" }
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                return nil
            }
        }
        if cancel.isSet || Task.isCancelled { return AgentResult(ok: false, summary: "Stopped") }
        emit(.cuStart(apps))
        let hands = MacHands(app: apps[0])
        let r = await ComputerAgent(route: route).run(task: task, apps: apps, hands: hands, cancel: cancel,
                                                      onAction: { emit(.cuAction($0)) }, doneCheck: doneCheck)
        emit(.cuDone(r))
        return r
    }

    func retryTask(_ plan: Plan, _ v: Verdict, cancel: CancelFlag) -> String? {
        guard !cancel.isSet && !Task.isCancelled else { return nil }
        guard plan.intent == "play_music", plan.arg("player") == "Spotify", let url = plan.urls.first else { return nil }
        _ = runner.run(["open", url], timeout: 10) // show the search results
        let wrong = v.nowPlaying.map { "Spotify is playing \"\($0["track"]!)\" by \($0["artist"]!), which is not" } ?? "Spotify is not playing"
        return "The user said: \"\(plan.transcript)\". \(wrong) what they asked for. Find what they asked for in Spotify (search if needed) and play it. Stop as soon as the right thing is playing."
    }

    @discardableResult
    private func stopped(_ cancel: CancelFlag, emit: (PipelineEvent) -> Void) -> Bool {
        guard cancel.isSet || Task.isCancelled else { return false }
        cancel.cancel()
        emit(.done(ok: false, summary: "Stopped"))
        return true
    }

    /// One short line for the notch.
    static func headline(_ plan: Plan, _ res: ExecResult, _ v: Verdict?) -> (Bool, String) {
        func doneLine() -> String {
            switch plan.intent {
            case "web_search": return "Opened \(plan.urls.count) search\(plan.urls.count == 1 ? "" : "es")"
            case "open_site": return "Opened \(Verifier.host(plan.urls.first ?? ""))"
            case "open_app": return "Opened \(plan.arg("app") ?? "the app")"
            case "play_music": return "Playing \(plan.arg("query") ?? "music")"
            default: return "Done"
            }
        }
        if let v {
            switch v.status {
            case .verified:
                if let np = v.nowPlaying { return (true, "Playing \(np["track"]!) — \(np["artist"]!)") }
                if plan.intent == "open_site", let t = v.page?["title"], !t.isEmpty { return (true, "Opened \(t)") }
                return (true, doneLine())
            case .mismatch: return (false, "Didn't get it right: \(v.detail)")
            case .unsure: return (true, "Maybe: \(v.detail)")
            case .unverified: if res.ok { return (true, doneLine()) }
            }
        }
        if !res.ok { return (false, res.note.isEmpty ? "Couldn't do that" : res.note) }
        return (true, doneLine())
    }
}
