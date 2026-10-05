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
    return f'''{section[1].strip()}

---

## Download and install

Download **Varta-{version}-arm64.dmg** for **Apple silicon, macOS 15+**. Open the
DMG, drag Varta into Applications, eject the image, and launch Varta from Applications.
Swift and Xcode are not required for this download.

**Experimental alpha. Ad-hoc signed; not Developer ID signed or notarized by Apple.**
If macOS blocks the app and you trust the download, use **System Settings → Privacy &
Security → Open Anyway** for Varta. Managed Macs may restrict this exception.
[Apple’s instructions](https://support.apple.com/102445)

Setup requires your own TypeSafe/Jev API key, the relevant macOS permissions, and an initial
speech-model download of approximately 1.5 GB. API usage charges apply. Audio is transcribed
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
