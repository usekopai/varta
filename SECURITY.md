# Security

We build Varta to execute bounded voice commands on macOS. It can open apps and URLs,
control music playback, and press explicitly supported menu commands. This document explains
the data we process, the execution boundaries we enforce, and how to report vulnerabilities.

## Reporting a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/usekopai/varta/security/advisories/new)
or email **swap@usekopai.com**, rather than opening a public issue. If private reporting is
unavailable to you, use email.

Include the affected revision, a minimal reproduction, expected and actual behavior, and
potential impact. Redact credentials and unrelated personal data. During the alpha, we apply
security fixes to the latest code; we do not maintain older release branches.

## Data and credentials

| Data | Handling in the enabled pipeline |
|---|---|
| Microphone audio | Transcribed locally by WhisperKit; Varta does not upload it to Jev |
| Transcript | Sent to TypeSafe's Jev API to route commands and, where needed, judge outcomes |
| Installed app names and website candidates | Discovered locally; shortlisted names and website titles/URLs are included in Jev requests. Websites can come from Chrome bookmarks and top sites |
| App controls | Accessibility labels and menu paths are sent to Jev for selection; a selected control description may be sent in a second request |
| Playback and page metadata | Verification may send track/artist/album or active Chrome page title/URL with the command |
| Logs | `~/.varta/app.log` can contain transcripts, plans, URLs, and observed results; build logs are in `~/.varta/build.log` |
| API key | Setup stores it in the login Keychain, service `com.usekopai.varta`. Environment variables override the Keychain; plaintext `~/.varta/dev.env` is a development fallback |
| Signing identity | Local self-signed certificate and private key in `~/.varta/signing.keychain-db`; not an Apple Developer ID |

We do not operate an analytics or crash-reporting backend. Jev, model/package download hosts,
opened sites, search engines, and music services receive requests as part of their functions.
Their terms govern how they process and retain submitted data. Recorded evaluation fixtures
also include candidate lists; review them for personal data before sharing or committing them.

See [installation and removal](docs/INSTALLATION.md) for local-data cleanup.

## Execution boundaries

- Commands use argument arrays and AppleScript `on run argv`, rather than interpolating spoken
  text into a shell script. This limits shell injection; it does not validate every destination
  URL or the consequences of opening it.
- Jev selects from candidates built by code. Candidates can originate in the transcript or
  local data, and a wrong selection remains possible.
- Confidence thresholds can decline ambiguous commands. Fixture accuracy does not establish
  safety on unseen commands, other languages, or changed app interfaces.
- Accessibility presses are restricted to exact English menu paths in known bundle IDs:
  Notes (`com.apple.Notes`) → File → New Note; Safari (`com.apple.Safari`) and Chrome
  (`com.google.Chrome`) → the documented tab, navigation, reload, and zoom menu commands.
  Additional browser controls require an explicit browser-control plan; the open-ended
  app-task selector retains its Notes/New Note and browser zoom scope. The app rechecks process identity,
  foreground status, menu ancestry, element identity, enabled state and press support.
  Arbitrary buttons, generic confirmations, unknown apps and localized paths are rejected.
  This assumes the local applications and macOS accessibility service are trusted; bundle
  IDs are not cryptographic app authentication.
- Esc and replacement commands invalidate pending work. Cancellation is checked after routing
  and accessibility requests and before new action dispatches; cancelled transcriptions and
  stale UI events are discarded. It does not roll back actions already dispatched to macOS,
  and an in-flight network request or subprocess may finish after cancellation.
- Note creation passes escaped text as AppleScript arguments, writes to Notes' default
  account/folder, and reads back only the created note by ID. Creation is never retried
  automatically. A timeout or verification error may occur after a note was created;
  inspect Notes before repeating the command.
- Appending requires one matching note title and supports simple text notes only. We reject
  locked/shared notes and attachments, preserve existing HTML, and recheck the target and
  original body before writing. Existing note content is kept local and excluded from command
  and error logs. Notes has no atomic conditional append; simultaneous edits remain a possible
  race. We verify the full text afterward and never retry an uncertain write automatically.
- Verification is partial. It checks supported app/browser state and sometimes asks Jev to
  judge a match. Accessibility presses are reported as unverified. A failed check does not undo
  the action, and an unavailable check is not proof of success.

## Experimental computer use

`Features.computerUse` is false. The enabled pipeline does not take or transmit screenshots,
or use the experimental multi-step vision agent. That source contains additional capabilities,
including screenshots and synthetic keyboard/mouse input, and checks such as password-field
blocking. Those checks are not a general guarantee about the enabled accessibility tier.

We keep computer use disabled while developing it. Enabling it introduces additional
permissions, providers, and outbound data and requires a separate security review.

## Scope

Please report crafted commands, web pages, documents, app controls, or local inputs that cause
unexpected actions, bypass intended guards, expose credentials, or disclose data beyond the
behavior documented above. Reports concerning dependencies are welcome when Varta's usage
creates exposure; upstream fixes may also be necessary.

A source build being self-signed rather than notarized, and the documented need for macOS
permissions, are expected properties rather than vulnerabilities by themselves.


## Reminders access

Apple's EventKit API requires full Reminders access to create tasks. We request it on first
use through the installed app's usage description. We read list metadata to choose the
requested destination, then read back only the newly created reminder by identifier. Existing
reminder contents are not sent to Jev. Your spoken request follows the transcript handling
and logging described above.

We check cancellation before saving, make one save attempt, and verify the saved fields.
A save may complete before cancellation arrives; cancellation cannot undo it. If readback
fails, we ask you to inspect Reminders before retrying to avoid duplicates. An ambiguous
schedule stays in memory for at most 90 seconds and does not write anything until clarified.


## Finder commands

Finder commands open directories or select files; they do not open file contents or modify,
move, rename or delete files. Filename search uses the local Spotlight index within the home
folder. We pass the escaped predicate as a process argument, validate actual filenames and
paths, and keep result lists local. Existing file contents are never read or sent to Jev.
Spoken filenames and result summaries follow the normal transcript and app logging policy.

Current-document reveals use the foreground app's Accessibility document URL captured before
routing. They require an existing local file and do not fall back to an inferred selection.
Cancellation is checked before dispatch; Finder windows already requested cannot be undone.


## Calendar access

Calendar commands request full EventKit access so we can verify new events and read a day
agenda. We create a single nonrecurring timed event without setting attendees, invitations,
locations, notes or explicit alarms. We require a writable default or uniquely named calendar
and check cancellation before saving. A completed save cannot be undone by cancellation;
uncertain saves require inspection in Calendar before retrying.

Agenda queries read one requested day from accessible calendars, optionally restricted to a
named calendar. Results appear locally in a Varta window. Existing event details are omitted
from pipeline logs and are never sent to Jev; normal handling still applies to the request
you dictate and the confirmation for an event you create. Agenda display does not execute
instructions embedded in event titles. Pending clarification lives in memory for 90 seconds.


## Timing records

The app adds timing-only JSON records to its existing local log. They contain a random command
identifier, timestamp, app version, intent, speech reuse source, outcome and stage durations.
They omit transcripts, arguments, file paths, note/event titles and response bodies. These
records are not uploaded. Existing transcript logging is unchanged. The timing analyzer exports
an allowlisted subset of fields and counts incomplete attempts without exporting command text.
