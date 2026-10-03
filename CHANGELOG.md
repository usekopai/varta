# Changelog

We document notable changes here. During the alpha, minor releases may change behavior;
patch releases address fixes.

## [Unreleased]

### Added

- System volume and mute controls with state readback.
- Spotify and Apple Music pause, resume, and track navigation, with explicit or active-player selection.

- Push-to-talk voice commands in the MacBook notch, with a transcript, action plan, and result
  display. Hold the shortcut to speak or tap to toggle recording.
- Local Whisper transcription through WhisperKit, including transcription during pauses.
- Jev routing with structured candidates and confidence thresholds.
- Direct actions for apps, websites, searches across seven engines, and Spotify playback.
- Supported accessibility menus: Notes' New Note and Safari/Chrome's Zoom In and Zoom Out.
- Result checks for app focus, Spotify playback, and Chrome pages.
- Configurable hotkey and Keychain-backed API-key setup.
- Source installer with toolchain checks and reusable local signing.
- CLI commands for routing, execution, transcription, evaluation, and performance measurement.
- A labelled 114-command router dataset and public replay fixture.

### Fixed

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
- Multi-step app tasks and system controls are not implemented; vision-based computer use is
  disabled. Album and playlist searches require a manual play action.
- Cancellation cannot undo dispatched actions. Outcome verification covers supported
  integrations only.
