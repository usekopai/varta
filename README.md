<div align="center">

# Varta by Kopai

**Fast, open-source voice commands that take action on your Mac.**

Hold a key, say what you want, let go. Your Mac does it.

We built Varta to make everyday Mac actions faster: local speech recognition, structured
model decisions, and direct execution, all from a small panel in the MacBook notch.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black.svg)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)](app/Package.swift)

</div>

> “play hello by adele” · “open chrome and go to hacker news” · “launch cursor”

Varta shows what it heard, the action it understood, and the result, then folds away.
Hold **⌥Space** to speak, or tap once to start recording and again to submit.

**Varta is an experimental alpha for Apple silicon Macs.** We distribute it as source
under the MIT licence. You'll need a TypeSafe API key for Jev; speech recognition runs locally.

## How it works

```
⌥Space → local Whisper transcription → Jev routing → direct action → result check
```

**Speech stays on your Mac.** We use [WhisperKit](https://github.com/argmaxinc/WhisperKit)
to run Whisper locally through Core ML.

**Jev chooses a structured action.** We generate candidates from your transcript, installed
apps, and known websites. [Jev](https://docs.typesafe.ai) selects an intent and arguments
in one routing request, rather than generating a script or a paragraph to parse.

**Code performs the action.** Apps and URLs open directly; Spotify playback uses AppleScript.
Supported menu actions use the macOS accessibility tree. Vision-based computer use is disabled.

**We check supported outcomes.** Varta reads the frontmost app, Spotify playback, or Chrome
state. Some matches are compared locally; others use another Jev request. The panel reports
mismatches and uncertainty. A completed accessibility press has no independent outcome check.

## Requirements

| Requirement | Details |
|---|---|
| Mac | Apple silicon (M1 or later), macOS 15+ |
| Build tools | Swift 6.0+ and macOS SDK 15+; compatible Xcode Command Line Tools are sufficient |
| API access | A [TypeSafe](https://docs.typesafe.ai) key for Jev; provider usage charges apply |
| Disk space | Approximately 1.5 GB for the default speech model, plus build dependencies |
| Network | Initial downloads and Jev routing/result checks require internet access |
| Integrations | Spotify desktop for direct music playback; Chrome for browser-state verification |

## Install

```bash
xcode-select --install
git clone https://github.com/usekopai/varta.git
cd varta
./run.sh
```

The installer builds Varta, signs it locally, installs it to `~/Applications`, and opens it.
The first build and speech-model preparation can take several minutes.

In Setup:

1. Allow Microphone and Accessibility access.
2. Paste your Jev API key and save it to your login Keychain.
3. Wait for Speech to show **Ready**.

Hold **⌥Space**, speak, and release. Change the shortcut in Setup if it conflicts with another
app. **Esc cancels pending work**; it cannot undo actions already dispatched to macOS.

See [Installation](docs/INSTALLATION.md) for key setup, permissions, configuration, updates,
and removal. Review [Privacy](#privacy) to understand the context sent to Jev.

<details>
<summary>Local signing and macOS permissions</summary>

We use a reusable self-signed identity to keep the app's signing identity stable across builds.
The installer stores it in a dedicated keychain at `~/.varta/signing.keychain-db` and restores
your keychain search list after signing. API credentials remain in your login Keychain.

This is a local development signature. macOS may still require permission reapproval.
Use `./run.sh --adhoc` to skip the reusable identity.

</details>

## What you can say

### Volume and playback controls

| Say | Action |
|---|---|
| “set volume to 30 percent” | Set system output volume and check the result |
| “turn the volume up” / “turn the volume down” | Adjust output volume by 10 percentage points |
| “turn volume down by 20 percent” | Subtract 20 percentage points, stopping at zero |
| “mute audio” / “unmute audio” | Change system output mute and check the result |
| “pause Spotify” / “resume Apple Music” | Control the named player and check its playback state |
| “next track” / “previous track in Apple Music” | Request track navigation |

We support playback controls in Spotify and Apple Music. Without a player name, we use
the only playing player, or the only running player if neither is playing. If both are
plausible, repeat the command with a player name. Open the player and choose content first.
macOS may ask for Automation permission to control each player.

Volume adjustments use whole percentages from 0 to 100 and preserve the current mute
state. Some external audio devices do not allow software volume control; Varta reports
an error if the device does not accept the change. These commands control system output,
not microphone mute or individual app volume. Track navigation confirms dispatch; it does
not independently verify which track was selected.

### Music

| Say | Action |
|---|---|
| “play hello by adele” | Search Spotify for the song and artist, then play the top track |
| “play blinding lights by the weeknd” | Play Spotify's top track for the song and artist |
| “play some chill jazz” | Play the top track for a mood or genre search |
| “play starboy by the weekend” | Search using the transcribed title and artist |
| “play tum hi ho by arijit singh” | Search for the title and artist, including non-English names |
| “play the album random access memories” | Open Spotify search results for you to select and play |

Tracks, artists, and moods use Spotify's AppleScript interface. Spotify must be installed,
signed in, and able to play the content. Albums and playlists leave the final selection to you.
Apple Music playback searches your local library.

### Websites and searches

| Say | Action |
|---|---|
| “open chrome and go to hacker news” | Open news.ycombinator.com in Chrome |
| “go to github dot com” | Open a spoken web address |
| “go to the verge” | Resolve the known website and open it |
| “search for flights to tokyo, hotels in kyoto and salt and pepper shakers” | Open three searches, keeping “salt and pepper shakers” together |
| “search tom and jerry and the weather in paris on youtube” | Open two YouTube searches |
| “find running shoes on amazon and also noise cancelling headphones” | Open two Amazon searches |
| “how tall is mount everest” | Open a Google search |

We support Google, YouTube, Amazon, Maps, Wikipedia, GitHub, and Reddit searches.
Known sites come from a built-in list and your Chrome bookmarks and top sites.

### Browser controls

We support these controls in Chrome and Safari:

| Say | Action |
|---|---|
| “next tab” / “previous tab” | Select the adjacent tab |
| “new tab in Chrome” | Open a new tab in Chrome |
| “close this tab” | Request the browser's Close Tab command |
| “reopen the last closed tab in Safari” | Request Safari's last closed tab |
| “go back” / “go forward” | Navigate page history |
| “reload this page” | Reload the current page |
| “zoom in” / “zoom out” | Adjust page zoom one step |

Name Chrome or Safari to bring that running browser forward. Without a name, we use the
browser that was foreground when routing started and stop if focus changes before dispatch.
If neither browser was foreground, repeat the command with a browser name. The browser
must already be running.

Enable Varta in **System Settings → Privacy & Security → Accessibility**. We use exact
English menu commands and report when a command is disabled or unavailable. Dialogs remain
for you to handle. Closing the final tab may close its window according to browser behavior;
we never substitute Close Window or Reopen Closed Window for a tab command. Feedback confirms
that the menu action was requested, not that a page finished loading. Firefox and other
browsers are not supported for these controls.

### Notes with content

| Say | Action |
|---|---|
| “create a note called Groceries with eggs, milk, and bread” | Create a titled note with the dictated body |
| “create a note called Launch ideas” | Create a titled note |
| “take a note: investigate the installer issue” | Save the content under **Quick note** |
| “make a new note” | Create a note under **Quick note** |
| “in the Launch Ideas note, add an item called Agentic Harness Evaluator” | Add the text as a new line to the named note |

We use Apple Notes' default account and default folder. Allow macOS Automation access to
Notes when prompted. Titles and content come from the original transcript; text is escaped
before being passed as HTML through AppleScript arguments. We read back the created note
by its identifier and compare its text before reporting success. Creation never changes an
existing note, and uncertain results are not retried automatically.

To append, name the existing note and the text to add. We require one exact title match
across Notes; no match does not create a note, and duplicate titles require giving the
intended note a unique title before repeating the command. We preserve the existing HTML,
recheck it before writing, and compare the complete original text plus the addition afterward.
Existing note content stays local and is omitted from subprocess command logs.

Appending currently supports simple text notes only. Locked or shared notes, attachments,
checklists, tables, and other unsupported markup are left untouched. “Add an item” adds a
plain line, not a checkbox. If an edit cannot be verified, inspect the note before retrying.

Keep the complete request to 200 words and titles to 200 characters. Explicit folders,
other notes apps, replacing/deleting existing text, attachments, and checkbox formatting are not
yet supported. If creation or readback fails, check Notes before repeating the command.

### Reminders

| Say | Action |
|---|---|
| “remind me tomorrow at 9 AM to review the release” | Create a task with a due time and alarm |
| “remind me in twenty minutes to check the build” | Create a task due after that duration |
| “add buy milk to my reminders” | Create a task without a due date |
| “remind me tomorrow to buy milk in my Shopping list” | Create an all-day task in an existing named list |

Allow **Reminders** access when macOS prompts on first use. We use your default list
unless you name one; named lists must have one exact, case-insensitive match and be writable.
We save through Apple's EventKit API and read back the new reminder before reporting success.
If verification fails, check Reminders before repeating the command; we never retry a write automatically.

Dates use your Mac's local time zone. Supported schedules include today, tomorrow, full
English month dates such as “on October 10 2027 at 9 AM,” ISO dates, and relative minutes,
hours or days. Use AM/PM, noon, midnight, or a numeric 24-hour time with a colon.
A date without a time creates an all-day task without an explicit alarm; an undated task
has neither a due date nor an alarm. Notification delivery also depends on macOS settings.

For an ambiguous time such as “tomorrow at six,” we ask for clarification and save nothing.
Use the shortcut again and say “six PM” within 90 seconds; we keep the task and original day.
You can also supply a complete date and time or say “no date.” Esc, an unrelated command,
or the timeout clears the pending request. Past times and invalid or ambiguous daylight-saving
times require another time. Recurring and location-based reminders, editing or deleting tasks,
subtasks, and calendar events are not supported. Task titles are limited to 300 characters.

### Finder

| Say | Action |
|---|---|
| “open Downloads” | Open your Downloads folder |
| “open my Documents folder” | Open your Documents folder |
| “find files named launch” | Find filenames containing “launch” in your home folder |
| “show launch.pdf in Finder” | Reveal one uniquely named file, including its extension |
| “show this file in Finder” | Reveal the foreground app's saved document, when available |

We support Home, Downloads, Documents, Desktop, Pictures, Movies and Music folders.
Say “open my Music folder” to distinguish it from the Music app.
Search uses the local Spotlight index, excludes hidden paths and directories, and matches
filenames without reading file contents. Finder selects up to ten matches in path order,
potentially opening multiple windows. We report how many matches were displayed. Use a
more specific name for a smaller result set. Exact reveal requires one case-insensitive,
diacritic-insensitive filename match; duplicates are left for you to resolve.

“This file” requires Accessibility access and an app that exposes its saved document URL.
We capture that URL before routing. Unsaved documents, browser pages, and Finder selections
are not inferred; name the file when no document path is available. A successful reveal
means we asked Finder to select it, not that we verified the resulting window.

Search covers indexed files under your home folder, subject to macOS access restrictions.
Unindexed, hidden, external-drive or unavailable cloud files may not appear. Paths, wildcards,
content search, date/type filters, moving, renaming, deleting, and opening file contents are
not supported. Filenames and results stay local except for the filename you speak in your
request, which follows normal transcript processing.

### Apps and menu commands

| Say | Action |
|---|---|
| “open notes” / “launch cursor” / “fire up iterm” | Open or switch to the named app |
| “open chatgpt” | Prefer the installed app when available |
| “zoom in on Safari” | Press Safari → View → Zoom In |

We restrict accessibility presses to exact English menu paths: Notes' **New Note** and
the Chrome/Safari controls listed above. Varta rechecks the foreground app and menu item
before pressing. Other apps, arbitrary buttons, confirmation dialogs, and localized menu paths
are unsupported.

### Current limits

Varta can decline uncertain requests and ignore speech classified as a non-command.
Recognition and routing can still be wrong, particularly with unfamiliar names or ambiguous
phrases. Supported examples describe intended behavior, not guaranteed outcomes.

We do not yet support multi-step app tasks, brightness controls, or
vision-based desktop automation. New plain-text notes with dictated content are supported; appending plain text to a uniquely named simple note is also supported. Replacing text and
creating formatted checklists are not.

## Performance

In our 15-request routing benchmark on an M4 Pro, Varta produced the expected plan for every
request, with **360 ms median total routing time** and **674 ms p95**. Subsequent requests using
the same client had a **356 ms median** and **433 ms p95**.

Speech transcription, app execution, and verification add to the time you experience.
In our synthetic speech test, the default model took **1.20 s median from simulated key release
to transcript**, with a 0.4-second delay between the clip ending and release. Varta transcribes
during pauses to reduce work remaining after release.

See [Performance](docs/PERFORMANCE.md) for hardware, raw samples, reproduction commands, and
measurement boundaries. These measurements cover routing and transcription separately.

## Router accuracy

We evaluate the router against **114 labelled commands**, covering songs, websites,
multi-searches, app names, and non-commands.

| Recorded evaluation | Result |
|---|---:|
| Whole plans matching labels | 112/114 |
| Plans meeting automatic-execution thresholds | 85/114 |
| Correct plans among those meeting the thresholds | 85/85 |
| First evaluation of the 30-command holdout, before tuning on it | 25/30 |

We tuned the confidence thresholds using this dataset. The shared fixture replays recorded
answers against a public candidate inventory; it checks interpretation rather than fresh model
accuracy, microphone recognition, or successful desktop execution. The combined dataset is no
longer an untouched holdout.

See [Evaluation](eval/README.md) for the dataset and reproducible checks.

## Privacy

- **Audio is transcribed locally.** We do not send microphone audio to Jev.
- **Jev receives command text and routing context.** This includes shortlisted app names and
  website titles/URLs, which may come from Chrome bookmarks and top sites.
- **Menu selection sends supported app and control labels.** A second request may assess
  whether the selected command completes the task.
- **Result checks may send metadata.** This can include Spotify track/artist/album information
  or a Chrome page title and URL, alongside your command.
- **We do not operate an analytics or crash-reporting service.** Local logs can contain
  transcripts, plans, URLs, and results. Review them before sharing.
- **The enabled pipeline takes no screenshots.** Jev, download hosts, browsers, search engines,
  and music services receive the requests required for their respective functions.

See [Security](SECURITY.md) for data handling and execution boundaries, and
[Installation](docs/INSTALLATION.md) for deleting credentials and local data.

## Configuration

| Setting | Where to change it |
|---|---|
| Hotkey | Setup → Hotkey → Change… |
| Speech model | `VARTA_WHISPER_MODEL`; default `openai_whisper-large-v3-v20240930_turbo` |
| Speech language | `VARTA_WHISPER_LANGUAGE`; default `en` |
| API key | Environment → login Keychain → `~/.varta/dev.env`, in that order |
| Logs | `~/.varta/app.log` and `~/.varta/build.log` |

Speech settings are read from the app's launch environment. See
[configuration instructions](docs/INSTALLATION.md#keys-and-settings) for GUI and CLI usage.

## Documentation

| Guide | Purpose |
|---|---|
| [Installation](docs/INSTALLATION.md) | Setup, configuration, troubleshooting, updates, removal |
| [Architecture](docs/ARCHITECTURE.md) | How speech becomes a plan and an action |
| [Swift package](app/README.md) | App, engine, and CLI targets |
| [Evaluation](eval/README.md) | Labelled commands and recorded router tests |
| [Testing](docs/TESTING.md) | Automated and manual contributor checks |
| [Performance](docs/PERFORMANCE.md) | Measurements and benchmarking |
| [Contributing](CONTRIBUTING.md) | Development workflow and extension points |
| [Releasing](docs/RELEASING.md) | Maintainer distribution procedure |

## Contributing

We welcome improvements to supported commands, recognition, reliability, and documentation.
Adding a website, app alias, or labelled command is a useful first contribution.
Read [CONTRIBUTING.md](CONTRIBUTING.md) to get started.

## Credits

- [Jev](https://docs.typesafe.ai) by TypeSafe — structured decision model.
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax — local Whisper through Core ML.
- Related projects: [jev-voice](https://github.com/kevinbadi/jev-voice),
  [UI-TARS](https://github.com/bytedance/ui-tars), and [ShowUI](https://github.com/showlab/showui).

## License

[MIT](LICENSE) © Kopai
