#!/usr/bin/env python3
"""Verify a packaged Varta app without launching it or requesting permissions."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess


def output(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(app, version):
    contents = app / 'Contents'
    with (contents / 'Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    require(info['CFBundleShortVersionString'] == version, 'Wrong app version')
    require(info['CFBundleIdentifier'] == 'com.usekopai.varta', 'Wrong bundle ID')
    require(info['CFBundleExecutable'] == 'Varta', 'Wrong executable')
    require(info['LSMinimumSystemVersion'] == '15.0', 'Wrong minimum macOS version')
    for key in ['NSMicrophoneUsageDescription', 'NSAppleEventsUsageDescription',
                'NSRemindersFullAccessUsageDescription', 'NSCalendarsFullAccessUsageDescription']:
        require(info.get(key), f'Missing permission description: {key}')
    required = ['Varta.icns', 'VartaMenuTemplate.png', 'VartaMenuTemplate@2x.png',
                'LICENSE.txt', 'THIRD_PARTY_NOTICES.txt']
    for name in required:
        require((contents / 'Resources' / name).stat().st_size > 0, f'Missing resource: {name}')
    allowed = {'Info.plist', 'MacOS/Varta', '_CodeSignature/CodeResources'} | {f'Resources/{n}' for n in required}
    actual = {str(p.relative_to(contents)) for p in contents.rglob('*') if p.is_file()}
    require(actual == allowed, f'Unexpected bundle files: {actual ^ allowed}')
    require(not any((p.is_symlink() for p in contents.rglob('*'))), 'Unexpected bundle symlink')
    binary = contents / 'MacOS/Varta'
    require(output('lipo', '-archs', str(binary)).strip() == 'arm64', 'Release must be arm64-only')
    build = output('xcrun', 'vtool', '-show-build', str(binary))
    require(re.search('^\\s*platform MACOS\\s*$', build, re.M), 'Not a macOS executable')
    require(re.search('^\\s*minos 15\\.0\\s*$', build, re.M), 'Binary minimum macOS differs from Info.plist')
    for line in output('otool', '-L', str(binary)).splitlines()[1:]:
        dependency = line.strip().split(' (', 1)[0]
        require(dependency.startswith(('/System/Library/', '/usr/lib/')), f'Unbundled dependency: {dependency}')
    output('codesign', '--verify', '--deep', '--strict', str(app))
    signature = output('codesign', '-dv', '--verbose=4', str(app))
    require('Signature=adhoc' in signature, 'Expected an ad-hoc signature')
    print(f'Verified Varta {version}: arm64, macOS 15+, resources and ad-hoc signature.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('version')
    args = parser.parse_args()
    verify(args.app, args.version)
