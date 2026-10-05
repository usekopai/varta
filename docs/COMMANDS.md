# Voice commands

Hold **⌥Space**, speak your request, and release. You can change the shortcut in Setup.
These examples cover the commands we support, with permissions and limits for each integration.

[Install Varta](INSTALLATION.md) · [Back to the README](../README.md)

## Volume and playback controls

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

## Music

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

## Websites and searches

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

## Browser controls

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

## Notes with content

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

## Reminders

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
and subtasks are not supported by reminder commands. For events, see [Calendar](#calendar). Task titles are limited to 300 characters.

## Calendar

| Say | Action |
|---|---|
| “schedule a launch review tomorrow at 3 PM for 30 minutes” | Create one timed event |
| “add a dentist appointment on October 12 at 10 AM for an hour” | Create an event on a named date |
| “schedule review tomorrow at 3 PM for one hour in my Work calendar” | Use one existing named calendar |
| “what’s on my calendar tomorrow?” | Show a local agenda window |
| “show my calendar today in my Work calendar” | Show that calendar's events for today |

Allow **full Calendar access** on first use. We create events in your default calendar unless
you name one. Named calendars need one exact, case-insensitive match; creation also requires
write access. We save once and read back the new event's title, calendar, start and end before
reporting success. If verification fails, check Calendar before repeating the command.

Creation requires a title, explicit day, start time and duration. Use today, tomorrow, or
“on” followed by a full English month date or ISO date. Dates without a year use the current
year; past dates are declined. Times use your Mac's local time zone. Use AM/PM, noon, midnight,
or a numeric 24-hour time with a colon. Durations support whole minutes or hours, including
“half an hour,” from one minute to 24 hours. We do not choose a duration for you.

If the date, time or duration is missing or ambiguous, use the shortcut again to answer the
question within 90 seconds. For example, follow “schedule review tomorrow at 3 PM” with
“30 minutes.” A time-only answer such as “three PM” preserves an already specified day.
Esc, an unrelated command or expiry discards the pending event. Nothing is saved until the
required details are resolved. Event creation does not check for scheduling conflicts.

Agenda queries cover today, tomorrow, or one future date and include overlapping and all-day
events across accessible calendars unless you name one. The scrollable window shows up to
50 events in start-time order and reports the total. Existing event details stay local and
are omitted from app logs and Jev requests. We do not create all-day or recurring events,
invite attendees, add locations or alerts, or edit/delete existing events in this version.

## Finder

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

## Apps and menu commands

| Say | Action |
|---|---|
| “open notes” / “launch cursor” / “fire up iterm” | Open or switch to the named app |
| “open chatgpt” | Prefer the installed app when available |
| “zoom in on Safari” | Press Safari → View → Zoom In |

We restrict accessibility presses to exact English menu paths: Notes' **New Note** and
the Chrome/Safari controls listed above. Varta rechecks the foreground app and menu item
before pressing. Other apps, arbitrary buttons, confirmation dialogs, and localized menu paths
are unsupported.

## Natural phrasing

You can begin supported requests with “please,” “can you,” “could you,” or “would you.”
We keep the original request for intent classification and preserve literal note content.
You can also say “take me to my Downloads folder,” “set a reminder to call mom tomorrow,”
“put review on my calendar tomorrow at 3 PM for 30 minutes,” or “what’s on my calendar for
tomorrow?” When a reminder or event already has an ambiguous clock hour, replying “AM” or
“PM” completes that time without changing its day. Missing hours still need a full time.

If we cannot resolve a command, we show a supported example for the relevant feature.
These phrasing variations retain the same action limits and confidence thresholds. Requests
that begin with negation, such as “please do not mute my Mac,” take no action.

## Current limits

Varta can decline uncertain requests and ignore speech classified as a non-command.
Recognition and routing can still be wrong, particularly with unfamiliar names or ambiguous
phrases. Supported examples describe intended behavior, not guaranteed outcomes.

We do not yet support multi-step app tasks, brightness controls, or
vision-based desktop automation. New plain-text notes with dictated content are supported; appending plain text to a uniquely named simple note is also supported. Replacing text and
creating formatted checklists are not.

