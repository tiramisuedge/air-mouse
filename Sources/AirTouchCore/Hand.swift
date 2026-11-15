import CoreGraphics
import Foundation

/// The 21 hand landmarks Apple Vision reports.
public enum Joint: String, CaseIterable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

/// One detected hand.
///
/// Coordinates are normalized to the camera frame (0...1) with the origin at the
/// **top-left**, already mirrored so it matches what you see in a mirror:
/// moving your hand to your right increases `x`, raising it decreases `y`.
public struct Hand {
    public var points: [Joint: CGPoint]
    /// Camera frame width / height. Used so distances are equal in x and y.
    public var aspect: Double

    public init(points: [Joint: CGPoint], aspect: Double) {
        self.points = points
        self.aspect = aspect
    }

    public subscript(_ joint: Joint) -> CGPoint? { points[joint] }

    /// Distance between two points in frame-height units, corrected for aspect ratio.
    public static func distance(_ p: CGPoint, _ q: CGPoint, aspect: Double) -> Double {
        let dx = Double(p.x - q.x) * aspect
        let dy = Double(p.y - q.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    public func distance(_ a: Joint, _ b: Joint) -> Double? {
        guard let p = points[a], let q = points[b] else { return nil }
        return Hand.distance(p, q, aspect: aspect)
    }

    /// Size of the hand (wrist → middle knuckle). Everything is measured relative to
    /// this so gestures work whether your hand is near or far from the camera.
    public var scale: Double? {
        distance(.wrist, .middleMCP) ?? distance(.wrist, .indexMCP)
    }

    /// Palm center: average of the wrist and the four knuckles that were detected.
    public var center: CGPoint? {
        let joints: [Joint] = [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let found = joints.compactMap { points[$0] }
        guard found.count >= 2 else { return nil }
        let sx = found.reduce(0) { $0 + $1.x }
        let sy = found.reduce(0) { $0 + $1.y }
        return CGPoint(x: sx / CGFloat(found.count), y: sy / CGFloat(found.count))
    }

    /// Midpoint between the thumb tip and the index tip.
    public var pinchPoint: CGPoint? {
        guard let t = points[.thumbTip], let i = points[.indexTip] else { return nil }
        return CGPoint(x: (t.x + i.x) / 2, y: (t.y + i.y) / 2)
    }
}
