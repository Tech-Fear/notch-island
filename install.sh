#!/bin/zsh
# Notch Island setup: one script to build, sign, install, run and remove the app.
#
#   ./install.sh               build, install to ~/Applications and launch
#   ./install.sh build         build only (build/NotchIsland.app); used by CI
#   ./install.sh uninstall     quit and remove the app, its data and its permissions
#   ./install.sh hooks         print the Claude Code hook settings for this install
#   ./install.sh test          run the unit tests
#   ./install.sh dmg           make build/NotchIsland-<version>.dmg to share (universal: Apple Silicon + Intel)
#   ./install.sh icon          redraw Resources/AppIcon.icns from Helper/make-icon.swift
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
MIN_MACOS="15.0"

ACTION="install"; MAKE_CERT=1; LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    install|build|uninstall|hooks|test|dmg|icon) ACTION="$arg" ;;
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

  # The code needs Swift 6: Command Line Tools 16 or Xcode 16 or later.
  local swift; swift="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -1)"
  [[ -n "$swift" ]] || die "Couldn't run 'swift'. Reinstall the tools with: xcode-select --install"
  if ! version_ge "$swift" "6.0"; then
    die "Swift $swift is too old; Swift 6 or later is needed (Command Line Tools 16+).
  Update in System Settings > General > Software Update, or:
    sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
  fi
  say "macOS $os, $(uname -m), Swift $swift"
}

# --- signing --------------------------------------------------------------

# The signing certificate lives in its own small keychain, not your login keychain. Its password is
# random and known to this script, so letting codesign use the key needs no password from you
# (a login-keychain password that differs from the Mac password made that step fail).
SIGN_KEYCHAIN="$HOME/Library/Keychains/notchisland-signing.keychain-db"
SIGN_DIR="$HOME/Library/Application Support/NotchIsland Signing"   # kept apart from the app's data
SIGN_PASS_FILE="$SIGN_DIR/keychain-password"                        # readable only by you

have_cert() {
  [[ -f "$SIGN_KEYCHAIN" && -f "$SIGN_PASS_FILE" ]] &&
    security find-identity -p codesigning "$SIGN_KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"
}

unlock_signing() { security unlock-keychain -p "$(<"$SIGN_PASS_FILE")" "$SIGN_KEYCHAIN" 2>/dev/null; }

# Signs a throwaway copy of /usr/bin/true: tells whether codesign may really use the key.
can_sign() {
  unlock_signing || return 1
  local f; f="$(mktemp -t notchisland-sign)"
  cp /usr/bin/true "$f"
  codesign --force --sign "$CERT_NAME" --keychain "$SIGN_KEYCHAIN" "$f" >/dev/null 2>&1
  local ok=$?
  rm -f "$f"
  return $ok
}

# Picks the signature for this build; never stops the install. Ad-hoc works too, but then macOS
# asks for permissions again after each rebuild.
choose_identity() {
  IDENTITY="-"
  SIGN_ARGS=()
  if have_cert && can_sign; then
    IDENTITY="$CERT_NAME"
    SIGN_ARGS=(--keychain "$SIGN_KEYCHAIN")
    return 0
  fi
  if have_cert; then
    warn "The \"$CERT_NAME\" certificate can't sign right now; signing ad-hoc this time."
    warn "To recreate it: ./install.sh uninstall (answer y for the certificate), then ./install.sh"
  else
    warn "Signing ad-hoc: macOS will ask for permissions again after each rebuild."
  fi
}

# A self-signed identity. A stable signature makes macOS remember the app's permissions across rebuilds.
make_cert() {
  have_cert && return 0
  say "Creating the local code-signing certificate \"$CERT_NAME\" (its own keychain, once; no password needed)"
  mkdir -p "$SIGN_DIR"; chmod 700 "$SIGN_DIR"
  local kpw; kpw="$(/usr/bin/openssl rand -hex 24)"
  (umask 077; print -rn -- "$kpw" > "$SIGN_PASS_FILE")
  security delete-keychain "$SIGN_KEYCHAIN" 2>/dev/null || true
  security create-keychain -p "$kpw" "$SIGN_KEYCHAIN"
  security set-keychain-settings "$SIGN_KEYCHAIN"   # no auto-lock timeout
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
    security import "$d/id.p12" -k "$SIGN_KEYCHAIN" -P "$pw" -T /usr/bin/codesign >/dev/null
    # Let Apple's signing tools use the key without a prompt (we know this keychain's password).
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kpw" "$SIGN_KEYCHAIN" >/dev/null
  } always { rm -rf "$d" }
  have_cert || { warn "Couldn't create the certificate; signing ad-hoc instead."; return 0; }
}

# --- build ----------------------------------------------------------------

# ARCHS: this Mac's architecture by default; "arm64 x86_64" for a universal app (./install.sh dmg).
build_app() {
  local -a archs=(${=ARCHS:-$(uname -m)})
  say "Building (${archs[*]}, release)"
  mkdir -p build
  rm -rf build/arch
  local a bin
  for a in $archs; do
    if ! swift build -c release --arch "$a" > build/swift-build.log 2>&1; then
      grep -E "error:" build/swift-build.log | sort -u | head -20 || tail -20 build/swift-build.log
      die "Build failed ($a). Full log: build/swift-build.log"
    fi
    # Newer SwiftPM writes every architecture to the same folder: copy each one out before the next.
    bin="$(swift build -c release --arch "$a" --show-bin-path)"
    mkdir -p "build/arch/$a"
    cp "$bin/$APP_NAME" "$bin/NotchHook" "build/arch/$a/"
  done

  rm -rf "$BUILT"
  mkdir -p "$BUILT/Contents/MacOS" "$BUILT/Contents/Resources"
  local -a apps hooks archflags
  for a in $archs; do apps+=("build/arch/$a/$APP_NAME"); hooks+=("build/arch/$a/NotchHook"); archflags+=(-arch "$a"); done
  lipo -create "${apps[@]}" -output "$BUILT/Contents/MacOS/$APP_NAME"
  lipo -create "${hooks[@]}" -output "$BUILT/Contents/MacOS/notch-hook"
  cp Resources/Info.plist "$BUILT/Contents/Info.plist"
  cp Resources/AppIcon.icns "$BUILT/Contents/Resources/AppIcon.icns"
  # System-wide Now Playing helper, loaded into /usr/bin/perl at runtime (see Helper/nowplaying.m).
  clang -O2 -fobjc-arc "${archflags[@]}" -mmacosx-version-min="$MIN_MACOS" -framework Foundation -dynamiclib \
    Helper/nowplaying.m -o "$BUILT/Contents/Resources/NowPlaying.dylib"

  choose_identity
  local identity="$IDENTITY"
  codesign --force --sign "$identity" "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID.hook" "$BUILT/Contents/MacOS/notch-hook"
  codesign --force --sign "$identity" "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID.nowplaying" "$BUILT/Contents/Resources/NowPlaying.dylib"
  codesign --force --sign "$identity" "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" "$BUILT"
  codesign --verify --strict "$BUILT" || die "The signature didn't verify."
  say "Built $BUILT (signed: $identity)"
}

# A disk image people install by dragging the app to Applications. Signed with the "NotchIsland Dev"
# certificate, so the permissions people grant survive your future releases.
# Optional, to avoid the "unverified developer" warning (needs an Apple Developer account):
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"  NOTARY_PROFILE=<your notarytool keychain profile>
make_dmg() {
  ARCHS="arm64 x86_64"
  build_app
  local version; version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
  if [[ -n "${DEVELOPER_ID:-}" ]]; then
    say "Signing for distribution: $DEVELOPER_ID (hardened runtime)"
    local f
    for f in "$BUILT/Contents/MacOS/notch-hook" "$BUILT/Contents/Resources/NowPlaying.dylib" "$BUILT"; do
      codesign --force --options runtime --timestamp --entitlements Resources/NotchIsland.entitlements \
        --sign "$DEVELOPER_ID" "$f"
    done
  fi
  local stage=build/dmg dmg="build/$APP_NAME-$version.dmg"
  rm -rf "$stage" "$dmg"; mkdir -p "$stage"
  cp -R "$BUILT" "$stage/"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname "Notch Island $version" -srcfolder "$stage" -ov -format UDZO "$dmg" >/dev/null
  rm -rf "$stage"
  if [[ -n "${DEVELOPER_ID:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
    say "Notarizing (a few minutes)"
    xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait && xcrun stapler staple "$dmg"
  fi
  say "Made $dmg ($(du -h "$dmg" | cut -f1)). Attach it to a GitHub Release."
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
  if [[ -f "$SIGN_KEYCHAIN" ]]; then
    if read -q "?Also delete the \"$CERT_NAME\" signing certificate (its own keychain)? [y/N] "; then
      echo; security delete-keychain "$SIGN_KEYCHAIN" 2>/dev/null; rm -rf "$SIGN_DIR"; say "Certificate deleted"
    else
      echo
    fi
  fi
  # Left over from older versions, which put the certificate in the login keychain.
  security find-identity -p codesigning "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | grep -q "$CERT_NAME" &&
    warn "An older \"$CERT_NAME\" is in your login keychain; remove it with: security delete-identity -c \"$CERT_NAME\""
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
    (( LAUNCH )) && { open "$DEST"; say "Notch Island is running: look for its icon (a small screen with the island at the top) in the menu bar."; }
    print_hooks ;;
  uninstall)
    uninstall_app ;;
  hooks)
    print_hooks ;;
  dmg)
    check_system
    (( MAKE_CERT )) && make_cert
    make_dmg ;;
  icon)
    # Redraws Resources/AppIcon.icns from Helper/make-icon.swift.
    tmp="$(mktemp -d)"; set="$tmp/AppIcon.iconset"; mkdir -p "$set"
    swift Helper/make-icon.swift "$tmp/icon.png"
    for px in 16 32 128 256 512; do
      sips -z $px $px "$tmp/icon.png" --out "$set/icon_${px}x${px}.png" >/dev/null
      sips -z $((px * 2)) $((px * 2)) "$tmp/icon.png" --out "$set/icon_${px}x${px}@2x.png" >/dev/null
    done
    iconutil -c icns "$set" -o Resources/AppIcon.icns
    rm -rf "$tmp"
    say "Wrote Resources/AppIcon.icns" ;;
  test)
    # The Command Line Tools keep the Swift Testing macro plugin in a folder SwiftPM doesn't always search.
    plugins="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
    if [[ -d "$plugins" ]]; then swift test -Xswiftc -plugin-path -Xswiftc "$plugins"; else swift test; fi ;;
esac
