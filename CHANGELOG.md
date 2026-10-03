# Changelog

We document notable changes here. During the alpha, minor releases may change behavior;
patch releases address fixes.

## [Unreleased]

### Added

- Finder commands for common folders, local filename searches, unique-file reveals, and supported foreground saved documents.

- Apple Reminders creation with local date parsing, default or named lists, timed alarms, and readback verification.
- Short follow-up clarification for ambiguous reminder times, with cancellation and a 90-second expiry.

- Append dictated text as a new line to one existing simple Apple Notes note, with unique-title lookup and content verification.

- Apple Notes creation with titles and dictated content, using the default destination and readback by note ID.

- Chrome and Safari tab, navigation, reload, and zoom controls with explicit or foreground targeting.

- System volume and mute controls with state readback.
- Spotify and Apple Music pause, resume, and track navigation, with explicit or active-player selection.

- Push-to-talk voice commands in the MacBook notch, with a transcript, action plan, and result
  display. Hold the shortcut to speak or tap to toggle recording.
- Local Whisper transcription through WhisperKit, including transcription during pauses.
- Jev routing with structured candidates and confidence thresholds.
- Direct actions for apps, websites, searches across seven engines, and Spotify playback.
- Supported accessibility menus: Notes' New Note and the documented Chrome/Safari browser controls.
- Result checks for app focus, Spotify playback, and Chrome pages.
- Configurable hotkey and Keychain-backed API-key setup.
- Source installer with toolchain checks and reusable local signing.
- CLI commands for routing, execution, transcription, evaluation, and performance measurement.
- A labelled 114-command router dataset and public replay fixture.

### Fixed

- Extract explicit note-append phrases directly so uncertain model boundaries cannot include the word “note” in the target title.
- Accept Notes’ standard font-size heading spans when appending to simple notes.

- Drain subprocess output while commands run to prevent larger Notes readbacks from blocking on full pipes.

- Cancelled or replaced commands discard pending transcription and model results.
- Cancellation checks precede subprocess dispatch and accessibility presses.
- Accessibility selection is restricted to supported app menus and revalidates the target
  process and menu item before pressing.
- Local signing restores the keychain search list on success and failure.
- Evaluation checks enforce fixture coverage, accuracy thresholds, and approved candidate data.

### Known limitations

- We distribute source builds for Apple silicon, macOS 15+, and Swift 6.0+.
- Jev requires API access and internet connectivity.
- Accessibility supports the listed English menu paths only.
- Multi-step app tasks and brightness controls are not implemented; vision-based computer use is
  disabled. Album and playlist searches require a manual play action.
- Cancellation cannot undo dispatched actions. Outcome verification covers supported
  integrations only.
