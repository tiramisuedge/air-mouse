#!/usr/bin/env bash
# Builds AirTouch, copies it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh

echo "▸ Installing to /Applications…"
pkill -x AirTouch 2>/dev/null || true
sleep 0.5
rm -rf /Applications/AirTouch.app
cp -R build/AirTouch.app /Applications/AirTouch.app

echo "▸ Launching…"
open /Applications/AirTouch.app
echo "✅ AirTouch is running. Look for the ✋ in your menu bar."
