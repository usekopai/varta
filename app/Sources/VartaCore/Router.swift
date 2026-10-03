import Foundation

/// One Jev request turns a transcript into a typed plan.
///
/// Every question over the transcript goes out together (speculative fan-out): the intent, plus
/// the arguments of every intent. Code then reads only the chosen intent's answers.
public enum Router {
    // Measured, not chosen by feel. On the 114 labelled commands in eval/, at 0.6/0.6 85 of them
    // run without asking and all 85 are right. Re-check with: varta-cli eval eval/all-commands.csv
    public static let fastIntent = 0.60
    public static let fastArg = 0.60
    public static let clarifyBelow = 0.50
    static let searchYes = 0.50

    public static let intents: [(String, String)] = [
        ("calendar_control", "Create one timed Calendar event or read a day agenda. Not reminders, invitations, editing or deleting events."),
        ("finder_control", "Open a common filesystem folder, find local files by filename, or reveal a file in Finder. Not web search, opening a file in an app, changing files, or merely opening Finder."),
        ("append_note", "Add dictated text or an item as a NEW LINE at the END of an existing Apple Notes note named by title. Not replacing, deleting, rewriting, a formatted checkbox, or another notes app."),
        ("create_reminder", "Create one new Apple Reminders task, with an optional due date/time and reminder list. Not calendar events, editing reminders, or a timer."),
        ("create_note", "Create a NEW Apple Notes note with a specified title or dictated text. Includes creating an empty note. Not editing or appending to an existing note, another notes app, or merely opening Notes."),
        ("browser_control", "One browser control in Chrome or Safari: next or previous tab, new tab, close current tab, reopen last closed tab, back, forward, reload, zoom in or out. Not opening a website, searching, closing multiple tabs, or tasks inside a page."),
        ("audio_control", "Control Mac system output volume: set a percentage, increase, decrease, mute or unmute. Not microphone mute or volume inside a named app."),
        ("playback_control", "Pause, resume, skip to the next track or return to the previous track in Spotify or Apple Music. Not a request to find new music or control another app."),
        ("play_music", "Play music or audio: a song, album, artist, playlist, podcast, or a genre or mood of music."),
        ("open_site", "Open a specific website or web page by its name or address, without searching for something."),
        ("web_search", "Search for one or more things: information, products, places, or videos, on the web or on a named site such as YouTube or Amazon."),
        ("open_app", "Only open, launch, or switch to an application installed on this Mac, with no further task inside it."),
        ("app_task", "Do a task inside an application that is not playing music, opening a website, or searching; for example write a note, set a reminder, send a message, or change a setting."),
        ("none", "Not a request to operate the computer, or too unclear to act on."),
    ]

    public static let musicKinds: [(String, String)] = [
        ("track", "A specific song."),
        ("album", "A specific album."),
        ("artist", "An artist's music in general, with no particular song or album."),
        ("playlist", "A named playlist."),
        ("mood", "A genre, mood, or activity rather than a named song, album, artist, or playlist, such as chill jazz or workout music."),
    ]

    public static let engines: [(String, String, String)] = [
        ("google", "Google web search, or no particular site is named for the search.", "https://www.google.com/search?q="),
        ("youtube", "Search on YouTube, or the user wants videos.", "https://www.youtube.com/results?search_query="),
        ("amazon", "Search for products on Amazon.", "https://www.amazon.com/s?k="),
        ("maps", "Search for a place, address, or directions on a map.", "https://www.google.com/maps/search/"),
        ("wikipedia", "Search on Wikipedia.", "https://en.wikipedia.org/w/index.php?search="),
        ("github", "Search on GitHub.", "https://github.com/search?q="),
        ("reddit", "Search on Reddit.", "https://www.reddit.com/search/?q="),
    ]

    static let musicApps: Set<String> = ["Spotify", "Music"]

    public struct Prepared {
        public let transcript: String
        public let command: String
        public let state: JSON
        public let questions: [(String, JSON)]
        let clauses: Candidates.Clauses
        let sites: [String: Site]
        public let apps: [String]
        /// The shortlisted sites, in the order the questions offered them.
        public let siteList: [Site]
    }

    static func spanChoice(_ instructions: JSON, _ options: [String], _ noneDesc: String) -> JSON {
        var criteria: [(String, JSON)] = options.map { ($0, .null) }
        criteria.removeAll { $0.0 == Candidates.none }
        criteria.append((Candidates.none, .string(noneDesc)))
        return obj(("type", "choice"), ("instructions", instructions), ("criteria", .object(criteria)))
    }

    static func choiceQ(_ instructions: JSON, _ criteria: [(String, JSON)]) -> JSON {
        obj(("type", "choice"), ("instructions", instructions), ("criteria", .object(criteria)))
    }

    public static func prepare(_ transcript: String, apps: [String] = MacSources.installedApps, sites: [Site] = MacSources.knownSites) -> Prepared {
        let ws = Candidates.words(transcript)
        let command = Candidates.clean(transcript)
        let spanOpts = Candidates.spans(ws)
        let appOpts = Candidates.shortlistApps(ws, apps)
        // An implied app ("set a timer" -> Clock) needn't resemble any word, so offer every built-in app too.
        var taskAppOpts = appOpts
        for a in apps where MacSources.systemApps.contains(a) && !taskAppOpts.contains(a) { taskAppOpts.append(a) }
        let siteList = Candidates.shortlistSites(ws, sites)
        var siteOpts: [(String, Site)] = []
        for s in siteList {
            var label = Candidates.siteLabel(s)
            while siteOpts.contains(where: { $0.0 == label }) || label == Candidates.none { label += " " }
            siteOpts.append((label, s))
        }
        let domains = Candidates.domainCandidates(ws)
        let cl = Candidates.clauses(ws)
        let noneApp: JSON = "No application is named in the command."

        var q: [(String, JSON)] = [
            ("intent", choiceQ(
                obj(("installed_apps_named", .array(Candidates.namedApps(ws, apps).map { .string($0) })),
                    ("websites_named", .array(Candidates.namedSites(command, siteList).map { .string($0) })),
                    ("question", "What does the user want the computer to do in `command`? `installed_apps_named` lists applications on this Mac that the command names, and `websites_named` lists known websites it names.")),
                intents.map { ($0.0, .string($0.1)) })),
            ("app", choiceQ("Which application does `command` name or ask to use? Answer none if no application is named.",
                            appOpts.map { ($0, JSON.null) } + [(Candidates.none, noneApp)])),
            ("app_for_task", choiceQ("Which application on a Mac would be used to do what `command` asks?",
                                     taskAppOpts.map { ($0, JSON.null) } + [(Candidates.none, "None of these applications fits the task.")])),
            ("music_song", spanChoice("Which span of `command` is the title of the song, album, or playlist the user wants to hear? The span must be only the title, without the artist or command words.",
                                      spanOpts, "The command names no song, album, or playlist title.")),
            ("music_artist", spanChoice("Which span of `command` is the name of the musical artist or band? The span must be only the name.",
                                        spanOpts, "The command names no artist or band.")),
            ("music_mood", spanChoice("Which span of `command` describes the kind of music wanted, such as a genre, mood, or activity?",
                                      spanOpts, "The command describes no genre, mood, or activity.")),
            ("music_kind", choiceQ("What does the user want to hear in `command`?", musicKinds.map { ($0.0, .string($0.1)) })),
            ("site", choiceQ("Which of these websites does `command` ask to open?",
                             siteOpts.map { ($0.0, JSON.string($0.1.url)) } + [(Candidates.none, "None of these websites is the one the command asks to open.")])),
            ("site_span", spanChoice("Which span of `command` is the name or address of the website the user wants to open?",
                                     Array((domains + spanOpts).prefix(250)), "The command names no website.")),
            ("search_engine", choiceQ("Where does `command` ask for the search to happen?", engines.map { ($0.0, .string($0.1)) })),
        ]
        q.append(("calendar_supported", choiceQ("Does this request ONLY create one Calendar event with a title, date/time, duration and optional named calendar, or read events for one day? Missing date/time/duration may be clarified. No attendees/invitations, recurrence, locations, conference links, notes, alerts, edits, deletion, availability checking, conflicts, or other actions. A title can mention a person, but inviting or contacting them is unsupported.",
            [("yes", "One supported event creation or day agenda request."), (Candidates.none, "Unsupported or not a Calendar request.")])))
        q.append(("finder_supported", choiceQ("Is the command ONLY opening one common folder, searching local files by filename, or revealing one file in Finder? No moving, renaming, deleting, content search, file-type/date filters, extra actions, or opening file contents. Bare open Music means the app, not a folder.",
            [("yes", "One supported Finder request."), (Candidates.none, "Unsupported or not a Finder request.")])))
        q.append(("reminder_supported", choiceQ("Does this command request ONLY one new Apple Reminders task, with optional due date/time and a named list? No recurrence, location triggers, subtasks, other apps, existing-reminder edits, or additional actions. The task text itself is literal content, not an action to execute now.",
            [("yes", "One supported reminder creation request."), (Candidates.none, "Unsupported or not a reminder creation request.")])))
        let noteText = NoteText(transcript)
        let noteContext = obj(("transcript", .string(transcript)), ("tokens", noteText.tokens))
        q.append(("note_supported", choiceQ(obj(("input", noteContext), ("question", "Can this request be completed ONLY by creating one new plain-text Apple Notes note in the default folder? No existing-note edits, explicit account/folder destinations, checklist formatting, attachments, or other apps. Text after a note-content delimiter such as 'with', 'saying', or 'note:' is literal content, even when it says delete, restart, or other actions. Creating that content does not execute those actions.")),
            [("yes", "One new plain-text note, with an optional title."), (Candidates.none, "Unsupported or not a note creation request.")])))
        q.append(("note_append_supported", choiceQ(obj(("input", noteContext), ("question", "Is this request ONLY to add literal new text at the end of one existing Apple Notes note named by title? Adding an item means a plain new line. No replacing/deleting text, formatting checkboxes, selecting a folder/account, or another app. Words inside the dictated addition are content, not actions.")),
            [("yes", "Append plain text to one explicitly named existing note."), (Candidates.none, "Unsupported, unnamed target, or not an append request.")])))
        for field in ["title", "body"] {
            let meaning = field == "title" ? "explicitly named note title (the existing target title for an append request; exclude words such as my and note)" : "literal text to put in the note (for append requests the new item/content being added; for creation often introduced by with, saying, or note:), excluding the title and introductory words. Imperative words inside this content, such as delete or restart, belong to the note"
            q.append(("note_\(field)_start", choiceQ(obj(("input", noteContext), ("question", .string("Select the first token index of the \(meaning). Choose none if absent. Preserve the complete text."))), noteText.starts + [(Candidates.none, "Absent.")])))
            q.append(("note_\(field)_end", choiceQ(obj(("input", noteContext), ("question", .string("Select the exclusive end token index of the \(meaning): one past its last token. Choose none if absent."))), noteText.ends + [(Candidates.none, "Absent.")])))
        }
        q.append(("browser_action", choiceQ("Which ONE browser operation completely fulfills the request? Choose none for multiple steps, multiple tabs, a specific named or numbered tab, a website to open, or extra details not handled by the operation.",
            BrowserAction.allCases.map { ($0.rawValue, .string($0.description)) } + [(Candidates.none, "No single supported operation completes the request.")])))
        q.append(("control_browser", choiceQ("Which browser is explicitly named? Do not infer a browser. Generic browser or no app name means foreground. Any other named app is unsupported.",
            [("Google Chrome", "Chrome or Google Chrome."), ("Safari", "Safari."), ("foreground", "No specific browser or application named."), ("unsupported", "Another browser or application named.")].map { ($0.0, .string($0.1)) })))
        q.append(("audio_action", choiceQ("Which system output-volume operation is requested? Microphone mute and per-app volume are unsupported.",
            [("set", "Set an absolute output volume."), ("increase", "Increase output volume."), ("decrease", "Decrease output volume."), ("mute", "Mute system output."), ("unmute", "Unmute system output."), (Candidates.none, "No supported operation.")].map { ($0.0, .string($0.1)) })))
        q.append(("audio_amount", choiceQ("What integer percentage from 0 to 100 is explicitly requested, either as an absolute volume or the amount to increase/decrease? Choose default only if no amount is specified for a relative increase/decrease. Choose none if outside this range, fractional, unclear, or missing for an absolute setting. Never invent an amount.",
            (0...100).map { (String($0), JSON.null) } + [("default", "Relative volume change with no amount specified."), (Candidates.none, "No valid percentage.")])))
        q.append(("playback_action", choiceQ("Which playback control is requested?",
            [("pause", "Pause playback."), ("resume", "Resume existing playback."), ("next", "Next track."), ("previous", "Previous track."), (Candidates.none, "No supported control.")].map { ($0.0, .string($0.1)) })))
        q.append(("control_player", choiceQ("Which music player does the command explicitly name? Do not infer a player when none is named.",
            [("Spotify", "Spotify."), ("Music", "Apple Music or Music.app."), ("automatic", "No player or other application is named."), ("unsupported", "Another application or player is named.")].map { ($0.0, .string($0.1)) })))
        for (i, part) in cl.parts.enumerated() {
            q.append(("search_q_\(i)", spanChoice(
                obj(("part", .string(part)),
                    ("question", "The user's `command` was split into parts. Which span of `part` is the exact text to type into a search box? Leave out command words such as 'search for', 'look up', or 'google', and leave out where to search, such as 'on YouTube' or 'on Amazon'.")),
                Candidates.spans(Candidates.words(part)), "This part asks for no search, for example it only opens an app.")))
        }
        for (i, sep) in cl.separators.enumerated() {
            // `after` is the rest of the command, so "kyoto and salt" is judged knowing "pepper shakers" follows.
            let rest = ((i + 1)..<cl.parts.count).map { j in j < cl.separators.count ? "\(cl.parts[j]) \(cl.separators[j])" : cl.parts[j] }.joined(separator: " ")
            q.append(("search_split_\(i)", obj(
                ("type", "noul"),
                ("instructions", obj(("before", .string(cl.parts[i])), ("after", .string(rest)),
                                     ("question", .string("In `command`, the words `before` are followed by `after`. Are they two separate things the user wants done, rather than one phrase that happens to contain the word \"\(sep)\"?")))),
                ("criteria", obj(("true", "Two separate searches or actions."),
                                 ("false", "One phrase, like \"salt and pepper shakers\" or \"tom and jerry\"."))))))
        }
        return Prepared(transcript: transcript, command: command, state: obj(("command", .string(command))), questions: q,
                        clauses: cl, sites: Dictionary(siteOpts, uniquingKeysWith: { a, _ in a }), apps: appOpts,
                        siteList: siteOpts.map(\.1))
    }

    // MARK: interpretation

    static func choice(_ a: JSON?) -> Arg { Arg(a?.choice.map(ArgValue.text) ?? .none, a?.confidence ?? 0) }

    /// A span pick whose confidence counts spans that differ only by articles as the same answer.
    static func span(_ a: JSON?) -> Arg {
        let arg = choice(a)
        guard let v = arg.text, v != Candidates.none, let a else { return arg }
        let key = Candidates.core(v)
        let mass = a.probabilities.filter { $0.0 != Candidates.none && Candidates.core($0.0) == key }.reduce(0) { $0 + $1.1 }
        return Arg(arg.value, max(arg.confidence, mass))
    }

    static func yes(_ a: JSON?) -> Arg {
        let p = a?.noul ?? 0
        return Arg(.number(p), max(p, 1 - p))
    }

    static func present(_ a: JSON?) -> Double {
        1 - (a?.probabilities.first { $0.0 == Candidates.none }?.1 ?? 0)
    }

    static func overlaps(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        return a.contains(b) || b.contains(a)
    }

    public static func interpret(_ prep: Prepared, _ reply: JevReply) -> Plan {
        let a = reply.answers
        let intent = choice(a["intent"])
        var plan = Plan(transcript: prep.transcript, intent: intent.text ?? "none", intentConfidence: intent.confidence)
        plan.model = reply.model
        plan.jevMs = reply.latencyMs
        plan.inputTokens = reply.inputTokens
        plan.questionCount = prep.questions.count
        let app = choice(a["app"])
        if app.isSome { plan.args["app"] = app }

        var used: [Arg] = []
        switch plan.intent {
        case "calendar_control":
            let supported = choice(a["calendar_supported"])
            used.append(supported)
            if supported.text == "yes", let request = CalendarParsing.parse(prep.transcript) {
                switch request {
                case let .create(draft):
                    plan.args["operation"] = Arg(.text("create"), 1)
                    plan.args["title"] = Arg(.text(draft.title), 1)
                    if let schedule = draft.schedule { plan.args["schedule"] = Arg(.text(schedule), 1) }
                    if let duration = draft.duration { plan.args["duration"] = Arg(.text(duration), 1) }
                    if let calendar = draft.calendar { plan.args["calendar"] = Arg(.text(calendar), 1) }
                case let .agenda(day, calendar):
                    plan.args["operation"] = Arg(.text("agenda"), 1)
                    plan.args["day"] = Arg(.text(day), 1)
                    if let calendar { plan.args["calendar"] = Arg(.text(calendar), 1) }
                }
            } else { used.append(Arg(.none, 0)) }
            plan.action = "create a verified Calendar event or read a local day agenda"
        case "finder_control":
            let supported = choice(a["finder_supported"])
            used.append(supported)
            if supported.text == "yes", let request = FinderRequest.parse(prep.transcript) {
                plan.args["operation"] = Arg(.text(request.operation), 1)
                plan.args["target"] = Arg(.text(request.target), 1)
            } else { used.append(Arg(.none, 0)) }
            plan.action = "open a folder or reveal filename matches in Finder"
        case "create_reminder":
            let supported = choice(a["reminder_supported"])
            used.append(supported)
            if supported.text == "yes", let draft = ReminderParsing.draft(prep.transcript) {
                plan.args["title"] = Arg(.text(draft.title), 1)
                if let list = draft.list { plan.args["list"] = Arg(.text(list), 1) }
                if let schedule = draft.schedule { plan.args["schedule"] = Arg(.text(schedule), 1) }
            } else { used.append(Arg(.none, 0)) }
            plan.action = "create a reminder after resolving the date and list"
        case "create_note", "append_note":
            let appending = plan.intent == "append_note"
            let note = NoteText(prep.transcript)
            let supported = choice(a[appending ? "note_append_supported" : "note_supported"])
            used.append(supported)
            var spans: [(Int, Int)] = []
            let explicitAppend = appending ? note.explicitAppend : nil
            for field in ["title", "body"] {
                // A complete explicit append grammar supplies exact original-text
                // boundaries; noisy independent model endpoints cannot add "note,".
                if let explicitAppend {
                    let value = field == "title" ? explicitAppend.title : explicitAppend.body
                    let argument = Arg(.text(value), 1)
                    used.append(argument)
                    plan.args[field] = argument
                    continue
                }
                let start = choice(a["note_\(field)_start"]), end = choice(a["note_\(field)_end"])
                if start.text == Candidates.none && end.text == Candidates.none {
                    if appending { used.append(Arg(.none, 0)); continue }
                    used.append(Arg(.text("absent"), min(start.confidence, end.confidence)))
                    plan.args[field] = Arg(.text(field == "title" ? "Quick note" : ""), min(start.confidence, end.confidence))
                } else if let value = note.slice(start: start.text, end: end.text) {
                    let confidence = min(start.confidence, end.confidence)
                    used.append(Arg(.text(value), confidence))
                    plan.args[field] = Arg(.text(value), confidence)
                    spans.append((Int(start.text!)!, Int(end.text!)!))
                } else { used.append(Arg(.none, 0)) }
            }
            if !note.supported || supported.text != "yes" || (plan.arg("title")?.count ?? 0) > 200 ||
               (spans.count == 2 && max(spans[0].0, spans[1].0) < min(spans[0].1, spans[1].1)) { used.append(Arg(.none, 0)) }
            plan.action = appending ? "append text to the named Apple Notes note" : "create a note in Apple Notes' default folder"
        case "browser_control":
            let action = choice(a["browser_action"])
            let browser = choice(a["control_browser"])
            plan.args["operation"] = action
            plan.args["browser"] = browser
            used += [action, browser]
            if BrowserAction(rawValue: action.text ?? "") == nil || !["foreground", "Google Chrome", "Safari"].contains(browser.text ?? "") {
                used.append(Arg(.none, 0))
            }
            plan.action = "browser control: \(action.text ?? "unknown")"
        case "audio_control":
            let action = choice(a["audio_action"])
            let amount = choice(a["audio_amount"])
            plan.args["operation"] = action
            used.append(action)
            if action.text == "set" || action.text == "increase" || action.text == "decrease" {
                if let text = amount.text, let n = Int(text), (0...100).contains(n) {
                    plan.args["amount"] = Arg(.number(Double(n)), amount.confidence)
                    used.append(amount)
                } else if action.text == "set" {
                    used.append(Arg(.none, 0))
                } else if amount.text == "default" && amount.confidence >= fastArg {
                    plan.args["amount"] = Arg(.number(10), amount.confidence)
                    used.append(amount)
                } else { used.append(Arg(.none, 0)) }
            }
            plan.action = "change system output volume"
        case "playback_control":
            let action = choice(a["playback_action"])
            let player = choice(a["control_player"])
            plan.args["operation"] = action
            plan.args["player"] = player
            used += [action, player]
            if player.text == "unsupported" { used.append(Arg(.none, 0)) }
            plan.action = "control playback in \(player.text ?? "the active player")"
        case "play_music":
            let song = span(a["music_song"]), artist = span(a["music_artist"]), mood = span(a["music_mood"])
            let kind = choice(a["music_kind"])
            plan.args["kind"] = kind
            // Jev may put the same span in every role (a one-name request: song 0.99, artist 0.25, mood 0.33).
            let keepSong = song.isSome && present(a["music_song"]) >= 0.5
            let keepArtist = artist.isSome && present(a["music_artist"]) >= 0.5 && !(keepSong && overlaps(song.text!, artist.text!))
            let keepMood = !(keepSong || keepArtist) && mood.isSome && present(a["music_mood"]) >= 0.5
            for (name, arg, keep) in [("song", song, keepSong), ("artist", artist, keepArtist), ("mood", mood, keepMood)] where keep {
                plan.args[name] = arg
                used.append(arg)
            }
            let target = musicApps.contains(app.text ?? "") ? app.text! : "Spotify"
            var query = [(song, keepSong), (artist, keepArtist)].filter(\.1).map { $0.0.text! }.joined(separator: " ")
            if query.isEmpty, keepMood { query = mood.text! }
            plan.args["player"] = Arg(.text(target), musicApps.contains(app.text ?? "") ? app.confidence : 1.0)
            if !query.isEmpty {
                plan.args["query"] = Arg(.text(query), used.map(\.confidence).min() ?? 0)
                if target == "Spotify" {
                    plan.urls = ["spotify:search:\(URLQuote.quote(query))"]
                    plan.action = "play the top \(kind.text ?? "track") result for \"\(query)\" in Spotify"
                } else {
                    plan.action = "Music.app: play \"\(query)\""
                }
            } else {
                plan.action = "resume playback in \(target)"
            }

        case "open_site":
            let site = choice(a["site"]), sp = span(a["site_span"])
            if site.isSome, let s = prep.sites[site.text!] {
                plan.args["site"] = Arg(.text(s.url), site.confidence)
                plan.urls = [s.url]
                used.append(site)
            } else if sp.isSome {
                let v = Candidates.spokenDomain(sp.text!)
                let url = Candidates.isDomain(v) ? "https://\(v)" : "https://duckduckgo.com/?q=!ducky+\(URLQuote.quotePlus(v))"
                plan.args["site"] = Arg(.text(url), sp.confidence)
                plan.urls = [url]
                used.append(sp)
            } else {
                plan.args["site"] = Arg(.none, site.confidence)
                used.append(Arg(.none, 0))
            }
            plan.action = plan.urls.first.map { "open \($0)" } ?? "no site found"

        case "web_search":
            let engine = choice(a["search_engine"])
            plan.args["engine"] = engine
            let (queries, confs) = groupQueries(prep, a)
            let qa = Arg(.list(queries), confs.min() ?? 0)
            plan.args["queries"] = qa
            used.append(qa)
            if engine.confidence < fastArg && engine.text != "google" { used.append(engine) }
            let prefix = engines.first { $0.0 == engine.text }?.2 ?? engines[0].2
            plan.urls = queries.map { prefix + URLQuote.quotePlus($0) }
            plan.action = plan.urls.isEmpty ? "no queries found" : "open \(plan.urls.count) search tab(s)"
            if queries.isEmpty { used.append(Arg(.none, 0)) }

        case "open_app":
            if app.isSome {
                used.append(app)
                plan.action = "open \(app.text!)"
            } else {
                used.append(Arg(.none, 0))
                plan.action = "no app found"
            }

        case "app_task":
            if !app.isSome {
                // "remind me to…" names no app; use the one the task implies.
                let implied = choice(a["app_for_task"])
                if implied.isSome { plan.args["app"] = implied }
            }
            plan.action = "do \"\(prep.command)\" in \(plan.args["app"]?.text ?? "the frontmost app")"

        default:
            break
        }
        route(&plan, intent, used)
        // A leading negative instruction must not be reinterpreted as its opposite action.
        // Check the original command, never the literal payload inside a note or reminder.
        if CommandText.isNegated(prep.transcript) {
            plan.route = .clarify
            plan.reason = "request begins with negation"
            plan.action = "no action requested"
            plan.args = [:]
            plan.urls = []
        }
        return plan
    }

    /// Merge clause-level query spans across separators Jev judged to be part of one phrase.
    static func groupQueries(_ prep: Prepared, _ a: [String: JSON]) -> ([String], [Double]) {
        let parts = (0..<prep.clauses.parts.count).map { span(a["search_q_\($0)"]) }
        let splits = (0..<prep.clauses.separators.count).map { yes(a["search_split_\($0)"]) }
        var queries: [String] = [], confs: [Double] = []
        var current: [String] = [], curConf: [Double] = []
        for (i, part) in parts.enumerated() {
            if part.isSome {
                current.append(part.text!)
                curConf.append(part.confidence)
            }
            let joinsNext = i < splits.count && (splits[i].number ?? 1) < searchYes
            if i < splits.count { curConf.append(splits[i].confidence) }
            if joinsNext && part.isSome {
                current.append(prep.clauses.separators[i])
                continue
            }
            if !current.isEmpty {
                while let last = current.last, Candidates.separators.contains(last) || last == "," { current.removeLast() }
                queries.append(current.joined(separator: " "))
                confs.append(curConf.min() ?? 0)
            }
            current = []
            curConf = []
        }
        return (queries, confs)
    }

    static func route(_ plan: inout Plan, _ intent: Arg, _ used: [Arg]) {
        let argConf = used.map(\.confidence).min() ?? 1.0
        plan.argConfidence = argConf
        let missing = used.contains { !$0.isSome }
        let i = intent.confidence
        if plan.intent == "none" || i < clarifyBelow {
            plan.route = .clarify
            plan.reason = String(format: "intent %@ at %.2f", plan.intent, i)
        } else if plan.intent == "app_task" {
            plan.route = .computerUse
            plan.reason = "open-ended task inside an app"
        } else if plan.intent == "play_music" && plan.args["query"] != nil {
            // Opening a search is harmless even when unsure; the check afterwards catches a wrong pick.
            plan.route = .fastpathThenCheck
            plan.reason = i >= fastIntent && argConf >= fastArg ? "play via Spotify search" : String(format: "unsure (intent %.2f, args %.2f); the check will catch a wrong pick", i, argConf)
        } else if missing {
            plan.route = .computerUse
            plan.reason = "an argument could not be resolved"
        } else if i >= fastIntent && argConf >= fastArg {
            plan.route = .fastpath
            plan.reason = String(format: "intent %.2f, args %.2f", i, argConf)
        } else {
            plan.route = .computerUse
            plan.reason = String(format: "low confidence (intent %.2f, args %.2f)", i, argConf)
        }
    }

    public static func route(jev: Jev, transcript: String) async throws -> Plan {
        let t0 = Date()
        let prep = prepare(transcript)
        let reply = try await jev.ask(state: prep.state, questions: prep.questions)
        var plan = interpret(prep, reply)
        plan.latencyMs = Date().timeIntervalSince(t0) * 1000
        return plan
    }
}

public enum ArgValue: Equatable {
    case none
    case text(String)
    case list([String])
    case number(Double)
}

public struct Arg: Equatable {
    public var value: ArgValue
    public var confidence: Double

    public init(_ value: ArgValue, _ confidence: Double) {
        self.value = value
        self.confidence = confidence
    }

    public var text: String? { if case let .text(s) = value { return s }; return nil }
    public var list: [String]? { if case let .list(l) = value { return l }; return nil }
    public var number: Double? { if case let .number(n) = value { return n }; return nil }

    /// Present and not the "none" option (an empty list counts as missing).
    public var isSome: Bool {
        switch value {
        case .none: return false
        case let .text(s): return s != Candidates.none && !s.isEmpty
        case let .list(l): return !l.isEmpty
        case .number: return true
        }
    }

    public var json: JSON {
        switch value {
        case .none: return .null
        case let .text(s): return .string(s)
        case let .list(l): return .array(l.map { .string($0) })
        case let .number(n): return .number(n)
        }
    }
}

public enum Route: String {
    case fastpath
    case fastpathThenCheck = "fastpath+computer_use"
    case computerUse = "computer_use"
    case clarify
}

public struct Plan {
    public var transcript: String
    public var intent: String
    public var intentConfidence: Double
    public var args: [String: Arg] = [:]
    public var route: Route = .clarify
    public var argConfidence = 1.0
    public var reason = ""
    public var action = ""
    public var urls: [String] = []
    public var latencyMs = 0.0
    public var jevMs = 0.0
    public var inputTokens = 0
    public var questionCount = 0
    public var model = ""

    public init(transcript: String, intent: String, intentConfidence: Double) {
        self.transcript = transcript
        self.intent = intent
        self.intentConfidence = intentConfidence
    }

    public func arg(_ k: String) -> String? { args[k]?.text }

    public var json: JSON {
        func r(_ x: Double) -> JSON { .number((x * 1000).rounded() / 1000) }
        return obj(
            ("transcript", .string(transcript)),
            ("intent", .string(intent)),
            ("intent_confidence", r(intentConfidence)),
            ("args", .object(args.keys.sorted().map { k in (k, obj(("value", args[k]!.json), ("confidence", r(args[k]!.confidence)))) })),
            ("route", .string(route.rawValue)),
            ("arg_confidence", r(argConfidence)),
            ("reason", .string(reason)),
            ("action", .string(action)),
            ("urls", .array(urls.map { .string($0) })),
            ("latency_ms", .number(latencyMs.rounded())),
            ("jev_ms", .number(jevMs.rounded())),
            ("input_tokens", .number(Double(inputTokens))),
            ("questions", .number(Double(questionCount))),
            ("model", .string(model))
        )
    }
}
