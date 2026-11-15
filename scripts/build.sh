#!/usr/bin/env bash
# Builds build/AirTouch.app using only Apple's free command-line tools.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/AirTouch.app"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/AirTouch" "$APP/Contents/MacOS/AirTouch"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# "-" = ad-hoc signature: free, fine for your own Mac.
# Set CODESIGN_IDENTITY to a certificate name to keep permissions across rebuilds.
IDENTITY="${CODESIGN_IDENTITY:--}"
echo "▸ Signing (identity: $IDENTITY)…"
codesign --force --sign "$IDENTITY" --identifier local.airtouch.app "$APP"

echo "✅ Built $APP"
