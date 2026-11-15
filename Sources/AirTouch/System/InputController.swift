import AppKit
import CoreGraphics

/// Sends synthetic mouse / keyboard events to macOS. Needs Accessibility permission.
final class InputController {
    private let source = CGEventSource(stateID: .hidSystemState)

    private enum Key {
        static let leftArrow: CGKeyCode = 0x7B
        static let rightArrow: CGKeyCode = 0x7C
        static let downArrow: CGKeyCode = 0x7D
        static let upArrow: CGKeyCode = 0x7E
        static let m: CGKeyCode = 0x2E
        static let equal: CGKeyCode = 0x18
        static let minus: CGKeyCode = 0x1B
        static let space: CGKeyCode = 0x31
        static let leftBracket: CGKeyCode = 0x21
        static let rightBracket: CGKeyCode = 0x1E
        static let four: CGKeyCode = 0x15
    }

    /// Values from IOKit's NX_KEYTYPE_* list.
    private enum MediaKey: Int {
        case soundUp = 0
        case soundDown = 1
        case playPause = 16
    }

    private let arrowFlags: CGEventFlags = [.maskControl, .maskSecondaryFn, .maskNumericPad]

    // MARK: Mouse

    func moveMouse(to point: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
    }

    func mouseDown(at point: CGPoint, clickCount: Int) {
        let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        post(event)
    }

    func mouseDragged(to point: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left))
    }

    func mouseUp(at point: CGPoint, clickCount: Int) {
        let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        post(event)
    }

    func rightClick(at point: CGPoint) {
        post(CGEvent(mouseEventSource: source, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right))
        post(CGEvent(mouseEventSource: source, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right))
    }

    /// Pixel scroll. Positive `vertical` reveals content above, positive `horizontal` reveals content on the left.
    func scroll(vertical: Double, horizontal: Double) {
        let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(vertical.rounded()),
            wheel2: Int32(horizontal.rounded()),
            wheel3: 0
        )
        post(event)
    }

    // MARK: System gestures

    func nextDesktop() { press(Key.rightArrow, flags: arrowFlags) }
    func previousDesktop() { press(Key.leftArrow, flags: arrowFlags) }
    func appExpose() { press(Key.downArrow, flags: arrowFlags) }

    func missionControl() {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        } else {
            press(Key.upArrow, flags: arrowFlags)
        }
    }

    func goBack() { press(Key.leftBracket, flags: .maskCommand) }
    func goForward() { press(Key.rightBracket, flags: .maskCommand) }

    func volumeUp() { mediaKey(.soundUp) }
    func volumeDown() { mediaKey(.soundDown) }
    func playPause() { mediaKey(.playPause) }

    /// Captures the rectangle between two points by driving macOS's own screenshot tool,
    /// so AirTouch never needs Screen Recording permission of its own.
    func screenshotRegion(from: CGPoint, to: CGPoint) {
        press(Key.four, flags: [.maskCommand, .maskShift])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.post(CGEvent(mouseEventSource: self.source, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left))
            self.post(CGEvent(mouseEventSource: self.source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left))
            self.post(CGEvent(mouseEventSource: self.source, mouseType: .leftMouseDragged, mouseCursorPosition: to, mouseButton: .left))
            self.post(CGEvent(mouseEventSource: self.source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left))
        }
    }

    func minimizeWindow() { press(Key.m, flags: .maskCommand) }
    func zoomIn() { press(Key.equal, flags: .maskCommand) }
    func zoomOut() { press(Key.minus, flags: .maskCommand) }
    func spotlight() { press(Key.space, flags: .maskCommand) }

    // MARK: Plumbing

    private func press(_ key: CGKeyCode, flags: CGEventFlags) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        up?.flags = flags
        post(down)
        post(up)
    }

    /// Media keys travel as NSSystemDefined events, not as key codes.
    private func mediaKey(_ key: MediaKey) {
        for isDown in [true, false] {
            let phase = isDown ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(phase << 8)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (key.rawValue << 16) | (phase << 8),
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }
}
