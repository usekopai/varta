#!/usr/bin/env python3
"""Validate the app's version metadata without building or launching it."""
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]


def read_version(root=ROOT, requested=None):
    with (root / 'app/Support/Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    version = info.get('CFBundleShortVersionString', '')
    if not isinstance(version, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('App version must be MAJOR.MINOR.PATCH')
    if requested is not None and requested != version:
        raise ValueError('Release version and Info.plist must match')
    source = (root / 'app/Sources/VartaCore/Version.swift').read_text()
    match = re.search(r'version\s*=\s*"([^"]+)"', source)
    if not match or match[1] != version:
        raise ValueError('Version.swift and Info.plist must match')
    build = info.get('CFBundleVersion', '')
    if not isinstance(build, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', build):
        raise ValueError('CFBundleVersion must be a numeric build number')
    if info.get('CFBundleIdentifier') != 'com.usekopai.varta' or info.get('CFBundleExecutable') != 'Varta':
        raise ValueError('Unexpected app identity or executable')
    if info.get('LSMinimumSystemVersion') != '15.0':
        raise ValueError('Review packaging checks when changing the minimum macOS version')
    return version


if __name__ == '__main__':
    print(read_version())
