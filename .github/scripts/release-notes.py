#!/usr/bin/env python3
"""Validate release metadata and prepare notes for a downloadable alpha release."""
import os
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from release_metadata import read_version


def release_notes(root, version):
    read_version(root, requested=version)
    changelog = (root / 'CHANGELOG.md').read_text()
    section = re.search(r'^## \[' + re.escape(version) + r'\] - [0-9]{4}-[0-9]{2}-[0-9]{2}\n(.*?)(?=^## \[|\Z)',
                        changelog, re.MULTILINE | re.DOTALL)
    if not section or not section[1].strip():
        raise ValueError('Missing nonempty, dated changelog section for release version')
    return installation_notes(version) + '\n\n## Changes\n\n' + section[1].strip() + '\n'


def installation_notes(version):
    return f'''## macOS security warning — please read before installing

**This experimental alpha is not signed with a Developer ID certificate from the Apple
Developer Program and is not notarized by Apple.** We currently distribute ad-hoc-signed
builds. macOS may block the first launch with **“Varta Not Opened”** and say that Apple
could not verify that Varta is free of malware.

We plan to add Developer ID signing and notarization in a future release. For this release,
use the per-app exception below only if you trust the download from this repository.

## Download and open Varta

Download **Varta-{version}-arm64.dmg** for **Apple silicon, macOS 15+**.
Swift and Xcode are not required.

1. Open the DMG and **drag Varta onto the Applications folder shortcut**. Double-clicking
   Varta inside the DMG does not install it.
2. Wait for the copy to finish, then **eject the Varta disk image**. Eject any older Varta
   images too, so you do not accidentally launch a different copy.
3. Open **Finder → Applications → Varta**.
4. If the warning appears, choose **Done**, then open **System Settings → Privacy & Security**.
5. Scroll to **Security** and click **Open Anyway** beside the message that Varta was blocked.
6. Authenticate if prompted, then confirm **Open** in the follow-up dialog.

Dismissing the first warning alone does not approve the app. This creates an exception for
that copy of Varta; it does not notarize it or disable protection for other apps. An update
may need a fresh exception. Organization-managed Macs may prevent this approval.
[Apple’s instructions](https://support.apple.com/102445)

If **Open Anyway** is missing, try opening the installed copy once and check Privacy &
Security again. If it remains blocked, report the exact message and macOS version in a
GitHub issue. Do not disable Gatekeeper globally. These steps apply to the unverified-app
warning; they are not instructions to override a damaged-app or detected-malware alert.

## First launch

In **Varta → Setup**, enter your own **TypeSafe/Jev API key** and choose **Save keys**.
Approve the required macOS permissions and wait for speech to become ready. The initial
speech-model download is approximately 1.5 GB. API usage charges apply. Audio is transcribed
locally; command text and routing context go to Jev. Updates are manual and may require
permission reapproval.

## Verify the download

Download `SHA256SUMS.txt` into the same directory as the DMG, then run:

```sh
shasum -a 256 -c SHA256SUMS.txt
```

The checksum detects file changes; it does not establish an Apple-verified developer identity.
See the README at this tag for supported commands and limitations. Recorded router checks
do not establish live end-to-end accuracy or latency.
'''


if __name__ == '__main__':
    try:
        notes = release_notes(ROOT, os.environ['RELEASE_VERSION'])
    except ValueError as error:
        raise SystemExit(str(error))
    (Path(os.environ['RUNNER_TEMP']) / 'varta-release-notes.md').write_text(notes)
