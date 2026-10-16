#!/bin/zsh
# Notch Island setup: one script to build, sign, install, run and remove the app.
#
#   ./install.sh               build, install to ~/Applications and launch
#   ./install.sh build         build only (build/NotchIsland.app); used by CI
#   ./install.sh uninstall     quit and remove the app, its data and its permissions
#   ./install.sh hooks         print the Claude Code hook settings for this install
#   ./install.sh test          run the unit tests
#
# Options:
#   --no-cert     don't create the local signing certificate (ad-hoc signature instead;
#                 macOS then asks for permissions again after every rebuild)
#   --no-launch   don't open the app after installing
#
# Environment:
#   NOTCH_ISLAND_APP_DIR   where to install (default: ~/Applications)

set -euo pipefail
cd "${0:A:h}"

APP_NAME="NotchIsland"
BUNDLE_ID="dev.local.NotchIsland"
CERT_NAME="NotchIsland Dev"
APP_DIR="${NOTCH_ISLAND_APP_DIR:-$HOME/Applications}"
DEST="$APP_DIR/$APP_NAME.app"
BUILT="build/$APP_NAME.app"
MIN_MACOS="14.0"

ACTION="install"; MAKE_CERT=1; LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    install|build|uninstall|hooks|test) ACTION="$arg" ;;
    --no-cert) MAKE_CERT=0 ;;
    --no-launch) LAUNCH=0 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (see ./install.sh --help)"; exit 2 ;;
  esac
done

say()  { print -P "%F{cyan}==>%f $*"; }
warn() { print -P "%F{yellow}warning:%f $*"; }
die()  { print -P "%F{red}error:%f $*"; exit 1; }

version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" == "$2" ]]; }

# --- checks ---------------------------------------------------------------

check_system() {
  local os; os="$(sw_vers -productVersion)"
  version_ge "$os" "$MIN_MACOS" || die "Notch Island needs macOS $MIN_MACOS or later (this Mac: $os)."

  xcode-select -p >/dev/null 2>&1 || {
    xcode-select --install 2>/dev/null || true
    die "Apple's Command Line Tools are missing. An installer window has opened: finish it, then run ./install.sh again."
  }

  # The code uses APIs from the macOS 15 SDK (they run on macOS 14), so it needs Swift 6:
  # Command Line Tools 16 or Xcode 16, which install on macOS 14.5 and later.
  local swift; swift="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -1)"
  [[ -n "$swift" ]] || die "Couldn't run 'swift'. Reinstall the tools with: xcode-select --install"
  if ! version_ge "$swift" "6.0"; then
    die "Swift $swift is too old; Swift 6 or later is needed (Command Line Tools 16+).
  Update in System Settings > General > Software Update (needs macOS 14.5+), or:
    sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
  fi
  say "macOS $os, $(uname -m), Swift $swift"
}

# --- signing --------------------------------------------------------------

have_cert() { security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; }

# A self-signed identity in your login keychain. A stable signature makes macOS remember the
# app's permissions across rebuilds. Remove with: security delete-identity -c "NotchIsland Dev"
make_cert() {
  have_cert && return 0
  say "Creating the local code-signing certificate \"$CERT_NAME\" (login keychain, once)"
  local d; d="$(mktemp -d)"
  {
    cat > "$d/cert.cnf" <<'EOF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=NotchIsland Dev
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/key.pem" -out "$d/cert.pem" \
      -days 3650 -config "$d/cert.cnf" 2>/dev/null
    local pw; pw="$(/usr/bin/openssl rand -hex 12)"
    # Legacy PKCS#12 algorithms: the only ones `security import` reads on every supported macOS.
    local legacy=()
    /usr/bin/openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && legacy=(-legacy)
    /usr/bin/openssl pkcs12 -export "${legacy[@]}" -inkey "$d/key.pem" -in "$d/cert.pem" -name "$CERT_NAME" \
      -out "$d/id.p12" -passout "pass:$pw" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
    security import "$d/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$pw" -T /usr/bin/codesign >/dev/null
  } always { rm -rf "$d" }
  have_cert || { warn "Couldn't create the certificate; signing ad-hoc instead."; return 0; }
}

# --- build ----------------------------------------------------------------

build_app() {
  local arch; arch="$(uname -m)"
  say "Building ($arch, release)"
  mkdir -p build
  if ! swift build -c release --arch "$arch" > build/swift-build.log 2>&1; then
    grep -E "error:" build/swift-build.log | sort -u | head -20 || tail -20 build/swift-build.log
    die "Build failed. Full log: build/swift-build.log"
  fi
  local bin; bin="$(swift build -c release --arch "$arch" --show-bin-path)"

  rm -rf "$BUILT"
  mkdir -p "$BUILT/Contents/MacOS" "$BUILT/Contents/Resources"
  cp "$bin/$APP_NAME" "$BUILT/Contents/MacOS/$APP_NAME"
  cp "$bin/NotchHook" "$BUILT/Contents/MacOS/notch-hook"
  cp Resources/Info.plist "$BUILT/Contents/Info.plist"
  # System-wide Now Playing helper, loaded into /usr/bin/perl at runtime (see Helper/nowplaying.m).
  clang -O2 -fobjc-arc -arch "$arch" -mmacosx-version-min="$MIN_MACOS" -framework Foundation -dynamiclib \
    Helper/nowplaying.m -o "$BUILT/Contents/Resources/NowPlaying.dylib"

  local identity="-"
  if have_cert; then identity="$CERT_NAME"; else warn "Signing ad-hoc: macOS will ask for permissions again after each rebuild."; fi
  codesign --force --sign "$identity" --identifier "$BUNDLE_ID.hook" "$BUILT/Contents/MacOS/notch-hook"
  codesign --force --sign "$identity" --identifier "$BUNDLE_ID.nowplaying" "$BUILT/Contents/Resources/NowPlaying.dylib"
  codesign --force --sign "$identity" --identifier "$BUNDLE_ID" "$BUILT"
  codesign --verify --strict "$BUILT" || die "The signature didn't verify."
  say "Built $BUILT (signed: $identity)"
}

quit_app() {
  pkill -x "$APP_NAME" 2>/dev/null && { for _ in {1..20}; do pgrep -x "$APP_NAME" >/dev/null || break; /bin/sleep 0.1; done } || true
}

install_app() {
  quit_app
  mkdir -p "$APP_DIR"
  rm -rf "$DEST"
  cp -R "$BUILT" "$DEST"
  say "Installed $DEST"
  # The `notch` command for scripts: a link to the helper inside the app (user folder, no sudo).
  mkdir -p "$HOME/.local/bin"
  ln -sf "$DEST/Contents/MacOS/notch-hook" "$HOME/.local/bin/notch"
  say "Command: ~/.local/bin/notch  (try: notch run -- sleep 3)"
  [[ ":$PATH:" == *":$HOME/.local/bin:"* ]] || warn "~/.local/bin is not in your PATH; add it to use 'notch' by name."
}

print_hooks() {
  local hook="$DEST/Contents/MacOS/notch-hook"
  cat <<EOF

Claude Code (optional): merge this into the "hooks" object of ~/.claude/settings.json yourself.
The app's menu has "Copy Hook Settings JSON" with the same text.

{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "\\"$hook\\"" }] }],
    "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\\"$hook\\"" }] }],
    "PermissionRequest": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "\\"$hook\\"", "timeout": 150 }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "\\"$hook\\"" }] }],
    "Stop": [{ "hooks": [{ "type": "command", "command": "\\"$hook\\"" }] }]
  }
}
EOF
}

uninstall_app() {
  say "Removing Notch Island"
  [[ -x "$DEST/Contents/MacOS/$APP_NAME" ]] && "$DEST/Contents/MacOS/$APP_NAME" --unregister-login-item 2>/dev/null || true
  quit_app
  rm -rf "$DEST" "$BUILT"
  [[ -L "$HOME/.local/bin/notch" ]] && rm -f "$HOME/.local/bin/notch"
  rm -rf "$HOME/Library/Application Support/NotchIsland" "$HOME/Library/Caches/$BUNDLE_ID"
  defaults delete "$BUNDLE_ID" 2>/dev/null || true
  tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true
  if have_cert; then
    if read -q "?Also delete the \"$CERT_NAME\" signing certificate from your keychain? [y/N] "; then
      echo; security delete-identity -c "$CERT_NAME" >/dev/null && say "Certificate deleted"
    else
      echo
    fi
  fi
  grep -q "NotchIsland.app/Contents/MacOS/notch-hook" "$HOME/.claude/settings.json" 2>/dev/null &&
    warn "Remove the notch-hook entries from ~/.claude/settings.json yourself."
  say "Done."
}

# --- main -----------------------------------------------------------------

case "$ACTION" in
  build)
    check_system
    build_app ;;
  install)
    check_system
    (( MAKE_CERT )) && make_cert
    build_app
    install_app
    (( LAUNCH )) && { open "$DEST"; say "Notch Island is running: look for the capsule icon in the menu bar."; }
    print_hooks ;;
  uninstall)
    uninstall_app ;;
  hooks)
    print_hooks ;;
  test)
    # The Command Line Tools keep the Swift Testing macro plugin in a folder SwiftPM doesn't always search.
    plugins="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
    if [[ -d "$plugins" ]]; then swift test -Xswiftc -plugin-path -Xswiftc "$plugins"; else swift test; fi ;;
esac
