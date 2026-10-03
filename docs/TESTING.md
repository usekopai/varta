# Testing Varta

We use offline regression tests, live routing checks, and hands-on macOS tests to verify
Varta. Each covers a different part of the voice-to-action pipeline. This guide explains
how to reproduce those checks and report results contributors can use.

See [installation](INSTALLATION.md) for prerequisites, permissions, and local signing.
See [performance](PERFORMANCE.md) for timing boundaries and published measurements.

## Build and offline regression tests

Run from the repository root:

```bash
swift build --package-path app
swift run --package-path app varta-selftest
python3 .github/scripts/check-eval.py
swift build --package-path app -c release
zsh -n run.sh
```

The self-tests cover core behavior, including cancellation and the accessibility policy.
The evaluation gate verifies fixture coverage, public candidate data, replay agreement,
and minimum whole-plan accuracy and automatic-execution coverage. These checks need no
API key or live API requests once dependencies have been fetched.

We currently maintain a 114-command recorded fixture. Its baseline is 114/114 replay
matches, 112/114 correct whole plans, and 85/85 correct plans selected for automatic
execution. These are regression results against historical responses, not a guarantee
for new commands. See [the evaluation guide](../eval/README.md) for methodology and limits.

For a clean source-build test, use a separate copy of the source without an `app/.build`
directory. Record the toolchain, operating system, hardware, dependency-cache state,
network conditions, and elapsed time. A clean build on an existing account does not test
first-time permissions or an empty speech-model cache.

## Installation and permissions

Use a separate macOS account or test Mac when checking first-time setup. Follow
[the installation guide](INSTALLATION.md), then exercise these cases:

1. Install with `./run.sh --no-open` and verify the installed bundle:
   `codesign --verify --strict "$HOME/Applications/Varta.app"`.
2. Launch Varta, configure the Jev key, and wait for model readiness. Check model
   download and preparation on an account with no existing speech-model cache.
3. Grant the requested permissions and record a short command. Check the first-time
   prompts against the setup instructions.
4. Deny each requested permission in turn. Confirm setup explains how to recover,
   grant it in System Settings, and relaunch where required.
5. Reinstall with the same signing identity and verify existing permissions and
   settings still work. Inspect any signing or permission warnings.
6. Follow the documented uninstall steps, then confirm the app and any local data
   selected for removal are gone.

Check keychain search-list preservation when testing installer changes. Use mocked
commands or a disposable account for signing failure scenarios; preserve working
identities and avoid altering your login keychain to simulate failures.

## Hands-on command tests

Use public or synthetic commands and documents. These tests perform actions on the Mac;
close any test documents afterwards without saving them if they are no longer needed.

| Case | What to check |
|---|---|
| Hold the configured shortcut, say “open Notes,” and release | Capture starts and stops correctly; the transcript appears; Notes opens |
| Say “make a new note” | Notes opens and a Quick note is created through the Notes integration |
| Request zoom in and zoom out in Safari or Google Chrome | The supported menu action changes page zoom in the intended browser |
| Say a non-command such as “hello there” | Varta asks for clarification rather than taking an action |
| Request an unsupported in-app action | Varta explains the limitation without pressing an unrelated control |
| Press Esc during recording, transcription, and routing | Pending work stops without later dispatching an action |
| Start a second command while the first is transcribing or routing | The first command cannot resume and dispatch an action after replacement |
| Route with unavailable network or an invalid test key | Failure is reported clearly and the app remains usable for another command |

Cancellation cannot undo an action macOS has already received. Exercise cancellation
before dispatch as well as near dispatch, and record the timing of any unexpected
result. A pipeline status or process exit alone does not establish that a window appeared,
a page loaded, or music became audible; observe the requested outcome directly.

## Live routing and speech checks

Build the release CLI first:

```bash
swift build --package-path app -c release --product varta-cli
app/.build/release/varta-cli benchmark --dry-run
app/.build/release/varta-cli benchmark --repetitions 3 > routing-benchmark.json
app/.build/release/varta-cli transcribe /path/to/command.wav
app/.build/release/varta-cli hold 0.4 /path/to/command.wav
```

The live benchmark requires a configured `TYPESAFE_API_KEY` and incurs API usage.
It uses fixed public candidates and does not execute plans. Speech commands consume
existing audio rather than recording the microphone. The `hold` argument is the delay
between the end of the audio and simulated key release; include it in timing reports.

Review correctness and failed requests alongside timing. Use the
[performance guide](PERFORMANCE.md) before making speed claims, and the
[evaluation guide](../eval/README.md) before changing recorded router expectations.

## Reporting results

For a bug report or pull request, include the Varta version or source revision, macOS
and Swift versions, hardware, selected speech model, relevant permissions, reproduction
steps, expected result, and observed result. State whether the result came from replay,
a live model request, synthetic audio, or a microphone command.

For performance changes, include sample count, raw sanitized timings, correctness,
network conditions, model preparation state, and the exact start/end boundary being
measured. Keep API keys, private commands, personal app/browser inventories, and live
user logs out of reports. Review `~/.varta/app.log` before sharing excerpts.

## Audio controls

The self-check executable covers bounded numeric arguments, explicit and automatic player
selection, ambiguous players, rejected operations, subprocess errors, and cancellation
between observation and dispatch. These tests inject subprocess responses and do not
change audio or launch music players.

For a live check, use a controllable audio output and test volume, mute, pause, resume, and
track navigation. Test Spotify and Apple Music separately, then with both running. Verify
that ambiguous commands request a player name and that denying Automation permission
produces an error. Check the final state in the system sound controls or player. Restore
your volume and playback settings afterward.

Use `varta-cli route "pause Spotify"` to check live Jev routing without executing it. The
historical 114-command fixture predates these new intents and is a regression replay,
not evidence of current live accuracy for audio controls.

## Browser controls

Offline checks use an injected browser driver to cover all ten operations in both browsers,
explicit targeting, absent targets, focus changes during routing, restarted processes,
cancellation during activation, unavailable menu commands, and unsupported requests. They
also assert that window and bulk-tab commands are excluded from the menu allowlist.

For a live check, give Varta Accessibility access and create disposable tabs in Chrome and
Safari. Test next/previous, new/close/reopen, back/forward/reload, and zoom. Name each browser
while the other is foreground, then test an unnamed command with a different app in front.
Switch focus while a command is routing and check that no menu action runs. Use disposable
content when checking Close Tab with an unsaved-work prompt; Varta must leave the prompt
for you. Menu dispatch feedback alone is not evidence that navigation finished.

## Notes creation

Self-checks cover original-text boundaries, punctuation, oversized requests, HTML escaping,
separate title/body fields, default titles, readback mismatches, subprocess failures, and
cancellation after creation. Injected subprocess responses keep these tests out of real notes.

For a live check, create a disposable titled note with content, then a title-only note and an
untitled dictation. Confirm the destination matches Notes' default account and folder. Test
quotes, ampersands, and content phrased as an instruction; it should appear as text. Denied
Automation access must report failure. On any uncertain result, inspect Notes before repeating
the command. Delete only the test notes you created when finished.

## Appending to notes

Self-checks cover exact title/body extraction, missing or duplicate matches, unsupported
markup, changed snapshots, full-content verification, cancellation after lookup, and
uncertain writes without retries. A real subprocess regression emits more than pipe capacity
on both stdout and stderr to exercise large readback handling.

For a live test, create a disposable simple note with a unique title, then say “in the
[title] note, add an item called Agentic Harness Evaluator.” Check that the original text
remains and the new line appears once. Repeat with duplicate titles and a note containing
an attachment or checklist; neither should be edited. Make manual edits while a command is
routing to test the changed-content guard. Do not repeat an uncertain append until you have
checked the note for an already completed addition.


## Reminders

Offline tests use an injected store and clock. They cover spoken and numeric times, local
calendar dates, daylight-saving gaps and repeated hours, past/invalid dates, follow-up context
and expiry, denied access, cancellation during permission requests, list selection failures,
and uncertain saves without retries. Pipeline tests confirm a temporal follow-up bypasses
routing and creates the task once. These tests do not establish real EventKit behavior.

In the installed app, use disposable tasks to check:

1. “Remind me in twenty minutes to check the test build.” Grant Reminders access on first use;
   confirm one task in the default list with the expected due time and alarm.
2. “Add Varta test milk to my reminders.” Confirm no due date or alarm.
3. “Remind me tomorrow to check Varta in my Shopping list,” using a list you already have.
   Confirm the named destination and an all-day due date. Try a nonexistent list; nothing saves.
4. “Remind me tomorrow at six to review the Varta test.” Confirm nothing saves yet; use the
   shortcut again and say “six PM.” Confirm one task tomorrow at 18:00 with the original title.
5. Repeat the ambiguous request, press Esc, then say “six PM.” Confirm no task is created.
   Repeat with a wait longer than 90 seconds and with an unrelated command in between.
6. Deny access in System Settings → Privacy & Security → Reminders; confirm a clear recovery
   message. Re-enable access and retry. Check Reminders before retrying any uncertain save.

Inspect results in Reminders and delete only the disposable tasks you created. Notification
appearance is a separate check subject to macOS notification and Focus settings.


## Finder

Offline tests use disposable files, a stub Spotlight runner and an injected Finder driver.
They cover folder allowlists, Music app ambiguity, filename extraction and predicate escaping,
missing and duplicate targets, actual filename and home-boundary validation, cancellation,
search failures, and capturing the current document before routing completes.

In the installed app, test “open Downloads” and “open my Documents folder.” Create an indexed
disposable file with a unique name, then say “find files named” followed by part of that name,
and “show” followed by its complete filename and “in Finder.” Confirm Finder selects the file
without opening its contents. With two copies of the same filename, exact reveal must decline.
Search can open multiple Finder windows and displays at most ten matching files.

Open a saved disposable document in TextEdit or Preview, then say “show this file in Finder.”
Confirm it selects that document. Repeat with an unsaved document or a browser page; Varta
should ask for a filename if the app exposes no existing local document URL. Also check an
unmatched name and cancellation during a search. Spotlight exclusions and indexing delays
can legitimately produce no results; do not interpret an empty result as proof a file is absent.
