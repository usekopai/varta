#!/bin/bash
# Build an ad-hoc-signed DMG; does not install, launch, publish or access signing keys.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { echo 'Packaging requires an Apple silicon Mac.' >&2; exit 1; }
[[ $# -le 1 ]] || { echo 'Usage: bash scripts/package-release.sh [output-directory]' >&2; exit 1; }
version=$(python3 scripts/release_metadata.py)
output_dir=${1:-app/build/release}
mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
filename="Varta-${version}-arm64.dmg"
[[ ! -e "$output_dir/$filename" && ! -e "$output_dir/SHA256SUMS.txt" ]] || {
  echo 'Output already exists; choose a new output directory.' >&2; exit 1;
}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/varta-release.XXXXXX")
mounted=0
cleanup() {
  if [[ $mounted == 1 ]]; then hdiutil detach "$work_dir/mounted" >/dev/null || true; fi
  rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
swift build --package-path app -c release --arch arm64 --disable-automatic-resolution --product Varta
bin_dir=$(swift build --package-path app -c release --arch arm64 --show-bin-path)
# Current production targets are statically linked and have no resource bundles. Fail on a
# dependency change that needs a deliberate bundling/signing update rather than omit it.
for resource in "$bin_dir"/*.bundle "$bin_dir"/*.framework "$bin_dir"/*.dylib; do
  [[ ! -e "$resource" ]] || { echo "Review runtime packaging for: $resource" >&2; exit 1; }
done
app="$work_dir/staging/Varta.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Varta" "$app/Contents/MacOS/Varta"
cp app/Support/Info.plist "$app/Contents/Info.plist"
cp app/Support/Assets/* "$app/Contents/Resources/"
cp LICENSE "$app/Contents/Resources/LICENSE.txt"
python3 - "$app/Contents/Resources/THIRD_PARTY_NOTICES.txt" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
notices = []
for pin in json.loads(Path('app/Package.resolved').read_text())['pins']:
    checkout = Path('app/.build/checkouts') / pin['identity']
    revision = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != pin['state']['revision']:
        raise SystemExit('Dependency revision differs from Package.resolved')
    candidates = [checkout / name for name in ['LICENSE', 'LICENSE.txt', 'LICENSE.md']]
    license_file = next((p for p in candidates if p.is_file()), None)
    if license_file is None:
        raise SystemExit(f'Missing license for {pin["identity"]}')
    notices.append(f'{pin["identity"]} {pin["state"].get("version", revision)}\n{pin["location"]}\n\n{license_file.read_text()}')
Path(sys.argv[1]).write_text('\n\n' + ('\n\n' + '=' * 72 + '\n\n').join(notices))
PY
codesign --force --sign - "$app"
python3 scripts/verify-release.py "$app" "$version"
ln -s /Applications "$work_dir/staging/Applications"
cat > "$work_dir/staging/Read Me.txt" <<EOF
Varta $version — experimental alpha
Apple silicon (M1 or later), macOS 15 or later.

1. Drag Varta into Applications, then eject this disk image.
2. Open Varta from Applications. If macOS blocks it, and you trust the download,
   open System Settings > Privacy & Security and choose Open Anyway for Varta.
   Your Mac's administrator may restrict this exception.
3. Open Setup from Varta's menu bar item. Grant the requested permissions, add
   your own TypeSafe/Jev API key, and wait for Speech to show Ready.

This app is ad-hoc signed. It is NOT Developer ID signed or notarized by Apple.
Apple's instructions: https://support.apple.com/102445

Initial speech-model download: approximately 1.5 GB. Command routing requires
internet access and your own Jev API key; provider usage charges apply.
Audio is transcribed locally; command text and routing context go to Jev.

Updates are manual. Quit Varta before replacing the app in Applications.
Permissions may need to be granted again after an update or signature change.
Models and credentials are stored separately from the app.

Source, license, instructions and release notes:
https://github.com/usekopai/varta
EOF
hdiutil create -quiet -volname "Varta $version" -srcfolder "$work_dir/staging" -format UDZO "$work_dir/$filename"
hdiutil verify "$work_dir/$filename" >/dev/null
mkdir "$work_dir/mounted"
hdiutil attach -readonly -nobrowse -mountpoint "$work_dir/mounted" "$work_dir/$filename" >/dev/null
mounted=1
python3 scripts/verify-release.py "$work_dir/mounted/Varta.app" "$version"
[[ $(readlink "$work_dir/mounted/Applications") == /Applications ]]
[[ -s "$work_dir/mounted/Read Me.txt" ]]
hdiutil detach "$work_dir/mounted" >/dev/null
mounted=0
(cd "$work_dir" && shasum -a 256 "$filename" > SHA256SUMS.txt)
mv "$work_dir/$filename" "$output_dir/"
mv "$work_dir/SHA256SUMS.txt" "$output_dir/"
echo "Prepared $output_dir/$filename and SHA256SUMS.txt"
