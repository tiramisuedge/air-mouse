import CoreGraphics
import Foundation

/// The 1€ filter (Casiez et al., 2012): heavy smoothing when the hand is still
/// (kills jitter), light smoothing when it moves fast (kills lag).
public struct OneEuroFilter {
    /// Lower = smoother when still, but laggier.
    public var minCutoff: Double
    /// Higher = less lag during fast movement.
    public var beta: Double
    public var derivativeCutoff: Double

    private var lastValue: Double?
    private var lastDerivative: Double = 0
    private var lastTime: Double?

    public init(minCutoff: Double = 1.2, beta: Double = 6.0, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    public mutating func reset() {
        lastValue = nil
        lastTime = nil
        lastDerivative = 0
    }

    public mutating func filter(_ value: Double, time: Double) -> Double {
        guard let prev = lastValue, let prevTime = lastTime else {
            lastValue = value
            lastTime = time
            return value
        }
        let dt = time - prevTime
        guard dt > 0 else { return prev }

        let derivative = (value - prev) / dt
        let aD = OneEuroFilter.alpha(cutoff: derivativeCutoff, dt: dt)
        let smoothedDerivative = aD * derivative + (1 - aD) * lastDerivative

        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let a = OneEuroFilter.alpha(cutoff: cutoff, dt: dt)
        let result = a * value + (1 - a) * prev

        lastValue = result
        lastDerivative = smoothedDerivative
        lastTime = time
        return result
    }

    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}

/// A 1€ filter for 2D points.
public struct PointFilter {
    private var fx = OneEuroFilter()
    private var fy = OneEuroFilter()

    public init() {}

    public mutating func setParameters(minCutoff: Double, beta: Double) {
        fx.minCutoff = minCutoff
        fy.minCutoff = minCutoff
        fx.beta = beta
        fy.beta = beta
    }

    public mutating func reset() {
        fx.reset()
        fy.reset()
    }

    public mutating func filter(_ p: CGPoint, time: Double) -> CGPoint {
        CGPoint(x: fx.filter(Double(p.x), time: time), y: fy.filter(Double(p.y), time: time))
    }
}
