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
| Say “make a new note” | Notes opens and a new note is created through the supported accessibility action |
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
