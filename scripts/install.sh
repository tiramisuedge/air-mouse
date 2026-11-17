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

# Finder and Spotlight cache icons, so point Launch Services at the new copy.
touch /Applications/AirTouch.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Applications/AirTouch.app 2>/dev/null || true

# The free ad-hoc signature changes with every build, so the Accessibility grant from the
# last build no longer matches this copy, even though its switch still shows on. macOS then
# lets the cursor move but silently drops every click, scroll and shortcut. Clear the stale
# entry so macOS asks again and the switch means what it says.
if [ "${CODESIGN_IDENTITY:--}" = "-" ]; then
  tccutil reset Accessibility local.airtouch.app >/dev/null 2>&1 || true
  NEEDS_GRANT=1
else
  NEEDS_GRANT=0
fi

echo "▸ Launching…"
open /Applications/AirTouch.app
echo "✅ AirTouch is running. Look for the ✋ in your menu bar."
if [ "${NEEDS_GRANT}" = "1" ]; then
  echo ""
  echo "One step left: turn AirTouch on, and when macOS asks, allow it under"
  echo "System Settings > Privacy & Security > Accessibility. Until you do, the"
  echo "cursor will move but nothing will click or scroll."
fi
