import CoreGraphics
import Foundation

/// The hand shapes AirTouch understands.
public enum Pose: String, CaseIterable {
    /// Anything else (relaxed hand, pointing finger…). Moves the cursor.
    case neutral
    /// Thumb tip touching index tip. Click / drag.
    case pinch
    /// Thumb tip touching middle tip. Right-click.
    case middlePinch
    /// All four fingers extended. Engage, swipes.
    case openPalm
    /// All four fingers curled. Minimize (pull down) / pause (hold still).
    case fist
    /// Index + middle extended (✌️). Scroll.
    case victory
    /// Thumb + little finger extended (🤙). App shortcut, and flick for back / forward.
    case shaka
    /// Thumb tip touching ring tip. Play / pause on a tap, volume when held and moved.
    case ringPinch
    /// Index + middle + ring extended, little curled. Holds to turn draw mode on and off.
    case threeFingers

    public var emoji: String {
        switch self {
        case .neutral: return "☝️"
        case .pinch: return "🤏"
        case .middlePinch: return "🤌"
        case .openPalm: return "🖐"
        case .fist: return "✊"
        case .victory: return "✌️"
        case .shaka: return "🤙"
        case .ringPinch: return "💍"
        case .threeFingers: return "🤟"
        }
    }

    public var title: String {
        switch self {
        case .neutral: return "Point"
        case .pinch: return "Pinch"
        case .middlePinch: return "Middle pinch"
        case .openPalm: return "Open palm"
        case .fist: return "Fist"
        case .victory: return "Two fingers"
        case .shaka: return "Shaka"
        case .ringPinch: return "Ring pinch"
        case .threeFingers: return "Three fingers"
        }
    }
}

/// Turns the 21 landmarks of a hand into a `Pose` using simple, explainable geometry.
/// All thresholds are relative to the hand's size, so distance from the camera doesn't matter.
public struct PoseClassifier {
    /// Thumb–finger gap (in hand-size units) below which a pinch starts.
    public var pinchOn = 0.30
    /// Gap above which an active pinch is released (hysteresis keeps clicks clean).
    public var pinchOff = 0.45
    /// A pinching fingertip must be at least this far from the wrist, in hand-size units.
    /// This is what tells a pinch from a fist. Bringing the index to the thumb curls the
    /// finger and pulls the tip back towards the wrist, so too high a bar rejects real
    /// pinches. Eased from 1.1; the AirTouch window shows the live number so it can be set
    /// from a real hand rather than guessed.
    public var pinchReach = 1.0
    /// tip-to-wrist / pip-to-wrist above this ⇒ finger extended.
    public var extendedRatio = 1.18
    /// tip-to-wrist / pip-to-wrist below this ⇒ finger curled.
    public var curledRatio = 1.02
    /// Thumb tip to index knuckle above this ⇒ thumb sticking out.
    public var thumbOut = 0.7

    public init() {}

    enum FingerState { case extended, curled, unknown }

    static let fingers: [(tip: Joint, pip: Joint)] = [
        (.indexTip, .indexPIP),
        (.middleTip, .middlePIP),
        (.ringTip, .ringPIP),
        (.littleTip, .littlePIP),
    ]

    func state(of finger: (tip: Joint, pip: Joint), in hand: Hand) -> FingerState {
        guard let tip = hand.distance(finger.tip, .wrist),
              let pip = hand.distance(finger.pip, .wrist),
              pip > 0 else { return .unknown }
        let ratio = tip / pip
        if ratio > extendedRatio { return .extended }
        if ratio < curledRatio { return .curled }
        return .unknown
    }

    /// The two numbers a click depends on, for the readout in the AirTouch window:
    /// `gap` has to drop below `pinchOn`, and `reach` has to stay above `pinchReach`.
    public func pinchMetrics(_ hand: Hand) -> (gap: Double, reach: Double)? {
        guard let scale = hand.scale, scale > 0,
              let gap = hand.distance(.thumbTip, .indexTip),
              let reach = hand.distance(.indexTip, .wrist) else { return nil }
        return (gap / scale, reach / scale)
    }

    /// Is the thumb tip within pinching distance of the index tip? (Looser test used for two-hand zoom.)
    public func isPinching(_ hand: Hand) -> Bool {
        guard let scale = hand.scale, scale > 0,
              let d = hand.distance(.thumbTip, .indexTip) else { return false }
        return d / scale < pinchOff
    }

    /// An L shape: index out, the other fingers curled, thumb clearly away from the knuckle.
    /// Only consulted for the two-hand framing gesture, so a one-handed point, which looks
    /// almost the same, is never stolen from the cursor.
    public func isCorner(_ hand: Hand) -> Bool {
        guard let scale = hand.scale, scale > 0 else { return false }
        let states = PoseClassifier.fingers.map { state(of: $0, in: hand) }
        let thumbIsOut = (hand.distance(.thumbTip, .indexMCP) ?? 0) / scale > thumbOut
        return states[0] == .extended && states[1] == .curled
            && states[2] == .curled && states[3] == .curled && thumbIsOut
    }

    /// Classify a hand. `previous` is the last stable pose; it lets pinches use hysteresis.
    public func classify(_ hand: Hand, previous: Pose = .neutral) -> Pose {
        guard let scale = hand.scale, scale > 0 else { return .neutral }

        // 1. Pinches first: they are the most time-sensitive (clicks).
        if let di = hand.distance(.thumbTip, .indexTip).map({ $0 / scale }),
           let dm = hand.distance(.thumbTip, .middleTip).map({ $0 / scale }) {
            let dr = hand.distance(.thumbTip, .ringTip).map { $0 / scale }
            let indexReach = (hand.distance(.indexTip, .wrist) ?? 0) / scale
            let middleReach = (hand.distance(.middleTip, .wrist) ?? 0) / scale
            let ringReach = (hand.distance(.ringTip, .wrist) ?? 0) / scale

            // Holding an existing pinch: only release once clearly apart.
            if previous == .pinch, di < pinchOff { return .pinch }
            if previous == .middlePinch, dm < pinchOff { return .middlePinch }
            // The ring finger must still be reaching for the thumb. Without this a tucked
            // thumb sits close enough to a curled ring finger to hold the pinch forever.
            if previous == .ringPinch, let dr, dr < pinchOff, ringReach > pinchReach { return .ringPinch }

            let farthest = Double.infinity
            if di <= dm, di <= (dr ?? farthest), di < pinchOn, indexReach > pinchReach { return .pinch }
            if dm < di, dm <= (dr ?? farthest), dm < pinchOn, middleReach > pinchReach,
               di > dm * 1.3 { return .middlePinch }
            if let dr, dr < pinchOn, dr < di, dr < dm, ringReach > pinchReach,
               di > dr * 1.25, dm > dr * 1.25 { return .ringPinch }
        }

        // 2. Finger-shape poses.
        let states = PoseClassifier.fingers.map { state(of: $0, in: hand) }
        let thumbIsOut = (hand.distance(.thumbTip, .indexMCP) ?? 0) / scale > thumbOut

        if states.allSatisfy({ $0 == .curled }) { return .fist }
        if states.allSatisfy({ $0 == .extended }) { return .openPalm }
        // Three fingers is the strict one, so test it before the looser two-finger shape.
        if states[0] == .extended, states[1] == .extended,
           states[2] == .extended, states[3] != .extended { return .threeFingers }
        // Two fingers only asks that the last two are not extended. Demanding a definite
        // curl meant a half-folded ring finger read as neither, and scrolling never fired.
        if states[0] == .extended, states[1] == .extended,
           states[2] != .extended, states[3] != .extended { return .victory }
        if states[3] == .extended, states[0] == .curled,
           states[1] == .curled, states[2] == .curled, thumbIsOut { return .shaka }

        return .neutral
    }
}
