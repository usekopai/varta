# Router evaluation

We maintain labelled commands and recorded Jev responses to test how Varta interprets
voice requests. We evaluate the complete plan, including its arguments, as well as intent
classification.

| File | What |
|---|---|
| `commands.csv` | 84 commands: music (non-English titles, misheard names), sites, multi-searches ("salt and pepper"), apps, in-app tasks, non-requests |
| `holdout.csv` | 30 commands originally reserved for evaluation; now part of the regression suite |
| `all-commands.csv` | both of the above, concatenated — what the fixture is recorded from |
| `fixtures/router-replay.jsonl` | Sanitized historical Jev answers for all 114 commands, plus the plan each should produce |
| `jevbench/` | a [jevbench](https://github.com/swapnanilray/jevbench) suite for the fixed-option questions (intent, music kind, search engine) |
| `results/` | Local evaluation output, excluded from version control |

In `queries` cells, `|` separates searches and `;` lists acceptable wordings of one search.

## Running it

Both commands need **no API key**. They score against the recorded fixture. Run these
commands from `eval/`:

```bash
cd ../app

# Did the router change? Replays the recorded answers and compares plans.
swift run varta-cli interpret ../eval/fixtures/router-replay.jsonl

# Is it right? Scores finished plans against the labels and sweeps the thresholds.
swift run varta-cli eval ../eval/all-commands.csv ../eval/fixtures/router-replay.jsonl
```

Drop the fixture argument from `eval` to ask Jev live instead, which needs a key and one logical routing request
per command; retries can add HTTP attempts.

### Re-recording the fixture

We update recorded expectations when an intentional behavior change requires it. Recording
needs a TypeSafe key and incurs API usage charges; retries may add requests. Use a clean
test profile and review candidate data before sharing a fixture.

```bash
swift run -c release varta-cli record ../eval/all-commands.csv ../eval/fixtures/router-replay.jsonl
```

Each line carries the command, explicit app and site candidates, Jev's pruned answers, and the
expected plan. The checked-in fixture uses a curated app inventory and sanitized site candidates
as described below. Replay uses these explicit candidates instead of scanning the runner's
installed apps and browser profile. It does not make live Jev requests.

## Results

`eval` judges the finished plan: the right intent **and** the right song, site, queries or app.

**Recorded baseline** (answers recorded 2026-10-01, `jev-1.13.0`; public candidate inventory updated 2026-10-03):

| | Intent | Whole plan |
|---|---|---|
| All 114 commands | 113/114 | **112/114** |
| At the default thresholds (0.6 / 0.6) | — | **85/85 plans selected for automatic execution** (95% CI 96–100%) |

The two whole-plan mismatches illustrate current limitations:

- **"turn the volume down"** — we do not yet support a system-volume action.
- **"look up the typesafe jev docs"** — the recorded response is split between searching and
  opening a site. Varta asks for clarification; the labels expect a search, so the evaluator
  counts that result as a mismatch.

The initial whole-plan score was 75/84 on `commands.csv` and 25/30 on the then-unseen
`holdout.csv`. We subsequently used both sets to improve the router. The combined 114-row
suite is therefore a regression baseline, rather than an untouched holdout.

**jevbench** on the fixed-option questions, 84 rows:

| Question | Accuracy | ECE |
|---|---|---|
| intent | 100% | 0.023 |
| music kind | 22/22 | — |
| search engine | 16/16 | — |

p50 latency 401 ms. Music kind and search engine have too few labelled rows for tight intervals.
Running this suite needs [jevbench](https://github.com/swapnanilray/jevbench), which is a separate
tool. These are historical results; the suite does not measure full-plan execution or
end-to-end voice latency.

## What these results establish

The recorded fixture checks router interpretation against historical responses; it does not
measure fresh Jev accuracy, microphone transcription, action execution, or cancellation. The
30-row holdout was subsequently used to improve the router, so the combined 114 rows are no
longer an untouched holdout. See [performance methodology](../docs/PERFORMANCE.md).

The CLI `eval` command prints a report without failing on an accuracy regression and skips
missing fixture commands. CI uses a separate wrapper to require complete coverage and enforce
the recorded baseline; see [release checks](../docs/RELEASING.md). A green replay alone does not
validate changes to question wording against the live service.

## Fixture privacy and provenance

We publish a fixture with a curated inventory of 45 public application names, exact
built-in website candidates, and numbered synthetic bookmarks under reserved `.example`
domains. Candidate labels in answer choices and probability dictionaries use the same
public inventory.

The fixture retains historical answers, expected plans, and confidence values. **We did
not re-record responses after replacing candidate data.** Synthetic titles and URLs can
change shortlisting and question context, so replay tests interpretation of the recorded
answers rather than how Jev would respond to the public inventory today. A live accuracy
claim needs a new run from a clean test profile.

Recording still collects local app candidates and shortlisted sites, including Chrome bookmark
and top-site names and full URLs. Use a clean test profile with synthetic/public candidates,
inspect every field before committing, and run `python3 .github/scripts/check-eval.py` from the
repository root after building the debug CLI. The gate permits only exact built-in URL/title
pairs or the numbered `.example` placeholders, checks candidate answer labels as well as URLs,
and requires the curated app inventory. It rejects arbitrary paths, queries, credentials,
fragments, ports, and titles in site candidates, including on an otherwise approved public host.
New approved candidates require an explicit policy/code review. This guard is not a general
secret scanner or a substitute for reviewing commands, labels, and other fixture content.
We do not accept live user logs or personal candidate lists as test artifacts. See
[testing Varta](../docs/TESTING.md) for the broader validation workflow.
