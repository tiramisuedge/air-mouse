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
    /// Thumb + little finger extended (🤙). App shortcut.
    case shaka

    public var emoji: String {
        switch self {
        case .neutral: return "☝️"
        case .pinch: return "🤏"
        case .middlePinch: return "🤌"
        case .openPalm: return "🖐"
        case .fist: return "✊"
        case .victory: return "✌️"
        case .shaka: return "🤙"
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
    /// A pinching fingertip must be at least this far from the wrist (tells a pinch from a fist).
    public var pinchReach = 1.1
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

    /// Is the thumb tip within pinching distance of the index tip? (Looser test used for two-hand zoom.)
    public func isPinching(_ hand: Hand) -> Bool {
        guard let scale = hand.scale, scale > 0,
              let d = hand.distance(.thumbTip, .indexTip) else { return false }
        return d / scale < pinchOff
    }

    /// Classify a hand. `previous` is the last stable pose; it lets pinches use hysteresis.
    public func classify(_ hand: Hand, previous: Pose = .neutral) -> Pose {
        guard let scale = hand.scale, scale > 0 else { return .neutral }

        // 1. Pinches first: they are the most time-sensitive (clicks).
        if let di = hand.distance(.thumbTip, .indexTip).map({ $0 / scale }),
           let dm = hand.distance(.thumbTip, .middleTip).map({ $0 / scale }) {
            let indexReach = (hand.distance(.indexTip, .wrist) ?? 0) / scale
            let middleReach = (hand.distance(.middleTip, .wrist) ?? 0) / scale

            // Holding an existing pinch: only release once clearly apart.
            if previous == .pinch, di < pinchOff { return .pinch }
            if previous == .middlePinch, dm < pinchOff { return .middlePinch }

            if di <= dm, di < pinchOn, indexReach > pinchReach { return .pinch }
            if dm < di, dm < pinchOn, middleReach > pinchReach, di > dm * 1.3 { return .middlePinch }
        }

        // 2. Finger-shape poses.
        let states = PoseClassifier.fingers.map { state(of: $0, in: hand) }
        let thumbIsOut = (hand.distance(.thumbTip, .indexMCP) ?? 0) / scale > thumbOut

        if states.allSatisfy({ $0 == .curled }) { return .fist }
        if states.allSatisfy({ $0 == .extended }) { return .openPalm }
        if states[0] == .extended, states[1] == .extended,
           states[2] == .curled, states[3] == .curled { return .victory }
        if states[3] == .extended, states[0] == .curled,
           states[1] == .curled, states[2] == .curled, thumbIsOut { return .shaka }

        return .neutral
    }
}
