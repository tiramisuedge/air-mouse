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

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }
}
