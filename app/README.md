# Varta app and command-line tools

**Hold ⌥Space and speak, then release to send.** A quick tap toggles instead: tap, speak, tap again. Esc cancels pending work; an action already dispatched to macOS cannot be undone. See [Security](../SECURITY.md).

We run speech transcription locally and use Jev for routing and selected verification checks.
Requires Apple silicon, macOS 15+, Swift 6.0+ with a macOS 15 SDK, and a Jev API key for live
commands. See [Installation](../docs/INSTALLATION.md) for setup and troubleshooting.

Run the following commands from `app/`. `run` takes real actions; `route` calls Jev but does
not execute the returned plan. `interpret` and the fixture-backed `eval` work without API
credentials after dependencies are installed.

The app manages the command pipeline. The notch panel grows to show:

- the live transcript,
- what Jev understood, as chips,
- each step,
- the action result and, when available, verification—for example, "Playing Blinding Lights — The Weeknd".

```bash
../run.sh                                       # build, sign, install, open; then menu bar icon → Setup…
swift run varta-cli run "go to hacker news"    # the same pipeline from a terminal
swift run varta-cli route "play hello by adele"
swift run varta-selftest
swift run varta-cli interpret ../eval/fixtures/router-replay.jsonl   # 114 commands, no key
swift run varta-cli eval ../eval/all-commands.csv ../eval/fixtures/router-replay.jsonl
swift run -c release varta-cli transcribe clip.wav          # local Whisper, with timings
swift run -c release varta-cli hold 0.4 clip.wav            # simulate holding ⌥Space, time from release
```

`run.sh` signs with a local self-signed identity, to help keep permission identity stable across rebuilds. A plain `swift build` is fine for the CLI and the self-test.

## Targets

| Target | Responsibility |
|---|---|
| `VartaCore` | the engine; no UI |
| `Varta` | the notch app: panel, hotkeys, speech, Setup window, menu bar item |
| `varta-cli` | `questions` (print the Jev request) · `route` (plan it) · `run` (plan and do it) · `interpret` (replay the fixture, no key) · `record` (re-record the fixture using live requests) · `eval` (score labels) · `transcribe` · `hold` · `benchmark` |
| `varta-selftest` | Standalone regression tests that run with the Command Line Tools. |

## VartaCore

| File | Role |
|---|---|
| `Router.swift` | one Jev routing request → typed plan; later stages can add requests; intent and argument thresholds evaluated against labelled commands |
| `Candidates.swift`, `Fuzzy.swift`, `Sources.swift` | spans, clauses, app and site shortlists (rapidfuzz ports), installed apps, Chrome bookmarks and top sites |
| `JSON.swift` | ordered JSON, so Jev sees options in a stable order |
| `BrowserControls.swift` | Chrome/Safari menu operations, foreground capture, target validation, and cancellation |
| `FinderControls.swift` | common folders, local filename search, unique reveals, and saved-document context |
| `ReminderParsing.swift`, `Reminders.swift` | local date parsing, pending clarification, EventKit creation and readback |
| `Notes.swift` | original-transcript extraction, creation, unique-title append, and content readback |
| `AudioControls.swift` | system volume and Spotify/Apple Music playback controls, with state checks |
| `Executor.swift` | tier 1: `open`, AppleScript via argv (never a shell), Spotify direct play |
| `Accessibility.swift` | tier 2: exact Notes and Chrome/Safari menu allowlist; process/menu identity and cancellation are rechecked before pressing. |
| `ComputerUse.swift`, `MacHands.swift` | Experimental vision-based actions, **switched off** by `Features.computerUse = false`; enabling them changes permissions, providers and data flows |
| `Verify.swift` | checks what happened (now playing, Chrome tabs, front app); Jev judges the match |
| `Pipeline.swift` | route → fast path or accessibility → check, as events for the UI and CLI |
| `LocalSpeech.swift` | local Whisper (WhisperKit, Core ML on the Neural Engine) plus the mic recorder. `HoldTranscriber` runs a pass at each pause while ⌥Space is held, to reduce transcription work remaining when you let go. |
| `Credentials.swift` | keys, looked up in this order: environment, Keychain, `~/.varta/dev.env` |

## Settings

- **Whisper model:** `VARTA_WHISPER_MODEL`. The default is `openai_whisper-large-v3-v20240930_turbo` (approximately 1.5 GB). `openai_whisper-base.en` (approximately 143 MB) is a smaller alternative; compare speed and recognition quality for your commands before switching. Models download once to `~/.varta/models`.
- **Whisper language:** `VARTA_WHISPER_LANGUAGE` (default `en`).
- **Hotkey:** Setup → Hotkey → Change…, then press the new shortcut. It needs ⌃, ⌥ or ⌘ with a key, or a function key. Holding works (push-to-talk), and so does tap, speak, tap.
- **Logs:** `~/.varta/app.log`; build output goes to `~/.varta/build.log`

## Network and local data

We send the transcript and prepared app/site candidates, including shortlisted website URLs, to Jev for routing. Accessibility
selection sends control labels; verification can send playback metadata or page titles/URLs.
The audio stays local in the enabled pipeline. Logs can contain command and result data.
See [Privacy](../README.md#privacy) and [Security](../SECURITY.md).

Environment settings apply to the process that launches Varta. Running an app from Finder
does not generally inherit exports from an existing terminal. See the installation guide for
launching with model overrides. For benchmarks, use release builds and distinguish model
request time from transcription, execution, and verification; see
[Performance](../docs/PERFORMANCE.md).
