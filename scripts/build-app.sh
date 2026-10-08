#!/bin/zsh
# Builds Jarvis.app from the SwiftPM product (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")/.."
CONF=${1:-release}

echo "== Jarvis build ($CONF) =="

# The build is intentionally run without grep/tail so the real compiler diagnostic is never hidden.
# Swift 6 diagnostics can fail the frontend; we need the complete error and source location.
swift build -c "$CONF"

BIN=$(swift build -c "$CONF" --show-bin-path)
APP="build/Jarvis.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Jarvis" "$APP/Contents/MacOS/Jarvis"
cp Sources/Jarvis/Info.plist "$APP/Contents/Info.plist"
echo "APPL????" > "$APP/Contents/PkgInfo"

# Sign with the self-signed "Jarvis Build Signing" so TCC grants (mic/speech) survive rebuilds: ad-hoc signatures
# change with every build and macOS forgets the permissions each time. The identity lives in its own keychain,
# ~/Library/Keychains/jarvis-signing.keychain-db, whose password sits in the Jarvis secrets folder: codesign never
# touches the login keychain, so a build never asks for the login password.
# JARVIS_SIGN=adhoc forces ad-hoc signing (macOS will then re-ask mic/speech after every rebuild).
KC="$HOME/Library/Keychains/jarvis-signing.keychain-db"
PWFILE="$HOME/Library/Application Support/Jarvis/secrets/signing-keychain-password"
IDENTITY=""
if [ "${JARVIS_SIGN:-}" != "adhoc" ] && [ -f "$KC" ] && [ -f "$PWFILE" ]; then
  security unlock-keychain -p "$(cat "$PWFILE")" "$KC"
  IDENTITY=$(security find-identity -p codesigning "$KC" 2>/dev/null | awk '/"Jarvis Build Signing"/{print $2; exit}')
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --keychain "$KC" --sign "$IDENTITY" --identifier ai.martes.jarvis --options runtime --timestamp=none \
    --entitlements scripts/Jarvis.entitlements "$APP"
else
  codesign --force --sign - --identifier ai.martes.jarvis --options runtime --timestamp=none \
    --entitlements scripts/Jarvis.entitlements "$APP"
fi
[ -n "$IDENTITY" ] && echo "Signed as: Jarvis Build Signing" || echo "Signed as: ad-hoc"
echo "Built $APP"
