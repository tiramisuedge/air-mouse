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
}

public enum EngineMode: String {
    case paused, tracking, pressing, scrolling, palm, fist, shortcut, zooming

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

    public static let idle = EngineSnapshot(
        mode: .paused, pose: .neutral, engaged: false, handCount: 0, pointer: nil, progress: 0
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
    public var dragDeadzone = 0.02
    public var doubleClickInterval = 0.45
    public var doubleClickDistance = 0.03

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

    /// Two-hand pinch: change in hand separation (fraction) per zoom step.
    public var zoomStep = 0.2

    /// Frames a new pose must be seen before it's accepted.
    public var poseDebounceFrames = 2

    public var smoothingMinCutoff = 1.2
    public var smoothingBeta = 6.0

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

    // Click / drag
    private var buttonDown = false
    private var downPoint = CGPoint.zero
    private var downTime: Double = 0
    private var dragging = false
    private var clickCount = 0
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
        clearTransientState()
        engaged = false
        stablePose = .neutral
        candidatePose = .neutral
        candidateCount = 0
        lastHandTime = nil
        cursor = nil
        cursorHistory.removeAll()
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
        let pointer = filter.filter(mapToScreen(anchor), time: t)

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
        }
        zoomBaseline = nil

        // MARK: One hand.
        let mode: EngineMode
        switch stablePose {
        case .neutral:
            mode = .tracking
            cursor = pointer
            cursorHistory.append(Sample(t: t, p: pointer))
            cursorHistory.removeAll { t - $0.t > 0.5 }
            actions.append(.moveCursor(pointer))

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

        case .shaka:
            mode = .shortcut
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
        guard candidatePose != stablePose, candidateCount >= config.poseDebounceFrames else { return }
        setPose(candidatePose, t: t, center: center, actions: &actions)
    }

    private func setPose(_ new: Pose, t: Double, center: CGPoint?, actions: inout [GestureAction]) {
        switch stablePose {
        case .pinch: releaseButton(t: t, actions: &actions)
        case .middlePinch: rightClickFired = false
        case .victory: scrollPrev = nil
        case .fist:
            fistStart = nil
            fistActed = false
        case .shaka: shortcutFired = false
        case .neutral, .openPalm: break
        }
        stablePose = new
        poseSince = t
        switch new {
        case .fist: fistStart = center.map { Sample(t: t, p: $0) }
        case .victory: scrollPrev = center
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
        zoomBaseline = nil
        engageStart = nil
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
            progress: progress
        )
    }
}
