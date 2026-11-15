# ✋ AirTouch

Use your MacBook as if it had a touchscreen, without touching it. AirTouch watches your hand through the built-in camera and turns your gestures into cursor movement, clicks, scrolling and system gestures.

- **Runs entirely on your Mac.** It uses Apple's on-device Vision hand tracking, saves no video and makes no network calls.
- **Lives in the menu bar.** Switch it on or off from the ✋ icon or with **⌥⌘A** from anywhere.
- **Free to build.** You only need Apple's free command-line tools. You don't need an Apple Developer account.

## Gestures

| | Gesture | Action |
|---|---|---|
| 🖐 | Hold open palm still (½ s) | **Start** controlling |
| ✊ | Hold a fist still (1 s) | **Pause** |
| 👋 | Lower your hand | Auto-pause after 1.5 s |
| ☝️ | Move your hand | Move the cursor |
| 🤏 | Pinch thumb + index | Click |
| 🤏🤏 | Pinch twice quickly | Double-click |
| 🤏➡️ | Pinch, hold and move | Drag / select |
| 🤌 | Pinch thumb + middle | Right-click |
| ✌️ | Two fingers up, move hand | Scroll (the page follows your hand) |
| 🖐⬅️ | Swipe open hand left | Next desktop / full-screen app |
| 🖐➡️ | Swipe open hand right | Previous desktop |
| 🖐⬆️ | Swipe open hand up | Mission Control |
| 🖐⬇️ | Swipe open hand down | App Exposé |
| ✊⬇️ | Make a fist and pull it down | Minimize window |
| 🤏 🤏 | Pinch with both hands, spread / squeeze | Zoom in / out (⌘+ / ⌘−) |
| 🤙 | Hold shaka (½ s) | Open your shortcut app (Spotlight by default) |
| 💍 | Tap thumb + ring finger | Play / pause |
| 💍↕️ | Hold thumb + ring, move up / down | Volume |
| 🤙⬅️ | Flick shaka left or right | Back / forward |
| 📷 | Both hands make corners, hold | Screenshot that region |
| 🤟 | Hold three fingers up (½ s) | Draw mode on / off |
| ✍️ | Pinch and move while drawing | Draw a glowing line |
| 🖐 | Open palm while drawing | Wipe the sheet |

A ring follows your hand on screen so you always know what AirTouch is doing:
**dashed gray** = seen but paused · **blue** = moving the cursor · **green** = pressing · **purple** = scrolling · **orange** = palm/swipe · **red** = fist · **white arc** = hold-to-confirm progress.

## Install on your Mac

**Requirements:** macOS 13 Ventura or later and the Xcode Command Line Tools. If you don't have the tools yet, run this once:

```bash
xcode-select --install
```

Then:

```bash
git clone https://github.com/tiramisuedge/air-mouse.git
```

```bash
cd air-mouse
```

```bash
./scripts/install.sh
```

This builds `AirTouch.app`, copies it to `/Applications` and launches it. A ✋ appears in your menu bar, and the AirTouch window opens on first launch.

### First run

1. Click ✋ in the menu bar, then **Enable AirTouch**. You can also press **⌥⌘A**.
2. Allow **Camera** when macOS asks.
3. Allow **Accessibility**. Go to System Settings › Privacy & Security › Accessibility and switch **AirTouch** on. AirTouch needs this to move the cursor and click.
4. Raise your hand, show an open palm 🖐 and hold it still for a moment. The ring turns blue and you're in control.

> **After rebuilding:** the free ad-hoc signature changes with every build, so macOS may forget the Accessibility permission. If gestures stop working after an update, open the Accessibility settings, remove AirTouch with the − button, then add it again with +.

## Tips

- Sit about an arm's length from the screen so the camera can see your face and your raised hand.
- Open **AirTouch Window…** from the menu to see the camera, your tracked hand skeleton and the **active zone** (the dashed box). That box maps to your whole screen.
- Change **Sensitivity** in the menu. *High* means small hand movements cover the whole screen.
- Change **Pace** in the menu if the cursor feels wrong. *Gentle* is the steadiest, *Quick* is the most responsive. The cursor also slows itself near whatever you are reaching for, so the last inch is easier than the first.
- Draw mode paints on a see-through sheet over your desktop. It never changes your wallpaper, and the strokes vanish when you switch it off. Use **Draw in Black Ink** in the menu on a light wallpaper.
- Good, even lighting makes a big difference. A bright window behind you makes tracking worse.
- Swipes or scrolling going the wrong way? Go to Menu › **Directions** › Reverse Swipe or Reverse Scroll.
- Is the cursor moving opposite to your hand? Go to Menu › Directions › **Mirror Camera**.
- Desktop swipes rely on the default macOS shortcuts **⌃←** / **⌃→** (System Settings › Keyboard › Keyboard Shortcuts › Mission Control).

## Project layout

```
Sources/
  AirTouchCore/          Pure gesture logic, unit-tested
    Hand.swift             21-joint hand model
    PoseClassifier.swift   landmarks → 🖐 ✊ ✌️ 🤏 🤌 🤙
    OneEuroFilter.swift    jitter-free cursor smoothing
    GestureEngine.swift    state machine: hands over time → actions
  AirTouch/              The macOS app
    AirTouchApp.swift      menu bar UI
    AppState.swift         wires everything together, settings
    Tracking/              camera + Apple Vision hand pose
    System/                mouse/keyboard events, hotkey, permissions
    UI/                    cursor ring overlay, main window
scripts/                 build.sh, install.sh
```

Run the logic tests with `swift test` (this may need full Xcode instead of only the Command Line Tools).

## Roadmap

- Calibration wizard (point at the 4 corners)
- Gesture remapping and per-app gestures
- Multi-monitor support
- Media gestures (volume dial, play/pause)
- Public release: notarized DMG, Homebrew, auto-updates
