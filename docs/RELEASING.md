# Releasing Varta

We prepare Apple-silicon macOS app downloads in GitHub Actions and publish them through
GitHub Releases. The workflow creates a **draft prerelease** for maintainer review. It never
publishes the release automatically.

Our alpha downloads are **ad-hoc signed, not Developer ID signed or notarized by Apple**.
No Apple Developer account or signing secret is required. macOS can block first launch;
our [installation guide](INSTALLATION.md#macos-first-launch-warning) explains the user-visible exception.

## Release assets

Each draft contains:

- `Varta-MAJOR.MINOR.PATCH-arm64.dmg`, with `Varta.app`, an Applications shortcut and installation instructions.
- `SHA256SUMS.txt`, covering the final DMG.
- Release notes identifying the signing status, requirements and current changes.

GitHub also provides source archives. The DMG includes Varta's MIT license and notices for
resolved Swift package dependencies inside the app's Resources directory. Speech models,
API keys, local preferences and logs are not bundled. The model downloads on first launch.

## Automated checks

CI runs debug and release builds on an Apple-silicon `macos-15` runner. It uses
`Package.resolved` without automatic dependency resolution, runs the self-tests and recorded
router gates, checks Python release/timing helpers, and validates shell syntax. Its release
job also builds and mounts a DMG to check the packaged app. PR jobs receive no signing keys,
API keys or repository write permission.

The release workflow checks out the exact requested version tag. It validates versions and
changelog notes, builds and tests release products, then packages and verifies the app. A
separate job receives the verified files and permission to create a draft GitHub Release.
GitHub Actions used by these workflows are pinned to commit SHAs.

Offline tests do not request microphone access or execute desktop actions. They do not
establish real speech accuracy, permission behavior or visible completion.

## Build a package locally

On an Apple-silicon Mac with Swift 6+ and the macOS 15+ SDK, from the repository root:

```sh
swift build -c release --package-path app --disable-automatic-resolution
swift run --skip-build -c release --package-path app varta-selftest
python3 .github/scripts/check-eval.py --configuration release
python3 -m unittest discover -s eval -p 'test_timing_analysis.py'
python3 -m unittest discover -s tests
bash scripts/package-release.sh
```

Outputs go to `app/build/release/`, which is ignored by Git. To preserve existing outputs,
supply a different output directory; the packager refuses to overwrite an existing DMG or checksum file:

```sh
bash scripts/package-release.sh app/build/release-check
```

Packaging does not install or launch Varta and does not touch local signing identities.
It builds the app, copies a defined set of resources and license notices, signs ad hoc,
creates a compressed DMG, mounts it read-only, verifies it, and writes the checksum.

Verification checks the app version, bundle identity, permissions descriptions, `arm64`
architecture, macOS 15 deployment target, resource inventory, signature and system-only
library dependencies. New runtime bundles/frameworks cause packaging to stop for a bundling
review. This prevents silently omitting resources when dependencies change.

A local build without a dated release entry can be packaged for testing. Publishing a draft
requires the versioned changelog entry below. Do not distribute a local test build as a tagged release.

## Version and changelog

Choose `MAJOR.MINOR.PATCH`, then update:

- `app/Sources/VartaCore/Version.swift`.
- `CFBundleShortVersionString` in `app/Support/Info.plist` and its numeric `CFBundleVersion` build number.
- `CHANGELOG.md`: move the released items from `Unreleased` into `## [MAJOR.MINOR.PATCH] - YYYY-MM-DD`.

During the alpha, minor versions may change behavior and patch versions address fixes.
We do not move published tags; corrections receive a new version.

## Prepare and publish

1. Commit and push the reviewed release commit to `main`. Confirm CI passes.
2. Create and push the intended version tag:

   ```sh
   git tag -a v0.1.0 -m "Varta 0.1.0"
   git push origin v0.1.0
   ```

   Replace the version as appropriate.
3. The tag starts **Prepare app release**. A manual run accepts an existing `vMAJOR.MINOR.PATCH` tag.
4. Review the draft's tag, notes, signing disclosure, DMG and checksum.
5. Complete the downloaded-app checks below, then publish the draft through GitHub Releases.

Workflow reruns fail if that release already exists; inspect and update an existing draft
instead of silently replacing a published asset. Build artifacts are retained for 14 days;
the assets attached to a published release remain available independently of that retention period.
Private-repository releases remain private. Public downloads require public release hosting.

## Test the downloaded app

Before publication, download the actual draft DMG through a browser onto a clean Apple-silicon
Mac or clean user account without existing Varta permissions or model files. CI mounting alone
does not reproduce download quarantine or Gatekeeper prompts.

Check installation on macOS 15 and a current supported macOS version, first-launch security
prompts, permission grants, Jev-key setup, model download, cancellation and the supported actions
in [Testing](TESTING.md). Check an upgrade from the previous binary and switching from a local
source build, including permission reapproval. Confirm models/settings survive replacement and
that removal instructions match the installation location. An administrator may block exceptions
on managed devices; our download does not circumvent that policy.

## Future Developer ID releases

Developer ID signing and notarization can replace the ad-hoc step when an Apple Developer
account is available. That requires protected signing credentials, appropriate hardened-runtime
entitlements, Apple notarization and ticket stapling, followed by clean-Mac testing. The current
workflow does not claim or attempt Apple notarization.
