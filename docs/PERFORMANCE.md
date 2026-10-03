# Performance

We built Varta around a short path from speech to action: transcribe locally, select a
structured plan in one Jev routing request, and execute supported actions directly.
We measure transcription, routing, and visible completion separately so the results describe
what users actually experience.

## Routing benchmark

On an Apple M4 Pro with 24 GB RAM, macOS 26.5.1, Swift 6.3.2, and Jev `jev-1.13.0`, our
release build completed 15 live requests on 2026-10-03. We repeated five fixed commands three
times. All requests produced the expected intent, arguments, and execution or clarification
route, with no request failures.

| Measurement | Samples | Median | p95 |
|---|---:|---:|---:|
| Total routing | 15 | 360 ms | 674 ms |
| Total routing after the first request | 14 | 356 ms | 433 ms |
| Successful Jev HTTP attempt | 15 | 357 ms | 662 ms |

The first total routing request took 674 ms. Total routing includes candidate preparation,
authentication, the request and any retries, and interpretation. We reused one client across
the run; we did not measure the provider's cold or warm state. Network conditions were not
controlled, and a dependency download ran in the background.

We include [raw samples and the tested source fingerprint](../eval/benchmarks/2026-10-03-routing.json).
This small workload demonstrates sub-second routing on that setup. It does not measure the
complete voice-to-action pipeline or establish a comparison with other applications.

## Speech benchmark

On the same Mac, we tested the default `openai_whisper-large-v3-v20240930_turbo` model with
15 synthetic audio samples: five phrases repeated three times. With the model prepared,
transcription took **1,197 ms median** and **1,275 ms p95** from simulated key release to the
final transcript. Every sample reused an in-flight transcription pass.

We generated clips with macOS `say -v Samantha -r 175`. The simulator released the key
0.4 seconds after each clip ended. Transcripts matched the intended content in all 15 samples
when ignoring case and whitespace, including “Nevermind” versus “never mind.” These clips
exercise transcription timing; they do not represent microphone conditions or human-speech
accuracy across accents, languages, and noise levels.

The reported run used a prepared model, with Varta open and no source build running. Initial
model download and Core ML preparation are excluded. See
[raw speech results and audio fingerprints](../eval/benchmarks/2026-10-03-speech.json).

## Measurement boundaries

We distinguish four timings:

1. **Key release to transcript.** Varta can reuse a completed transcription pass, wait for an
   in-flight pass, or run a final pass. Pauses before release affect the remaining work.
2. **Transcript to plan.** Candidate preparation, Jev routing, and interpretation. Plan JSON
   exposes total `latency_ms` and successful-attempt `jev_ms` separately.
3. **Key release to observable action.** Includes transcription, routing, and app work. Check
   when the requested window appears, page opens, or playback starts.
4. **Key release to final status.** Includes any verification. The verifier normally waits one
   second for the app to settle; semantic matches may require another Jev request.

One routing request does not mean one request for every command. Menu selection uses additional
requests, as can music and page verification. The client retries certain failures up to three
times, adding attempts and backoff. Successful-attempt timing excludes earlier retries.

Do not add medians from independent stage tests and present the sum as measured end-to-end
latency. Measure the complete command directly when reporting voice-to-action performance.

## Reproduce routing measurements

From `app/`:

```bash
swift build -c release --product varta-cli

# Check benchmark arguments and output without an API request
.build/release/varta-cli benchmark --dry-run

# Five commands repeated three times; requires a Jev key
.build/release/varta-cli benchmark --repetitions 3 > routing-benchmark.json
```

The workload is `open Notes`, `open Calculator`, `open GitHub`, `search for lunar eclipses`,
and `hello there`. We supply fixed public app/site candidates rather than reading your app
inventory or bookmarks. The first four must produce the labelled plan and `fastpath` route;
the non-command must return `clarify`. The benchmark executes no desktop actions.

Repetitions can range from 1 to 100. Each logical request incurs provider usage; retries can
add HTTP attempts. Progress goes to stderr, and JSON goes to stdout. The report includes raw
samples, first/subsequent-request summaries, error counts, incorrect plans, and nearest-rank
p50/p95 distributions. Fifteen samples give a preliminary estimate, especially for p95.

Exit status is 0 when all plans match, 1 for request failures or incorrect plans, and 2 for
invalid arguments. We report failures as `request_failed` to exclude provider response bodies
from saved reports. Successful-request distributions include incorrect plans; correctness is
reported separately.

## Reproduce speech measurements

Use existing audio files:

```bash
.build/release/varta-cli transcribe /path/to/command.wav
.build/release/varta-cli hold 0.4 /path/to/command.wav
```

`transcribe` measures a pass over a file. `hold` replays audio in real time and measures work
remaining after simulated release. Its numeric argument is the delay after the audio ends,
not the recording duration. Report it alongside every result. Neither command records the
microphone. A missing model is downloaded and prepared before transcription.

For live commands, `varta-cli run "open Notes"` executes the pipeline. The app logs transcript
and pipeline timestamps in `~/.varta/app.log`; observe visible completion independently and
redact private context before sharing excerpts.

## Report a performance result

Include hardware, macOS and Swift versions, source revision or fingerprint, build configuration,
model, compute settings, sample count, release delay, preparation state, and network conditions.
Report failures and correctness alongside latency, and retain sanitized raw samples.

For comparisons, use equivalent commands and outcome criteria across products, including
multiple-request paths. Measure transcription, routing, observable completion, and confirmation
consistently. We have not published a comparative speed ranking.

See [Testing](TESTING.md), [Evaluation](../eval/README.md), and
[Installation](INSTALLATION.md) for related instructions.
