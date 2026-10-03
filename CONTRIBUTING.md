# Contributing to Varta

We welcome improvements to commands, speech recognition, reliability, and documentation.
Varta is deliberately small: a Swift app, a shared engine, and CLI tools for inspecting and
testing the same pipeline.

- Report bugs and suggest features in [Issues](https://github.com/usekopai/varta/issues).
- Ask questions in [Discussions](https://github.com/usekopai/varta/discussions).
- Report vulnerabilities privately using [SECURITY.md](SECURITY.md).

We licence Varta under MIT. Contributions are distributed under the same [licence](LICENSE).
Please follow our [Code of Conduct](CODE_OF_CONDUCT.md).

## Set up the project

You'll need Apple silicon, macOS 15+, Swift 6.0+, and the macOS 15+ SDK. Compatible Xcode
Command Line Tools are sufficient; see [Installation](docs/INSTALLATION.md).

```bash
git clone https://github.com/usekopai/varta.git
cd varta/app
swift build
swift run varta-selftest
```

Most development needs no API key. Live routing, live evaluation, and command execution use
Jev and incur usage under your TypeSafe account. To run the app, use `./run.sh` from the
repository root and add your key in Setup. For CLI development, see
[credential configuration](docs/INSTALLATION.md#keys-and-settings).

## Development workflow

From `app/`:

```bash
# Offline checks and inspection
swift run varta-selftest
swift run varta-cli interpret ../eval/fixtures/router-replay.jsonl
swift run varta-cli eval ../eval/all-commands.csv ../eval/fixtures/router-replay.jsonl
swift run varta-cli questions "play hello by adele"

# Live routing: requires a Jev key, executes no action
swift run varta-cli route "play hello by adele"

# Execute a command on your Mac
swift run varta-cli run "open notes"

# Transcribe an existing audio file; no Jev key required
swift run -c release varta-cli transcribe clip.wav
swift run -c release varta-cli hold 0.4 clip.wav
```

After a debug build, run the evaluation gate from the repository root:

```bash
python3 .github/scripts/check-eval.py
```

We use this gate in CI to enforce fixture coverage, approved candidate data, and accuracy
thresholds. The CLI `eval` command alone prints a report; it does not enforce those thresholds.
Read [Testing](docs/TESTING.md) for checks appropriate to your change, and
[Performance](docs/PERFORMANCE.md) for reporting latency.

## Design principles

We generate candidates in code and ask Jev to select among them. The model returns structured
decisions; it does not generate executable code. Keep actions explicit, inputs bounded, and
outcomes observable where possible.

The pipeline is:

`Candidates` → `Router.prepare` → Jev → `Router.interpret` → `Executor` or `AXTier` → `Verifier`.

Read [Architecture](docs/ARCHITECTURE.md) for the data flow and component responsibilities.

## Good first contributions

### Add a website

Add the public home-page URL and spoken name to `MacSources.builtinSites` in
[`Sources.swift`](app/Sources/VartaCore/Sources.swift):

```swift
("https://news.ycombinator.com", "Hacker News"),
```

Add representative commands to `eval/commands.csv` and cover them in the replay fixture.
Keep test candidates public or synthetic.

### Add an app alias

Use `MacSources.appAliases` in the same file for spoken names that differ from an app's name:

```swift
"Visual Studio Code": ["vs code", "vscode", "code editor"],
```

Include cases that could be confused with another app or website.

### Add a search engine

`Router.engines` in [`Router.swift`](app/Sources/VartaCore/Router.swift) contains a key, a
description Jev reads, and a URL prefix:

```swift
("reddit", "Search on Reddit.", "https://www.reddit.com/search/?q="),
```

Describe the intent clearly and add labelled examples, including ambiguous requests.

### Improve the dataset

We value realistic phrasing, fillers, unusual names, transcription errors, and non-commands.
Record the words actually spoken or transcribed, then label the intended behavior. See
[Evaluation](eval/README.md) for the schema and fixture requirements.

## Add an action

Discuss larger actions in an issue before implementation so we can agree on behavior and scope.
A new direct action usually needs:

1. An intent description in `Router.intents`.
2. Candidate generation and any new questions in `Router.prepare`.
3. Argument interpretation and confidence handling in `Router.interpret`.
4. A branch in `Executor.execute` and a helper for the operation.
5. A result check in `Verify.swift` when an outcome can be observed.
6. Labelled commands, confusing alternatives, and cancellation tests.

For accessibility actions, extend `AXTier.isAllowed` deliberately with an app-specific menu
path and tests. We do not expose arbitrary buttons or menu items to automatic selection.

## Update a replay fixture

The fixture records model answers and expected plans. It detects changes to interpretation;
it does not establish how the live model responds to revised question wording.

If an unexpected replay failure appears, investigate the behavior before updating expectations.
For an intentional change, record responses from a clean test profile:

```bash
cd app
swift run -c release varta-cli record ../eval/all-commands.csv ../eval/fixtures/router-replay.jsonl
```

Recording requires a key and can include local app/site candidates. Review the resulting data,
conform it to the public fixture policy in [Evaluation](eval/README.md), and run the gate.
Explain changed plans in your PR. Test question changes against the live service too.

## Submit a pull request

We prefer focused changes with a clear problem, resulting behavior, and validation results.
Match the surrounding code and explain non-obvious decisions. Discuss new dependencies before
adding them.

Keep these boundaries intact:

- Pass subprocess arguments as arrays and AppleScript inputs through `on run argv`.
- Check cancellation before dispatch and after asynchronous work.
- Keep accessibility actions within the reviewed per-app allowlist.
- Update privacy documentation when changing outbound context.
- Exclude credentials, private candidate lists, recordings, screenshots, and logs from commits.

For UI and integration changes, describe the Mac, OS, permissions, and real commands tested.
For performance changes, include the workload, measurement boundary, and raw timing evidence.
We use [Testing](docs/TESTING.md) to review coverage and [Releasing](docs/RELEASING.md) to prepare
source distributions.
