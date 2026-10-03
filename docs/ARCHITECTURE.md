# Architecture

We built Varta around a single command pipeline: local speech recognition, structured decisions
from Jev, and bounded macOS actions. The app runs in one process without a local server, daemon
or Python runtime. Jev requests use the remote TypeSafe API.

```
  you hold ⌥Space
        │
        ▼
  ┌───────────────┐   mic → 16 kHz mono floats
  │ MicRecorder   │
  └───────┬───────┘
          │                       ┌──────────────────────────────┐
          ├──────────────────────► │ HoldTranscriber              │
          │   audio so far         │ runs Whisper at each pause   │
          │                        └──────────────┬───────────────┘
  you let go                                      │ transcript
        │                                         ▼
        │                        ┌────────────────────────────────┐
        │                        │ Candidates                     │
        │                        │ spans · apps · sites · clauses │
        │                        └────────────────┬───────────────┘
        │                                         ▼
        │                        ┌────────────────────────────────┐
        │                        │ Router.prepare → one Jev request│
        │                        │ Router.interpret → Plan         │
        │                        └────────────────┬───────────────┘
        │                                         ▼
        │                         ┌──────────────────────────────┐
        │                         │ Pipeline                     │
        │                         └──┬───────────┬───────────────┘
        │                            │           │
        │                 Executor ◄─┘           └─► AXTier
        │          open / AppleScript / URLs        one button or menu press
        │                            │           │
        │                            └─────┬─────┘
        │                                  ▼
        │                         ┌──────────────────┐
        └────────────────────────►│ Verifier         │ → the notch
                                  │ did it work?     │
                                  └──────────────────┘
```

## The pieces

All paths are under [`app/Sources/`](../app/Sources).

| File | Responsibility |
|---|---|
| `Varta/App.swift` | The lifecycle: hotkey, push-to-talk, menu bar, turning pipeline events into notch states |
| `Varta/NotchPanel.swift`, `NotchView.swift` | A borderless, click-through `NSPanel` pinned over the notch |
| `Varta/HotKey.swift` | Carbon global hotkeys (press *and* release, no Accessibility needed) and the recorder |
| `Varta/Speech.swift` | Wires the mic to `HoldTranscriber` |
| `VartaCore/LocalSpeech.swift` | Whisper via WhisperKit, the mic recorder, and `HoldTranscriber` |
| `VartaCore/Candidates.swift`, `Fuzzy.swift`, `Sources.swift` | What an answer could be: spans, clauses, app and site shortlists |
| `VartaCore/Router.swift` | Builds the Jev request; turns answers into a `Plan` and picks a route |
| `VartaCore/Jev.swift` | The TypeSafe client, one warm connection |
| `VartaCore/JSON.swift` | JSON that keeps key order, so Jev sees options in a stable order |
| `VartaCore/AudioControls.swift` | bounded volume changes, player selection, and playback state checks |
| `VartaCore/Executor.swift` | The fast path: `open`, URL schemes, AppleScript |
| `VartaCore/Accessibility.swift` | Reads allowed menu controls; Jev selects one; revalidates before pressing |
| `VartaCore/Verify.swift` | Reads what happened and asks Jev whether it matches |
| `VartaCore/Pipeline.swift` | Ties it together and emits events for the UI and the CLI |
| `VartaCore/ComputerUse.swift`, `MacHands.swift` | Experimental screenshot-based actions; disabled by `Features.computerUse`. |

## Speech

Whisper produces a transcript after each inference pass. We start transcription during pauses
while the user is still recording, reducing the work remaining after release. The amount of time
saved depends on the utterance, model and hardware; see [performance measurements](PERFORMANCE.md).

`HoldTranscriber` watches the audio while you hold the key. Each time you **pause** — 0.25 s of
silence after new speech — it starts a pass over everything recorded so far, as long as no pass is
already running. We allow only one pass at a time so speculative work does not queue behind an active pass.

When you let go, there are three cases:

1. A finished pass already covers all your speech → use it, with no wait at all.
2. A pass is running and covers all your speech → wait for it, usually a few hundred ms.
3. Neither → run one final pass over the whole recording.

The app's installed app names and known site names are fed to Whisper as a prompt, so it spells
them the way the router expects.

## The router

We separate candidate generation from model decisions so execution can use a typed, validated plan.

**Code generates candidates; Jev chooses among them.** Before any request, `Candidates` produces:

- every contiguous 1–8 word **span** of what you said (minus filler words), capped at 240,
- **apps** on this Mac, fuzzy-matched against those spans, plus common defaults,
- **sites** from a built-in list plus your Chrome bookmarks and top sites,
- **clauses**, split on "and", "then" and commas,
- **spoken domains** — "github dot com" → `github.com`.

**One routing request asks all prepared questions** (`Router.prepare`), including questions for
intents the user may not have selected. We batch them to avoid sequential routing round trips.
Request size, network conditions and service load still affect latency.

| Question | Type | Asks |
|---|---|---|
| `intent` | choice | play music, open a site, search, open an app, do a task in an app, or none |
| `app`, `app_for_task` | choice | which app you named; which app the task implies |
| `music_song`, `music_artist`, `music_mood` | choice over spans | which words are the title, the artist, the mood |
| `music_kind` | choice | track, album, artist, playlist or mood |
| `site`, `site_span` | choice | which known site; or which words name a site |
| `search_engine` | choice | Google, YouTube, Amazon, Maps, Wikipedia, GitHub, Reddit |
| `search_q_N` | choice over spans | the exact text to type, per clause |
| `search_split_N` | noul | does this "and" separate two requests, or is it one phrase? |

`Router.interpret` then reads **only** the answers belonging to the chosen intent, and ignores the
rest along with their uncertainty.

### Routing

Jev returns a probability with every answer. `Router.route` turns those into one of:

| Route | When | What happens |
|---|---|---|
| `fastpath` | intent ≥ 0.6 **and** every argument used ≥ 0.6 | act immediately |
| `fastpath+computer_use` | music with a query | act, then check (the name is historical) |
| `computer_use` | low confidence, an unresolved argument, or a multi-step app task | with computer use off: tell the user, don't guess |
| `clarify` | intent is `none`, or below 0.5 | "Didn't catch that" |

We evaluate the confidence thresholds against labelled commands; see [`eval/README.md`](../eval/README.md).

### Span interpretation

**Span confidence is summed by meaning.** Jev may split probability between "the weather in paris"
and "weather in paris". Those are the same search, so `Router.span` adds up every option with the
same core (articles stripped) before judging confidence.

**One phrase can't fill two roles.** For a one-word command, Jev may offer the same span as song,
artist *and* mood. A role only counts if its presence probability is over 0.5, and a span already
used as the title can't also be the artist.

## Action execution

We use direct application integrations first, then a restricted accessibility path. Experimental
screenshot-based actions remain disabled.

1. **`Executor`** — direct macOS integration. `open -a` for apps, one `open` call with every URL for
   tabs, and `play track "spotify:search:…"` for music. Nothing touches a shell: commands are
   argument lists, and AppleScript receives values through `on run argv`, so transcript values are not
   interpreted as shell or AppleScript source.

2. **`AXTier`** — the macOS accessibility tree, without screenshots. It collects the focused
   app's explicitly allowed menu commands (Notes new-note and Safari/Chrome zoom), then asks Jev two things in
   sequence: *which control does this?* and, only if that looks right, *does running this control
   finish the job by itself?* Both must clear their thresholds before anything is pressed. The exact app/menu allowlist and process/control revalidation gate every press.

3. **`ComputerAgent`** — screenshots and clicks driven by a vision model. **Off.** The code remains
   behind `Features.computerUse`; enabling it changes permissions, providers and data flows.

## Verification

`Verifier` reads evidence from the machine, not from the model: what Spotify reports it is playing,
which URLs Chrome's front window has open, which app is frontmost. Exact comparisons happen in code;
semantic checks send the command together with observed track/artist/album metadata, or a page
title and URL, to Jev for a yes/no judgement with a probability. Above 0.6 it's verified, below 0.4 it's a mismatch, and in between it says "maybe".

## Offline router tests

`eval/fixtures/router-replay.jsonl` holds Jev's recorded answers for 114 commands, together with
the apps and sites the questions were built from and the plan each should produce. Replaying it
exercises the whole router without network requests. Run it from `app/`:

```bash
swift run varta-cli interpret ../eval/fixtures/router-replay.jsonl
```

Because the fixture carries its own apps and sites, it gives the same result on any Mac, including
CI runners with a different set of installed applications.

## Data handling and limitations

Audio transcription runs locally. Routing sends the transcript plus the prepared questions,
including app candidates and shortlisted site names/URLs, to TypeSafe. The accessibility tier
sends app and control labels in up to two additional requests; verification can make another
request with observed metadata. One routing request does not mean one request for the entire
command. See [Security and privacy](../SECURITY.md).

Accessibility uses exact English menu paths in known app bundle IDs and revalidates the
foreground process and original menu element after model requests. Unsupported controls are
never candidates. A successful press is still reported as unverified: it is not proof that the
intended task completed.

We use one cancellation token across recording, transcription, routing and execution. Esc or a new
command invalidates old work; results and UI callbacks from that work are discarded. Routing
and accessibility awaits check cancellation before proceeding, and each new subprocess or
accessibility press checks again before dispatch. Already dispatched macOS actions cannot be
rolled back. Offline cancellation regressions live in `varta-selftest`.

Verification currently inspects Chrome's front window even if another browser handled the
request. An unavailable verifier can still lead to an execution-success headline; it does not
mean a semantic check passed. See [installation and troubleshooting](INSTALLATION.md) and
[performance methodology](PERFORMANCE.md).

## Audio controls

We route system output volume and playback controls through explicit `audio_control` and
`playback_control` intents. The executor validates operations, player names, and whole
percentage values before dispatch. Relative volume defaults to 10 percentage points when
no amount is specified; invalid amounts cannot use that default.

Audio scripts read back output volume or mute state. Pause and resume check the selected
player's state with a bounded wait. Track navigation reports dispatch only. These actions
return their own result directly, without the general verifier's settling delay or an
additional model request.

Player selection honors an explicit Spotify or Apple Music name. Otherwise we query the
installed players without launching them, choose a unique playing player, or choose the
only running player when neither is playing. Ambiguity asks the user to repeat the command
with a player name. Cancellation is checked before each observation and action subprocess.

## Browser controls

We route ten single browser operations through `browser_control`. Jev selects an enumerated
operation and an explicit Chrome/Safari target or the foreground browser. Multi-action
requests, named tabs, window commands, and unsupported browsers cannot use this executor.

The pipeline captures the foreground browser before routing. The controller checks the
bundle ID, process ID, launch date, and foreground identity before dispatch. Explicit
browser names may activate an already running browser; unnamed controls cannot switch
applications. The native driver selects one exact allowlisted menu leaf and uses AXTier's
identity and enabled-state revalidation before pressing. Cancellation is checked around
activation and before pressing. Modal windows and attached sheets are left untouched.

The additional browser menu operations are exposed only to the explicit browser controller;
the open-ended app-task selector retains its original Notes and zoom scope.

The browser executor reports menu dispatch, without a second model request or a claim that
page navigation completed. Menu labels must match the supported English paths. Missing,
disabled, duplicated, or changed menu items fail rather than falling back to keystrokes or
a broader window operation.

## Notes creation

The `create_note` intent selects title and body boundaries from the original transcript.
We preserve the text between those boundaries rather than reusing the short, cleaned spans
for search and music. Requests over 200 whitespace-delimited words or 16,000 UTF-8 bytes,
invalid or overlapping boundaries, and titles over 200 characters cannot run automatically.
Absent titles use Quick note; absent bodies are empty. Unsupported destinations, formatting,
and existing-note edits cannot use this action.

We escape text into a heading and body, then pass it as an AppleScript argument to Notes.
The script creates one note in the default folder of the default account and returns its ID.
A separate request reads that note's plaintext; comparison normalizes whitespace but preserves
words and punctuation. We do not read other notes or automatically retry failed creation.
Cancellation prevents subsequent dispatches but cannot remove a note already created.
