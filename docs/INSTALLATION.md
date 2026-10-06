# Installation and troubleshooting

Varta runs on **Apple silicon (M1 or later), macOS 15+**. Download a prebuilt app when
available, or build from source. Both paths use your own Jev API key and download the speech
model on first launch.

## Download the app

Download `Varta-VERSION-arm64.dmg` and `SHA256SUMS.txt` from the same
[GitHub Release](https://github.com/usekopai/varta/releases). If the release has no DMG,
follow the source-build instructions below. Private releases are accessible only to users
with repository access.

To check the downloaded files, put both in the same directory and run there:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

It should report `OK` for the DMG. A mismatch means the file differs from the release checksum;
download both files again from the same release. A checksum does not verify the publisher's identity.

Open the DMG, drag **Varta** into **Applications**, eject the image, and launch the installed
copy. Downloads require neither Xcode nor Swift. Avoid keeping competing copies in both
`/Applications` and `~/Applications` when switching from a source installation.
Copy the app before launching it; double-clicking Varta inside the mounted DMG does not
install it. Eject older Varta disk images to avoid opening a different copy.

### macOS first-launch warning

Our alpha app is **ad-hoc signed and not notarized by Apple**. Ad-hoc signing seals the app's
contents but does not establish a verified developer identity. macOS may block the first launch.
After attempting to open Varta, if you trust the download, open **System Settings → Privacy &
Security** and choose **Open Anyway** for Varta, then confirm the macOS prompt.
[Apple documents this exception](https://support.apple.com/102445). An organization's device
policy may prevent it. Do not disable Gatekeeper globally to install Varta.

If the initial warning remains visible, choose **Done**, then approve **Open Anyway** for
the installed copy and confirm **Open** in the follow-up prompt. Dismissing a warning alone
does not approve the app. This exception permits that copy to run; it does not notarize it.
Removing the unverified-developer block for downloads requires Developer ID signing and
Apple notarization, which our current alpha builds do not have.

Follow [first-launch setup](#first-launch-setup) once the app opens. Subsequent versions may
require a fresh security exception or permission approval because their ad-hoc signature changes.

## Build from source

Source builds require **Swift 6.0+ and macOS SDK 15+**. The package uses Swift 5 language mode,
but its manifest requires Swift 6. Compatible Xcode Command Line Tools are sufficient; a full
Xcode installation and Apple Developer account are not required.

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

The first build downloads Swift dependencies.

## First-launch setup

First launch downloads the default Whisper model (approximately 1.5 GB) to `~/.varta/models` and prepares it for local inference. Allow several minutes and additional space for compiled model data. Source builds also need space for the source and build cache. Subsequent launches reuse downloaded models.

Setup shows the download percentage and a progress bar. The menu-bar icon animates during
download and loading; open its menu for the current status. With Reduce Motion enabled, a
static preparation icon replaces the animation. After downloading, **Loading and optimizing
Whisper** can take a few minutes before **Speech ready** appears. If preparation fails,
Setup displays the error and a **Retry** button.

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
- **Apple Music:** music searches use the local Music library; online catalogue selection remains manual. Pause/resume controls check the named player's playback state.
- **Inside applications:** see the [command guide](COMMANDS.md) for supported browser controls, Notes, Reminders, Finder and Calendar actions. Browser controls use exact English menu labels in Chrome and Safari. Arbitrary in-app workflows are unsupported.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Downloaded app is blocked by macOS | See [macOS first-launch warning](#macos-first-launch-warning). Check the release checksum and your device policy; a warning is expected for an unnotarized alpha. |
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

If signing fails, read the error and check both signing files exist and are accessible to your account. An interrupted first-time setup may leave an incomplete dedicated signing keychain; preserve any working identity before trying to recreate it. If the installer warns that it could not restore the keychain search list, inspect the list with `security list-keychains -d user` before retrying. `./run.sh --adhoc` is a diagnostic fallback, with likely repeated permission prompts after rebuilds. Recreating the local identity changes the identity macOS trusts. Do not delete or reset your login keychain to repair Varta signing. This source-build signature is not Apple notarization. Prebuilt alpha downloads use ad-hoc signing and do not create this local signing keychain.

## Update

There is no automatic updater.

For a downloaded app, read the release notes, download and verify the newer DMG, and quit
Varta using its menu-bar menu. Replace the app at its existing installation location, eject
the image, and reopen it. Models, preferences and Keychain credentials are stored separately
and are not removed by replacing the app. macOS may require permission reapproval. Existing
source-install signing files can remain in place if you switch to the download.

For source builds, save or commit any local changes, inspect `git status`, then update the
branch you intend to use:

```bash
git pull --ff-only
./run.sh
```

Read [CHANGELOG.md](../CHANGELOG.md) first. Rebuilding preserves `~/.varta`, the saved key and preferences; keep the signing files to reuse the identity. For a specific release, inspect available tags and check out the chosen tag before rebuilding. If Git reports local changes or diverged history, resolve that explicitly rather than discarding work.

## Logs and removal

`~/.varta/app.log` contains transcripts, plans, action arguments and results. These may expose website URLs, search queries, app names, music metadata and accessibility labels. Logging has no automatic rotation or retention limit. Build logs can include local paths. We keep microphone samples in memory during recording and transcription; the enabled pipeline does not save recordings to disk. Developer-supplied audio files remain wherever you stored them.

Quit Varta before removing its logs. Deleting `~/.varta/app.log` and `~/.varta/build.log` clears those local logs; new runs create them again. Review and redact logs before sharing, including service error responses. If you use the CLI to record evaluation fixtures, those files can contain local app and site candidates; review them before sharing.

To uninstall:

1. Quit Varta and move its installed app to Trash (`/Applications/Varta.app` for a typical DMG installation, or `~/Applications/Varta.app` for `run.sh`). This leaves source, models, credentials and preferences intact.
2. If you want to remove stored credentials, use Keychain Access to delete only Varta's generic-password entries for service `com.usekopai.varta`. The current required account is `TYPESAFE_API_KEY`; older experimental installations may also have `ANTHROPIC_API_KEY` or `AI_GATEWAY_API_KEY`. Remove any shell overrides or `dev.env` copies too. Revoke the key in TypeSafe if you no longer need it.
3. To remove the dedicated signing keychain, run `security delete-keychain "$HOME/.varta/signing.keychain-db"` if that file exists. **Do not delete the login keychain.** Then move `~/.varta` to Trash to remove models, logs, development credentials and signing files.
4. Optionally reset preferences with `defaults delete com.usekopai.varta` (a missing-domain error means there are no preferences to remove), and remove Varta's entries from Privacy & Security settings where supported.
5. Remove your source checkout and its `app/.build` / `app/build` outputs if no longer needed. Model/framework caches outside Varta's directory are not exhaustively removed by these steps.
