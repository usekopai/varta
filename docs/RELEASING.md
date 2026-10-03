# Releasing Varta

We distribute Varta as source under `usekopai/varta`. Our release workflow builds and tests the
selected version tag, then creates a draft prerelease for maintainer review.

## Release requirements

Before a release, we:

- Run automated checks and exercise the supported commands, cancellation, and permission flows
  described in [Testing](TESTING.md).
- Test installation, upgrade, model download, and removal on an Apple silicon Mac with a
  supported macOS/toolchain. Include a clean user profile without existing Varta permissions
  or downloaded models.
- Review fixture changes and release assets for private data. Shared candidate inventories
  must use public or synthetic data and pass the evaluation gate.
- Update documentation to reflect supported behavior, requirements, and known limitations.
- Confirm repository settings for Actions, Discussions, and private vulnerability reporting.

## Automated checks

Run from the repository root:

```sh
swift build --package-path app
swift run --skip-build --package-path app varta-selftest
python3 .github/scripts/check-eval.py
zsh -n run.sh
swift build -c release --package-path app
swift run --skip-build -c release --package-path app varta-selftest
python3 .github/scripts/check-eval.py --configuration release
```

The Python helpers use the standard library. Recorded checks need no API key, microphone,
speech model, or automation permission after dependencies are fetched. We complement them
with manual installation and action tests; replay cannot verify desktop execution or live
model behavior.

## Version and changelog

Choose `MAJOR.MINOR.PATCH`, then update:

- `app/Sources/VartaCore/Version.swift`.
- `CFBundleShortVersionString` in `app/Support/Info.plist` and the appropriate
  `CFBundleVersion` build number.
- `CHANGELOG.md`: move released items from `Unreleased` into
  `## [MAJOR.MINOR.PATCH] - YYYY-MM-DD`, using the publication date.

During the alpha, minor versions may change behavior and patch versions address fixes.
We do not move published tags; corrections receive a new version.

## Create a source release

1. Commit the reviewed changes and push the release commit to `main`. Confirm CI passes.
2. Tag that commit and push the intended tag:

   ```sh
   git tag -a v0.1.0 -m "Varta 0.1.0"
   git push origin v0.1.0
   ```

   Replace `v0.1.0` with the chosen version.
3. The tag starts **Prepare source release**. To run it manually, select the workflow in
   GitHub Actions and supply an existing `vMAJOR.MINOR.PATCH` tag.
4. The workflow checks out that exact tag, verifies versions and changelog notes, builds release
   products, and runs self-tests and evaluation gates.
5. Review the resulting draft prerelease: tag, notes, source contents, requirements, and
   limitations. Publish it through GitHub Releases when ready.

The workflow creates a draft; maintainers publish it. Reruns fail if a release already exists,
so inspect and update the existing draft rather than deleting or retagging a published release.

GitHub provides source archives for published releases. Users follow [Installation](INSTALLATION.md)
to build the app. Our source workflow does not attach a prebuilt application.

## Binary distribution

A downloadable application requires a separate packaging and signing workflow. We plan that
process around these requirements:

- Bundle the executable and required resources, then sign the app and nested components with
  the maintainer's Apple Developer ID.
- Configure the required hardened-runtime entitlements, notarize the final package, and staple
  where supported.
- Check Gatekeeper, permissions, model download, installation, and upgrades on a clean Mac.
- Publish versioned archives or disk images with checksums and installation/update instructions.
- Store signing material in protected release secrets, outside the repository and PR jobs.

`run.sh` creates a local development identity for source builds. It does not perform Developer
ID signing or notarization for binary distribution.
