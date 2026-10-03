#!/bin/zsh
# Build Varta from source and run it.
#
#   ./run.sh            build, sign, install to ~/Applications, open
#   ./run.sh --no-open  build and install only
#   ./run.sh --adhoc    skip the local signing identity (macOS will re-ask for permissions after every build)
#
# Needs: Apple silicon, macOS 15+, Swift 6+ and macOS 15+ SDK via Command Line Tools. No Xcode, no Apple developer account.
set -euo pipefail
cd "${0:A:h}"

APP_NAME="Varta"
CONFIG_DIR="$HOME/.varta"
KEYCHAIN="$CONFIG_DIR/signing.keychain-db"
KEYCHAIN_PASS_FILE="$CONFIG_DIR/signing.pass"
IDENTITY_NAME="$APP_NAME Local Signing"
INSTALL_DIR="$HOME/Applications"
OPEN=1
ADHOC=0

for arg in "$@"; do
  case $arg in
    --no-open) OPEN=0 ;;
    --adhoc) ADHOC=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (try --help)"; exit 2 ;;
  esac
done

bold() { print -P "%B$1%b"; }
fail() { print -P "%F{red}✗%f $1"; exit 1; }
ok() { print -P "%F{green}✓%f $1"; }

# 1. Requirements -------------------------------------------------------------------------------
[[ "$(uname -m)" == "arm64" ]] || fail "$APP_NAME needs Apple silicon (M1 or later): Whisper runs on the Neural Engine."
os_major=$(sw_vers -productVersion | cut -d. -f1)
(( os_major >= 15 )) || fail "$APP_NAME needs macOS 15 or later (this Mac has $(sw_vers -productVersion))."
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
  fail "The Xcode Command Line Tools are missing. Install them with:  xcode-select --install   then run ./run.sh again."
fi
swift_version=$(xcrun swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p')
[[ -n "$swift_version" ]] && (( ${swift_version%%.*} >= 6 )) || fail "Swift 6.0 or later is required. Update the selected Xcode Command Line Tools."
sdk_version=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null) || fail "No macOS SDK found. Update the selected Xcode Command Line Tools."
[[ -n "$sdk_version" ]] && (( ${sdk_version%%.*} >= 15 )) || fail "The macOS 15 SDK or later is required (selected SDK: $sdk_version). Update the selected Xcode Command Line Tools."
ok "Apple silicon, macOS $(sw_vers -productVersion), Swift $swift_version, SDK $sdk_version"

# 2. Build --------------------------------------------------------------------------------------
bold "Building (the first build fetches packages and takes a few minutes)…"
mkdir -p "$CONFIG_DIR"
BUILD_LOG="$CONFIG_DIR/build.log"
if ! ( cd app && xcrun swift build -c release --product "$APP_NAME" ) >"$BUILD_LOG" 2>&1; then
  grep -m 20 -E "error:" "$BUILD_LOG" || true
  fail "Build failed. The full output is in $BUILD_LOG"
fi
BIN="app/.build/release/$APP_NAME"

APP="app/build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp app/Support/Info.plist "$APP/Contents/Info.plist"
ok "Built $APP"

# 3. Sign ---------------------------------------------------------------------------------------
# macOS ties Microphone, Accessibility and Screen Recording to the app's signature. An ad-hoc signature
# changes with every build, so permissions would reset each time. Instead, sign with a self-signed
# certificate kept in a keychain of its own (never your login keychain): the signature then stays the
# same across rebuilds. The keychain is on the search list only while codesign runs.
sign_local() (
  # A subshell confines traps to signing. Snapshot before create-keychain, which may
  # itself change the search list. Explicit checks are needed because this function
  # is called in an `elif`, where shell errexit is disabled.
  local original_output tmp=""
  local -a original
  original_output=$(security list-keychains -d user) || return 1
  original=("${(@f)$(print -r -- "$original_output" | sed -e 's/^ *"//' -e 's/"$//')}")
  trap '[[ -z "$tmp" ]] || rm -rf "$tmp"; security list-keychains -d user -s "${original[@]}" || print -u2 "Warning: could not restore the keychain search list."' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  mkdir -p "$CONFIG_DIR" && chmod 700 "$CONFIG_DIR" || return 1
  if [[ ! -f "$KEYCHAIN" ]]; then
    bold "Creating a local signing identity (once)…"
    tmp=$(mktemp -d) || return 1
    local pass; pass=$(/usr/bin/openssl rand -hex 24) || return 1
    (umask 077; print -n "$pass" > "$KEYCHAIN_PASS_FILE") || return 1
    cat > "$tmp/cert.cnf" <<EOF || return 1
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -days 3650 -config "$tmp/cert.cnf" >/dev/null 2>&1 || return 1
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$IDENTITY_NAME" -out "$tmp/id.p12" -passout "pass:$pass" >/dev/null 2>&1 || return 1
    security create-keychain -p "$pass" "$KEYCHAIN" >/dev/null && chmod 600 "$KEYCHAIN" || return 1
    security set-keychain-settings "$KEYCHAIN" || return 1 # never auto-lock
    security unlock-keychain -p "$pass" "$KEYCHAIN" || return 1
    security import "$tmp/id.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null || return 1
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$KEYCHAIN" >/dev/null || return 1
    rm -rf "$tmp"
  fi
  [[ -r "$KEYCHAIN_PASS_FILE" ]] || return 1
  security unlock-keychain -p "$(cat "$KEYCHAIN_PASS_FILE")" "$KEYCHAIN" || return 1
  local identity; identity=$(security find-identity "$KEYCHAIN" | awk -v n="\"$IDENTITY_NAME\"" 'index($0, n) && !found {print $2; found=1}') || return 1
  [[ -n "$identity" ]] || return 1

  security list-keychains -d user -s "${original[@]}" "$KEYCHAIN" || return 1
  codesign --force --sign "$identity" "$APP" || return 1
)

if (( ADHOC )); then
  codesign --force --sign - "$APP" >/dev/null 2>&1
  ok "Signed ad hoc (permissions will be asked again after each build)"
elif sign_local; then
  ok "Signed with \"$IDENTITY_NAME\" (permissions survive rebuilds)"
else
  signing_rc=$?
  (( signing_rc != 130 && signing_rc != 143 )) || exit "$signing_rc"
  codesign --force --sign - "$APP" >/dev/null 2>&1
  print -P "%F{yellow}!%f Local signing didn't work, so the app is signed ad hoc and macOS may ask for permissions again after each build."
fi
codesign --verify --strict "$APP" || fail "The signature didn't verify."

# 4. Install and open ---------------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP" "$INSTALL_DIR/"
ok "Installed to $INSTALL_DIR/$APP_NAME.app"

if (( OPEN )); then
  open "$INSTALL_DIR/$APP_NAME.app"
  echo
  bold "$APP_NAME is starting in your menu bar."
  echo "  • The Setup window asks for Microphone and Accessibility (Screen Recording only matters for computer use)"
  echo "    and for your TypeSafe (Jev) key."
  if [[ ! -d "$CONFIG_DIR/models/models/argmaxinc/whisperkit-coreml" ]]; then
    echo "  • First launch downloads the Whisper speech model (~1.5 GB) and prepares it for the Neural Engine;"
    echo "    that takes a few minutes. Setup shows the progress."
  fi
  echo "  • Then hold ⌥Space, say what you want, and let go. Change the hotkey in Setup."
  echo "  • Log: $CONFIG_DIR/app.log"
fi
