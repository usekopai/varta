# Installation and troubleshooting

We distribute Varta as source for **Apple silicon (M1 or later), macOS 15+, Swift 6.0 or later, and the macOS 15 SDK or later**. The package uses Swift 5 language mode but its manifest requires the Swift 6 toolchain. A compatible Xcode Command Line Tools installation is enough; the full Xcode app and an Apple Developer account are not required for a local build.

## Build and first launch

Install the tools if needed, then check the selected toolchain:

```bash
xcode-select --install
xcode-select -p
xcrun swift --version
xcrun --sdk macosx --show-sdk-version
```

Clone the repository and run the installer:

```bash
git clone https://github.com/usekopai/varta.git
cd varta
./run.sh
```

If you already have the source, start with `./run.sh` in its root. The script builds a release executable, assembles and signs the app, installs it at `~/Applications/Varta.app`, and opens it. It replaces any existing Varta app at that location. `./run.sh --no-open` installs without launching. The installer checks the selected Swift compiler and SDK before building. Build output is in `~/.varta/build.log`.

The first build downloads Swift dependencies. First launch downloads the default Whisper model (approximately 1.5 GB) to `~/.varta/models` and prepares it for local inference. Allow several minutes and space for the source, build cache, model and compiled model data. Subsequent launches reuse downloaded models.

1. Open **Varta → Setup…** from the menu bar.
2. Grant Microphone access to record commands and Accessibility access for supported button/menu actions.
3. Get a Jev API key from the [TypeSafe dashboard](https://console.typesafe.ai), following its [official quick start](https://docs.typesafe.ai/introduction/quickstart). Paste it into **TypeSafe (Jev)** and choose **Save keys**.
4. Wait until Speech says **Ready**. Hold **⌥Space**, speak a simple command such as “open Notes,” then release. A quick tap toggles recording; tap again to submit.
5. Accept macOS Automation prompts when a command first needs Spotify, Music, Notes or Chrome control. Only approve the applications you intend Varta to use.

For your first reminder, allow the separate **Reminders** permission. If denied, enable Varta
in System Settings → Privacy & Security → Reminders and repeat the command. Set a default
list in Apple Reminders before creating tasks without an explicit list. Test this from the
installed app; the unbundled CLI cannot request this permission.

Calendar commands request separate **full Calendar access** on first use, including for
creation because we verify the saved event. If denied or limited to adding events, enable
full access under System Settings → Privacy & Security → Calendars, then repeat the command.
Set a default calendar in Apple Calendar or name an existing writable calendar. Use the
installed app for the permission prompt and agenda window.

Finder filename search uses Spotlight and existing folder access. “Show this file in Finder”
also needs Accessibility access and a saved document URL exposed by the foreground app.
No new Finder Automation permission is required.

We keep screenshot-based computer use disabled. You do not need Screen Recording permission or an Anthropic/Gateway key. Esc cancels pending work; actions already dispatched to macOS cannot be undone. See [SECURITY.md](../SECURITY.md) for data handling and action boundaries.

## Network and account requirements

Speech recognition runs locally after model download. Routing still needs internet access to `https://api.typesafe.ai/v1/systemone`, a valid key, and an account permitted to make requests. Browsing and online music also depend on their respective services. Varta does not implement an offline command router.

We publish Varta under the MIT licence. Hosted API usage is billed separately by TypeSafe; check its dashboard for account limits, credits and billing terms. Usage depends on request size, additional verification/accessibility requests and retries. Builds and model downloads need access to their package/model hosts as well.

## Keys and settings

Credential lookup order is **process environment → login Keychain → `~/.varta/dev.env`**. Setup stores the Jev key as a generic password with service `com.usekopai.varta` and account `TYPESAFE_API_KEY`. Saving an empty field does not delete a saved key. An environment override takes precedence over changes in Setup.

For CLI development, create `~/.varta/dev.env` in a text editor with:

```dotenv
TYPESAFE_API_KEY=your-key-here
```

Keep the directory private (`chmod 700 ~/.varta`) and the file private (`chmod 600 ~/.varta/dev.env`). Never commit this file or paste the key into an issue. This file is parsed only for API credentials; it does **not** configure Whisper.

| Setting | Configuration |
|---|---|
| Hotkey | Setup → Hotkey → Change…; persisted in macOS preferences |
| Speech model | `VARTA_WHISPER_MODEL`; default `openai_whisper-large-v3-v20240930_turbo` |
| Language | `VARTA_WHISPER_LANGUAGE`; default `en`; automatic language detection is disabled |
| Encoder | `VARTA_WHISPER_ENCODER=ane` or `gpu`; unset uses WhisperKit's default compute configuration |

These speech settings are environment variables read at process launch. A Finder/menu-bar launch should not be assumed to inherit your shell exports. To launch the app with a different speech model, quit Varta and run the installed executable directly from Terminal:

```bash
VARTA_WHISPER_MODEL=openai_whisper-base.en "$HOME/Applications/Varta.app/Contents/MacOS/Varta"
```

Keep that Terminal session open while using this launch. Relaunching normally returns to default settings. A different model may require another download; the smaller English model trades recognition quality for speed. See [performance](PERFORMANCE.md) for measurement boundaries.

## Supported application behavior

- **Websites and searches:** Varta honors a supported browser named in the plan when installed; otherwise it prefers Chrome, falling back to the system URL handler. Explicit browser support includes Chrome, Safari, Arc, Brave, Firefox and Edge. Tab/page verification reads **Chrome only**. A successful action in another browser may be unverified, or a check may inspect an unrelated Chrome window.
- **Spotify:** install and sign into the desktop app and ensure playback works manually. Track, artist and mood requests try the top search track; the result can be wrong. Albums/playlists open search results for you to press Play. Account/service playback restrictions still apply.
- **Apple Music:** playback searches the local Music library, not the online catalogue. Catalogue selection remains manual; automatic playback verification is Spotify-only.
- **Inside applications:** the accessibility path supports only Notes → File → New Note and Safari/Chrome → View → Zoom In/Zoom Out, using exact English menu labels. Other controls, apps, localized menus and multi-step workflows are unsupported.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Build fails or reports unsupported tools | Check `xcrun swift --version` is 6.0+, `xcrun --sdk macosx --show-sdk-version` is 15+, and `xcode-select -p` points at the intended installation. Update compatible Command Line Tools if necessary. Read `~/.varta/build.log`. |
| No Dock icon | Varta is a menu-bar app. Look for its menu-bar item and open Setup there. |
| Shortcut opens another app or does nothing | Change it in Setup; conflicting global shortcuts may belong to another app. Ensure speech preparation finished. |
| No microphone input | In System Settings → Privacy & Security → Microphone, enable Varta. Check the selected input device in Sound settings, then quit and reopen Varta. |
| Button actions fail | Enable Varta under Privacy & Security → Accessibility, then restart. Only controls exposed by the target app can be pressed. |
| First action times out | Look for macOS's “allow to control” dialog. Under Privacy & Security → Automation, check the relevant target app permission, then retry. Terminal/CLI runs can have separate permission prompts. |
| Download or speech preparation fails | Check internet access, disk space and `~/.varta/app.log`; quit and reopen to retry. If a specific downloaded model is corrupt, move that model's directory out of `~/.varta/models/models/argmaxinc/whisperkit-coreml/` and retry. This triggers a download; do not delete your signing/key files. |
| “Jev is unreachable” | This can also mask credential/API errors. Inspect the preceding log error: check saved key and precedence for authentication failures, account limits for HTTP 429, and network/service availability for timeouts or server errors. |
| Permissions reset after a rebuild | Check installer output for ad-hoc signing fallback. Keep the same local signing identity; approve the newly signed app again if it changed. |
| Playback/page opens but check disagrees | See the application limitations above. A verifier result is separate from whether a command launched successfully. |

### Local signing

The installer creates **Varta Local Signing**, a self-signed identity in the dedicated `~/.varta/signing.keychain-db`, with its password in `~/.varta/signing.pass`. This is separate from API credentials in your login Keychain. The script captures the original keychain search list before creating its keychain, temporarily adds its keychain while signing, and restores the list on completion or failure. Reusing this identity is intended to preserve permissions across rebuilds; macOS may still require reapproval.

If signing fails, read the error and check both signing files exist and are accessible to your account. An interrupted first-time setup may leave an incomplete dedicated signing keychain; preserve any working identity before trying to recreate it. If the installer warns that it could not restore the keychain search list, inspect the list with `security list-keychains -d user` before retrying. `./run.sh --adhoc` is a diagnostic fallback, with likely repeated permission prompts after rebuilds. Recreating the local identity changes the identity macOS trusts. Do not delete or reset your login keychain to repair Varta signing. This local signature is not Apple notarization and is not a binary distribution signing process.

## Update

There is no automatic updater. Save or commit any local changes, inspect `git status`, then update the branch you intend to use:

```bash
git pull --ff-only
./run.sh
```

Read [CHANGELOG.md](../CHANGELOG.md) first. Rebuilding preserves `~/.varta`, the saved key and preferences; keep the signing files to reuse the identity. For a specific release, inspect available tags and check out the chosen tag before rebuilding. If Git reports local changes or diverged history, resolve that explicitly rather than discarding work.

## Logs and removal

`~/.varta/app.log` contains transcripts, plans, action arguments and results. These may expose website URLs, search queries, app names, music metadata and accessibility labels. Logging has no automatic rotation or retention limit. Build logs can include local paths. We keep microphone samples in memory during recording and transcription; the enabled pipeline does not save recordings to disk. Developer-supplied audio files remain wherever you stored them.

Quit Varta before removing its logs. Deleting `~/.varta/app.log` and `~/.varta/build.log` clears those local logs; new runs create them again. Review and redact logs before sharing, including service error responses. If you use the CLI to record evaluation fixtures, those files can contain local app and site candidates; review them before sharing.

To uninstall:

1. Quit Varta and move `~/Applications/Varta.app` to Trash. This leaves source, models, credentials and preferences intact.
2. If you want to remove stored credentials, use Keychain Access to delete only Varta's generic-password entries for service `com.usekopai.varta`. The current required account is `TYPESAFE_API_KEY`; older experimental installations may also have `ANTHROPIC_API_KEY` or `AI_GATEWAY_API_KEY`. Remove any shell overrides or `dev.env` copies too. Revoke the key in TypeSafe if you no longer need it.
3. To remove the dedicated signing keychain, run `security delete-keychain "$HOME/.varta/signing.keychain-db"` if that file exists. **Do not delete the login keychain.** Then move `~/.varta` to Trash to remove models, logs, development credentials and signing files.
4. Optionally reset preferences with `defaults delete com.usekopai.varta` (a missing-domain error means there are no preferences to remove), and remove Varta's entries from Privacy & Security settings where supported.
5. Remove your source checkout and its `app/.build` / `app/build` outputs if no longer needed. Model/framework caches outside Varta's directory are not exhaustively removed by these steps.
