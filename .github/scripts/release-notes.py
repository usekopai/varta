#!/usr/bin/env python3
"""Validate version metadata and prepare notes for a source-only draft release."""
import os
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[2]
version = os.environ["RELEASE_VERSION"]
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    raise SystemExit("Invalid release version")
swift = (root / "app/Sources/VartaCore/Version.swift").read_text()
match = re.search(r'version\s*=\s*"([^"]+)"', swift)
with (root / "app/Support/Info.plist").open("rb") as handle:
    plist = plistlib.load(handle)
if not match or match[1] != version or plist["CFBundleShortVersionString"] != version:
    raise SystemExit("Tag, Version.swift and Info.plist versions must match")
changelog = (root / "CHANGELOG.md").read_text()
section = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## \[|\Z)", changelog, re.MULTILINE | re.DOTALL)
if not section or not section[1].strip():
    raise SystemExit("Missing nonempty changelog section for release version")
notes = section[1].strip() + "\n\n---\n\nSource-only experimental prerelease. No prebuilt, Developer ID-signed or notarized app is attached. See the README at this tag for requirements, source installation and known limitations. Recorded router checks do not establish live end-to-end accuracy or latency.\n"
(Path(os.environ["RUNNER_TEMP"]) / "varta-release-notes.md").write_text(notes)
