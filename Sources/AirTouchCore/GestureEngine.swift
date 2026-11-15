import CoreGraphics
import Foundation

public enum SwipeDirection: String {
    case left, right, up, down

    public var opposite: SwipeDirection {
        switch self {
        case .left: return .right
        case .right: return .left
        case .up: return .down
        case .down: return .up
        }
    }
}

public enum ZoomDirection: String {
    case zoomIn, zoomOut
}

public enum VolumeDirection: String {
    case up, down
}

public enum NavDirection: String {
    case back, forward
}

/// What the engine wants the Mac to do. Points are normalized screen coordinates
/// (0...1, origin top-left of the main display).
public enum GestureAction: Equatable {
    case engaged
    case paused
    case moveCursor(CGPoint)
    case mouseDown(CGPoint, clickCount: Int)
    case mouseDrag(CGPoint)
    case mouseUp(CGPoint, clickCount: Int)
    case rightClick(CGPoint)
    /// Pixels. Positive `dy` = hand moved down, positive `dx` = hand moved right.
    case scroll(dx: Double, dy: Double)
    /// Direction the open hand moved.
    case swipe(SwipeDirection)
    case minimize
    case zoom(ZoomDirection)
    /// The 🤙 app shortcut.
    case shortcut
    case volume(VolumeDirection)
    case playPause
    case navigate(NavDirection)
    /// Opposite corners of the region to capture, in normalized screen coordinates.
    case screenshot(from: CGPoint, to: CGPoint)
    /// Draw mode turned on or off.
    case toggleDraw(Bool)
    /// Another point on the stroke being drawn.
    case drawPoint(CGPoint)
    case drawEnd
    case drawClear
}

public enum EngineMode: String {
    case paused, tracking, pressing, scrolling, palm, fist, shortcut, zooming, volume, framing, drawing

    public var title: String {
        switch self {
        case .paused: return "Paused"
        case .tracking: return "Tracking"
        case .pressing: return "Pressing"
        case .scrolling: return "Scrolling"
        case .palm: return "Palm (swipe)"
        case .fist: return "Fist"
        case .shortcut: return "Shortcut"
        case .zooming: return "Zooming"
        case .volume: return "Volume"
        case .framing: return "Framing a shot"
        case .drawing: return "Drawing"
        }
    }
}

/// A read-only view of the engine state for the UI (cursor ring, status, preview).
public struct EngineSnapshot: Equatable {
    public var mode: EngineMode
    public var pose: Pose
    public var engaged: Bool
    public var handCount: Int
    /// Where the ring should be drawn (normalized screen coords), nil when no hand.
    public var pointer: CGPoint?
    /// 0...1 progress of a "hold" gesture (engage, pause, shortcut). Drawn as an arc.
    public var progress: Double
    /// 1 when your hand is resting, 0 when it is moving fast. The halo swells with it.
    public var calm: Double

    public static let idle = EngineSnapshot(
        mode: .paused, pose: .neutral, engaged: false, handCount: 0, pointer: nil, progress: 0, calm: 0
    )
}

public struct GestureConfig {
    /// The box in the camera frame (normalized, top-left origin) that maps to the whole screen.
    public var zoneCenter = CGPoint(x: 0.5, y: 0.55)
    public var zoneSize = CGSize(width: 0.48, height: 0.42)

    public var requirePalmToEngage = true
    /// Seconds to hold 🖐 still to start.
    public var engageHold = 0.5
    /// Seconds without a hand before AirTouch pauses itself.
    public var lostTimeout = 1.5
    /// Seconds to hold ✊ still to pause.
    public var pauseHold = 1.0

    /// After a pinch starts, the cursor is frozen this long so clicks land where you aimed.
    public var clickFreeze = 0.15
    /// Movement (normalized screen units) needed while pinched before it becomes a drag.
    /// Generous on purpose: pinching jostles your hand, and a click that turns into a
    /// drag does nothing useful, it just tries to pick up whatever you aimed at.
    public var dragDeadzone = 0.05
    /// Hold a pinch still this long and it becomes a double click.
    public var doubleHold = 0.5
    public var doubleClickInterval = 0.75
    public var doubleClickDistance = 0.09

    /// Scroll pixels per unit of hand movement (frame-height units).
    public var scrollGain = 2500.0
    /// Ignore hand movement smaller than this while scrolling (jitter).
    public var scrollDeadzone = 0.002

    /// How far (frame-height units) and how fast the open hand must move to count as a swipe.
    public var swipeDistance = 0.16
    public var swipeWindow = 0.35
    public var gestureCooldown = 0.8

    /// ✊ pulled down this far within `minimizeWindow` seconds = minimize.
    public var minimizeDistance = 0.10
    public var minimizeWindow = 0.6

    /// Seconds to hold 🤙 to fire the shortcut.
    public var shortcutHold = 0.5

    /// A ring pinch let go inside this, without moving, is a tap: play / pause.
    public var mediaTapWindow = 0.4
    /// Vertical hand movement (frame units) per volume step while the ring pinch is held.
    public var volumeStep = 0.045
    /// Seconds both hands must hold the corners before the screenshot is taken.
    public var frameHold = 0.7
    /// Seconds to hold three fingers up to turn draw mode on or off.
    public var drawHold = 0.5

    /// Two-hand pinch: change in hand separation (fraction) per zoom step.
    public var zoomStep = 0.2

    /// Frames a new pose must be seen before it's accepted.
    public var poseDebounceFrames = 2
    /// Pinches are accepted after fewer frames: waiting two frames twice over ate most
    /// of the double-click window on a camera that runs well under 30 fps.
    public var pinchDebounceFrames = 1

    public var smoothingMinCutoff = 1.0
    public var smoothingBeta = 8.0

    /// Hand speed (screen widths per second) below which the cursor is damped for fine aim.
    public var precisionLowSpeed = 0.10
    /// Speed at and above which the cursor follows your hand one to one.
    public var precisionHighSpeed = 0.70
    /// Share of your movement that reaches the cursor at the slow end. 1 = no damping.
    public var precisionGain = 0.5

    public init() {}
}

/// Turns a stream of detected hands into Mac actions.
///
/// Pure logic, no camera or OS calls, so it can be unit tested with synthetic hands.
/// Feed it every camera frame (even frames with no hands) via `process(hands:time:)`.
public final class GestureEngine {
    public var config: GestureConfig {
        didSet { applySmoothing() }
    }
    public var classifier: PoseClassifier
    public private(set) var snapshot = EngineSnapshot.idle

    struct Sample {
        var t: Double
        var p: CGPoint
    }

    private var engaged = false
    private var engageStart: Sample?

    private var stablePose: Pose = .neutral
    private var candidatePose: Pose = .neutral
    private var candidateCount = 0
    private var poseSince: Double = 0
    private var lastHandTime: Double?

    private var filter = PointFilter()
    private var cursor: CGPoint?
    private var cursorHistory: [Sample] = []
    private var precisionPoint: CGPoint?
    private var precisionTime: Double?

    // Click / drag
    private var buttonDown = false
    private var downPoint = CGPoint.zero
    private var downTime: Double = 0
    private var dragging = false
    private var clickCount = 0
    private var doubleFired = false
    private var lastUpTime: Double = -.infinity
    private var lastUpPoint = CGPoint.zero

    private var rightClickFired = false
    private var scrollPrev: CGPoint?
    private var palmHistory: [Sample] = []
    private var cooldownUntil: Double = 0
    private var fistStart: Sample?
    private var fistActed = false
    private var shortcutFired = false
    private var zoomBaseline: Double?
    private var shakaHistory: [Sample] = []
    private var volumeAnchor: CGPoint?
    private var ringMoved = false
    private var frameStart: Sample?
    private var drawing = false
    private var drawToggled = false
    private var calmLevel: Double = 0

    public init(config: GestureConfig = GestureConfig(), classifier: PoseClassifier = PoseClassifier()) {
        self.config = config
        self.classifier = classifier
        applySmoothing()
    }

    /// Stop everything (e.g. AirTouch switched off). Returns a mouse-up if a button was held.
    @discardableResult
    public func reset() -> [GestureAction] {
        var actions: [GestureAction] = []
        releaseButton(t: lastHandTime ?? 0, actions: &actions)
        if drawing {
            drawing = false
            actions.append(.toggleDraw(false))
        }
        clearTransientState()
        engaged = false
        stablePose = .neutral
        candidatePose = .neutral
        candidateCount = 0
        lastHandTime = nil
        cursor = nil
        cursorHistory.removeAll()
        precisionPoint = nil
        precisionTime = nil
        filter.reset()
        snapshot = .idle
        return actions
    }

    // MARK: - Main entry point

    public func process(hands: [Hand], time t: Double) -> [GestureAction] {
        var actions: [GestureAction] = []
        var progress = 0.0

        // Biggest hand (closest to the camera) is the primary hand.
        let usable = hands
            .filter { ($0.scale ?? 0) > 0.02 && $0.center != nil }
            .sorted { ($0.scale ?? 0) > ($1.scale ?? 0) }

        guard let primary = usable.first, let center = primary.center else {
            handleNoHands(t: t, actions: &actions)
            return actions
        }
        lastHandTime = t
        let aspect = primary.aspect

        // Pointer position: the index knuckle is much steadier than the fingertip,
        // and barely moves when you pinch.
        let anchor = primary[.indexMCP] ?? center
        let pointer = precise(filter.filter(mapToScreen(anchor), time: t), t: t)

        updatePose(classifier.classify(primary, previous: stablePose), t: t, center: center, actions: &actions)

        // MARK: Paused: wait for 🖐 held still.
        if !engaged {
            if !config.requirePalmToEngage {
                engage(t: t, pointer: pointer, actions: &actions)
            } else if stablePose == .openPalm {
                if let start = engageStart, Hand.distance(start.p, center, aspect: aspect) < 0.08 {
                    progress = min(1, (t - start.t) / config.engageHold)
                    if t - start.t >= config.engageHold {
                        engage(t: t, pointer: pointer, actions: &actions)
                        progress = 0
                    }
                } else {
                    engageStart = Sample(t: t, p: center)
                }
            } else {
                engageStart = nil
            }
            if !engaged {
                publish(mode: .paused, pointer: pointer, handCount: usable.count, progress: progress)
                return actions
            }
        }

        // MARK: Two hands: pinch with both and spread/squeeze to zoom. Clicks are disabled.
        if usable.count >= 2 {
            let a = usable[0], b = usable[1]
            if classifier.isPinching(a), classifier.isPinching(b),
               let pa = a.pinchPoint, let pb = b.pinchPoint {
                releaseButton(t: t, actions: &actions)
                let d = Hand.distance(pa, pb, aspect: aspect)
                if let base = zoomBaseline, base > 0 {
                    if d > base * (1 + config.zoomStep) {
                        actions.append(.zoom(.zoomIn))
                        zoomBaseline = d
                    } else if d < base * (1 - config.zoomStep) {
                        actions.append(.zoom(.zoomOut))
                        zoomBaseline = d
                    }
                } else {
                    zoomBaseline = d
                }
                publish(mode: .zooming, pointer: cursor ?? pointer, handCount: usable.count, progress: 0)
                return actions
            }
            // Both hands make an L: frame a region and hold to capture it.
            if classifier.isCorner(a), classifier.isCorner(b),
               let ca = a[.indexTip], let cb = b[.indexTip] {
                releaseButton(t: t, actions: &actions)
                if let start = frameStart {
                    progress = min(1, (t - start.t) / config.frameHold)
                    if t - start.t >= config.frameHold, t >= cooldownUntil {
                        actions.append(.screenshot(from: mapToScreen(ca), to: mapToScreen(cb)))
                        cooldownUntil = t + 2.0
                        frameStart = nil
                        progress = 0
                    }
                } else {
                    frameStart = Sample(t: t, p: center)
                }
                publish(mode: .framing, pointer: cursor ?? pointer, handCount: usable.count, progress: progress)
                return actions
            }
        }
        zoomBaseline = nil
        frameStart = nil

        // MARK: One hand.
        let mode: EngineMode
        switch stablePose {
        case .neutral:
            mode = .tracking
            cursor = pointer
            cursorHistory.append(Sample(t: t, p: pointer))
            cursorHistory.removeAll { t - $0.t > 0.5 }
            actions.append(.moveCursor(pointer))

        case .threeFingers:
            mode = drawing ? .drawing : .tracking
            if !drawToggled {
                progress = min(1, (t - poseSince) / config.drawHold)
                if t - poseSince >= config.drawHold, t >= cooldownUntil {
                    drawing.toggle()
                    drawToggled = true
                    cooldownUntil = t + config.gestureCooldown
                    progress = 0
                    actions.append(.toggleDraw(drawing))
                }
            }

        case .pinch where drawing:
            mode = .drawing
            cursor = pointer
            actions.append(.drawPoint(pointer))

        case .pinch:
            mode = .pressing
            if !buttonDown {
                // Only click when exactly one hand is visible (avoids clicks when starting a zoom).
                if usable.count == 1 { press(t: t, actions: &actions) }
            } else if t - downTime >= config.clickFreeze {
                if !dragging, plainDistance(pointer, downPoint) > config.dragDeadzone {
                    dragging = true
                }
                if dragging {
                    cursor = pointer
                    actions.append(.mouseDrag(pointer))
                } else if !doubleFired, t - downTime >= config.doubleHold {
                    // Held still rather than dragged: finish this click and send a second
                    // one. Far easier to land than two pinches inside a timing window.
                    actions.append(.mouseUp(downPoint, clickCount: 1))
                    actions.append(.mouseDown(downPoint, clickCount: 2))
                    actions.append(.mouseUp(downPoint, clickCount: 2))
                    buttonDown = false
                    doubleFired = true
                    lastUpTime = t
                    lastUpPoint = downPoint
                }
            }

        case .middlePinch:
            mode = .tracking
            if !rightClickFired, usable.count == 1 {
                actions.append(.rightClick(cursor ?? pointer))
                rightClickFired = true
            }

        case .victory:
            mode = .scrolling
            if let prev = scrollPrev {
                let dx = Double(center.x - prev.x) * aspect
                let dy = Double(center.y - prev.y)
                if abs(dx) > config.scrollDeadzone || abs(dy) > config.scrollDeadzone {
                    actions.append(.scroll(dx: dx * config.scrollGain, dy: dy * config.scrollGain))
                    scrollPrev = center
                }
            } else {
                scrollPrev = center
            }

        case .openPalm where drawing:
            // In draw mode an open palm wipes the sheet instead of changing desktop.
            mode = .drawing
            if t >= cooldownUntil {
                actions.append(.drawClear)
                cooldownUntil = t + config.gestureCooldown
            }

        case .openPalm:
            mode = .palm
            palmHistory.append(Sample(t: t, p: center))
            palmHistory.removeAll { t - $0.t > config.swipeWindow }
            if t >= cooldownUntil, let first = palmHistory.first {
                let dx = Double(center.x - first.p.x) * aspect
                let dy = Double(center.y - first.p.y)
                var direction: SwipeDirection?
                if abs(dx) >= abs(dy), abs(dx) > config.swipeDistance {
                    direction = dx < 0 ? .left : .right
                } else if abs(dy) > abs(dx), abs(dy) > config.swipeDistance {
                    direction = dy < 0 ? .up : .down
                }
                if let direction {
                    actions.append(.swipe(direction))
                    cooldownUntil = t + config.gestureCooldown
                    palmHistory.removeAll()
                }
            }

        case .fist:
            mode = .fist
            if let start = fistStart, !fistActed {
                let elapsed = t - start.t
                let pulledDown = Double(center.y - start.p.y)
                if elapsed <= config.minimizeWindow, pulledDown > config.minimizeDistance, t >= cooldownUntil {
                    actions.append(.minimize)
                    fistActed = true
                    cooldownUntil = t + config.gestureCooldown
                } else if Hand.distance(center, start.p, aspect: aspect) < 0.05 {
                    progress = min(1, elapsed / config.pauseHold)
                    if elapsed >= config.pauseHold {
                        pause(t: t, actions: &actions)
                        publish(mode: .paused, pointer: pointer, handCount: usable.count, progress: 0)
                        return actions
                    }
                } else if elapsed > config.minimizeWindow {
                    // Drifted: restart the hold timer instead of pausing.
                    fistStart = Sample(t: t, p: center)
                }
            }

        case .ringPinch:
            mode = .volume
            let base = volumeAnchor ?? center
            let lift = Double(center.y - base.y)
            if abs(lift) > config.volumeStep {
                actions.append(.volume(lift < 0 ? .up : .down))
                volumeAnchor = center
                ringMoved = true
            }

        case .shaka:
            mode = .shortcut
            // Flick sideways for back / forward; hold still to open the shortcut app.
            shakaHistory.append(Sample(t: t, p: center))
            shakaHistory.removeAll { t - $0.t > config.swipeWindow }
            if !shortcutFired, t >= cooldownUntil, let first = shakaHistory.first {
                let dx = Double(center.x - first.p.x) * aspect
                if abs(dx) > config.swipeDistance {
                    actions.append(.navigate(dx < 0 ? .back : .forward))
                    shortcutFired = true
                    cooldownUntil = t + config.gestureCooldown
                    shakaHistory.removeAll()
                }
            }
            if !shortcutFired {
                progress = min(1, (t - poseSince) / config.shortcutHold)
                if t - poseSince >= config.shortcutHold, t >= cooldownUntil {
                    actions.append(.shortcut)
                    shortcutFired = true
                    cooldownUntil = t + 1.0
                    progress = 0
                }
            }
        }

        publish(mode: mode, pointer: cursor ?? pointer, handCount: usable.count, progress: progress)
        return actions
    }

    // MARK: - Helpers

    private func handleNoHands(t: Double, actions: inout [GestureAction]) {
        if let last = lastHandTime, t - last > 0.3, stablePose != .neutral {
            // Hand gone: drop whatever it was doing (releases a held click).
            setPose(.neutral, t: t, center: nil, actions: &actions)
            candidatePose = .neutral
            candidateCount = 0
        }
        if engaged, let last = lastHandTime, t - last > config.lostTimeout {
            pause(t: t, actions: &actions)
        }
        engageStart = nil
        publish(mode: engaged ? .tracking : .paused, pointer: nil, handCount: 0, progress: 0)
    }

    private func updatePose(_ raw: Pose, t: Double, center: CGPoint, actions: inout [GestureAction]) {
        if raw == candidatePose {
            candidateCount += 1
        } else {
            candidatePose = raw
            candidateCount = 1
        }
        let pinching = candidatePose == .pinch || candidatePose == .middlePinch
            || stablePose == .pinch || stablePose == .middlePinch
        let needed = pinching ? config.pinchDebounceFrames : config.poseDebounceFrames
        guard candidatePose != stablePose, candidateCount >= needed else { return }
        setPose(candidatePose, t: t, center: center, actions: &actions)
    }

    private func setPose(_ new: Pose, t: Double, center: CGPoint?, actions: inout [GestureAction]) {
        switch stablePose {
        case .pinch:
            releaseButton(t: t, actions: &actions)
            doubleFired = false
            if drawing { actions.append(.drawEnd) }
        case .threeFingers: drawToggled = false
        case .middlePinch: rightClickFired = false
        case .victory: scrollPrev = nil
        case .fist:
            fistStart = nil
            fistActed = false
        case .shaka:
            shortcutFired = false
            shakaHistory.removeAll()
        case .ringPinch:
            // Let go quickly without moving and it was a tap, not a volume drag.
            if !ringMoved, t - poseSince < config.mediaTapWindow {
                actions.append(.playPause)
            }
            volumeAnchor = nil
            ringMoved = false
        case .neutral, .openPalm: break
        }
        stablePose = new
        poseSince = t
        switch new {
        case .fist: fistStart = center.map { Sample(t: t, p: $0) }
        case .victory: scrollPrev = center
        case .shaka: shakaHistory.removeAll()
        case .ringPinch:
            volumeAnchor = center
            ringMoved = false
        default: break
        }
    }

    private func engage(t: Double, pointer: CGPoint, actions: inout [GestureAction]) {
        engaged = true
        engageStart = nil
        cursor = pointer
        palmHistory.removeAll()
        // Don't treat the palm you just showed as a swipe.
        cooldownUntil = t + 0.5
        actions.append(.engaged)
    }

    private func pause(t: Double, actions: inout [GestureAction]) {
        releaseButton(t: t, actions: &actions)
        if drawing {
            drawing = false
            actions.append(.toggleDraw(false))
        }
        clearTransientState()
        engaged = false
        actions.append(.paused)
    }

    private func clearTransientState() {
        rightClickFired = false
        scrollPrev = nil
        palmHistory.removeAll()
        fistStart = nil
        fistActed = false
        shortcutFired = false
        shakaHistory.removeAll()
        volumeAnchor = nil
        ringMoved = false
        frameStart = nil
        zoomBaseline = nil
        engageStart = nil
        drawToggled = false
        calmLevel = 0
    }

    private func press(t: Double, actions: inout [GestureAction]) {
        // Use where the cursor was ~100ms ago: the pinch motion itself nudges the hand.
        let p = cursorHistory.last(where: { $0.t <= t - 0.1 })?.p ?? cursor ?? .zero
        if t - lastUpTime < config.doubleClickInterval,
           plainDistance(p, lastUpPoint) < config.doubleClickDistance {
            clickCount = min(clickCount + 1, 3)
        } else {
            clickCount = 1
        }
        buttonDown = true
        dragging = false
        doubleFired = false
        downTime = t
        downPoint = p
        cursor = p
        actions.append(.mouseDown(p, clickCount: clickCount))
    }

    private func releaseButton(t: Double, actions: inout [GestureAction]) {
        guard buttonDown else { return }
        let p = dragging ? (cursor ?? downPoint) : downPoint
        actions.append(.mouseUp(p, clickCount: clickCount))
        buttonDown = false
        dragging = false
        lastUpTime = t
        lastUpPoint = p
    }

    private func mapToScreen(_ p: CGPoint) -> CGPoint {
        let zone = config.zoneSize
        let originX = config.zoneCenter.x - zone.width / 2
        let originY = config.zoneCenter.y - zone.height / 2
        let x = (p.x - originX) / zone.width
        let y = (p.y - originY) / zone.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// Slows the cursor while your hand creeps, so small targets stop sliding away.
    /// Fast movement passes through untouched, which also walks the cursor back onto
    /// the exact point your hand maps to, so the damping never accumulates.
    private func precise(_ p: CGPoint, t: Double) -> CGPoint {
        guard let last = precisionPoint, let lastT = precisionTime, t > lastT else {
            precisionPoint = p
            precisionTime = t
            return p
        }
        let speed = plainDistance(p, last) / (t - lastT)
        calmLevel = max(0, min(1, 1 - speed / max(config.precisionHighSpeed, 0.0001)))
        let span = max(config.precisionHighSpeed - config.precisionLowSpeed, 0.0001)
        let ratio = min(1, max(0, (speed - config.precisionLowSpeed) / span))
        let gain = config.precisionGain + (1 - config.precisionGain) * ratio
        let result = CGPoint(
            x: last.x + (p.x - last.x) * CGFloat(gain),
            y: last.y + (p.y - last.y) * CGFloat(gain)
        )
        precisionPoint = result
        precisionTime = t
        return result
    }

    private func plainDistance(_ a: CGPoint, _ b: CGPoint) -> Double {
        Double(hypot(a.x - b.x, a.y - b.y))
    }

    private func applySmoothing() {
        filter.setParameters(minCutoff: config.smoothingMinCutoff, beta: config.smoothingBeta)
    }

    private func publish(mode: EngineMode, pointer: CGPoint?, handCount: Int, progress: Double) {
        snapshot = EngineSnapshot(
            mode: mode,
            pose: stablePose,
            engaged: engaged,
            handCount: handCount,
            pointer: pointer,
            progress: progress,
            calm: calmLevel
        )
    }
}
