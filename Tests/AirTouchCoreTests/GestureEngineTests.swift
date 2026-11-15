import CoreGraphics
import XCTest
@testable import AirTouchCore

/// Builds synthetic hands (fingers pointing up, palm facing the camera).
enum FakeHand {
    enum Finger { case extended, curled }

    static func make(
        at c: CGPoint = CGPoint(x: 0.5, y: 0.55),
        index: Finger = .extended,
        middle: Finger = .extended,
        ring: Finger = .extended,
        little: Finger = .extended,
        thumbOut: Bool = true,
        pinchIndex: Bool = false,
        pinchMiddle: Bool = false,
        pinchRing: Bool = false
    ) -> Hand {
        var p: [Joint: CGPoint] = [:]
        p[.wrist] = CGPoint(x: c.x, y: c.y + 0.15)

        func finger(_ dx: CGFloat, _ state: Finger, _ mcp: Joint, _ pip: Joint, _ dip: Joint, _ tip: Joint) {
            let base = CGPoint(x: c.x + dx, y: c.y)
            p[mcp] = base
            switch state {
            case .extended:
                p[pip] = CGPoint(x: base.x, y: base.y - 0.06)
                p[dip] = CGPoint(x: base.x, y: base.y - 0.10)
                p[tip] = CGPoint(x: base.x, y: base.y - 0.13)
            case .curled:
                p[pip] = CGPoint(x: base.x, y: base.y - 0.04)
                p[dip] = CGPoint(x: base.x, y: base.y - 0.02)
                p[tip] = CGPoint(x: base.x, y: base.y + 0.02)
            }
        }
        finger(-0.045, index, .indexMCP, .indexPIP, .indexDIP, .indexTip)
        finger(-0.015, middle, .middleMCP, .middlePIP, .middleDIP, .middleTip)
        finger(0.015, ring, .ringMCP, .ringPIP, .ringDIP, .ringTip)
        finger(0.045, little, .littleMCP, .littlePIP, .littleDIP, .littleTip)

        p[.thumbCMC] = CGPoint(x: c.x - 0.05, y: c.y + 0.11)
        p[.thumbMP] = CGPoint(x: c.x - 0.09, y: c.y + 0.07)
        p[.thumbIP] = CGPoint(x: c.x - 0.12, y: c.y + 0.04)
        p[.thumbTip] = thumbOut
            ? CGPoint(x: c.x - 0.17, y: c.y + 0.01)
            : CGPoint(x: c.x - 0.02, y: c.y + 0.03)
        if pinchIndex { p[.thumbTip] = p[.indexTip] }
        if pinchMiddle { p[.thumbTip] = p[.middleTip] }
        if pinchRing { p[.thumbTip] = p[.ringTip] }

        return Hand(points: p, aspect: 1)
    }

    static func palm(at c: CGPoint = CGPoint(x: 0.5, y: 0.55)) -> Hand { make(at: c) }
    static func point(at c: CGPoint = CGPoint(x: 0.5, y: 0.55)) -> Hand {
        make(at: c, middle: .curled, ring: .curled, little: .curled, thumbOut: false)
    }
    static func pinch(at c: CGPoint = CGPoint(x: 0.5, y: 0.55)) -> Hand {
        make(at: c, ring: .curled, little: .curled, pinchIndex: true)
    }
    static func fist(at c: CGPoint = CGPoint(x: 0.5, y: 0.55)) -> Hand {
        make(at: c, index: .curled, middle: .curled, ring: .curled, little: .curled, thumbOut: false)
    }
    static func victory(at c: CGPoint = CGPoint(x: 0.5, y: 0.55)) -> Hand {
        make(at: c, ring: .curled, little: .curled, thumbOut: false)
    }
    static func ringPinch(at c: CGPoint = CGPoint(x: 0.5, y: 0.55)) -> Hand {
        make(at: c, little: .curled, pinchRing: true)
    }
    static func threeFingers(at c: CGPoint = CGPoint(x: 0.5, y: 0.55)) -> Hand {
        make(at: c, little: .curled, thumbOut: false)
    }
    static func shaka(at c: CGPoint = CGPoint(x: 0.5, y: 0.55)) -> Hand {
        make(at: c, index: .curled, middle: .curled, ring: .curled, little: .extended, thumbOut: true)
    }
}

final class PoseClassifierTests: XCTestCase {
    let classifier = PoseClassifier()

    func testPoses() {
        XCTAssertEqual(classifier.classify(FakeHand.palm()), .openPalm)
        XCTAssertEqual(classifier.classify(FakeHand.fist()), .fist)
        XCTAssertEqual(classifier.classify(FakeHand.victory()), .victory)
        XCTAssertEqual(classifier.classify(FakeHand.shaka()), .shaka)
        XCTAssertEqual(classifier.classify(FakeHand.pinch()), .pinch)
        XCTAssertEqual(classifier.classify(FakeHand.point()), .neutral)
        XCTAssertEqual(classifier.classify(FakeHand.make(pinchMiddle: true)), .middlePinch)
    }
}

final class GestureEngineTests: XCTestCase {
    var engine: GestureEngine!
    var t = 0.0
    let dt = 1.0 / 30.0

    override func setUp() {
        engine = GestureEngine()
        t = 0
    }

    /// Feeds the same hand for `seconds`, returning every action emitted.
    @discardableResult
    func feed(_ hand: Hand?, for seconds: Double) -> [GestureAction] {
        var actions: [GestureAction] = []
        let end = t + seconds
        while t < end {
            actions += engine.process(hands: hand.map { [$0] } ?? [], time: t)
            t += dt
        }
        return actions
    }

    func engage() {
        let actions = feed(FakeHand.palm(), for: 0.8)
        XCTAssertTrue(actions.contains(.engaged))
    }

    func testDoesNothingUntilPalmShown() {
        let actions = feed(FakeHand.point(), for: 1)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(engine.snapshot.engaged)
    }

    func testRingPinchTapPlaysPause() {
        engage()
        feed(FakeHand.point(), for: 0.3)
        let actions = feed(FakeHand.ringPinch(), for: 0.2) + feed(FakeHand.point(), for: 0.2)
        XCTAssertTrue(actions.contains(.playPause))
    }

    func testRingPinchHeldAndLiftedChangesVolume() {
        engage()
        feed(FakeHand.point(), for: 0.3)
        var actions: [GestureAction] = []
        for step in 0..<20 {
            let y = 0.55 - Double(step) * 0.01
            actions += engine.process(hands: [FakeHand.ringPinch(at: CGPoint(x: 0.5, y: y))], time: t)
            t += dt
        }
        XCTAssertTrue(actions.contains(.volume(.up)))
        XCTAssertFalse(actions.contains(.playPause))
    }

    func testShakaFlickNavigatesInsteadOfOpeningTheApp() {
        engage()
        feed(FakeHand.point(), for: 0.7)
        var actions: [GestureAction] = []
        for step in 0..<10 {
            let x = 0.42 + Double(step) * 0.025
            actions += engine.process(hands: [FakeHand.shaka(at: CGPoint(x: x, y: 0.55))], time: t)
            t += dt
        }
        XCTAssertTrue(actions.contains(.navigate(.forward)))
        XCTAssertFalse(actions.contains(.shortcut))
    }

    func testThreeFingersTurnDrawModeOnAndPinchDrawsInsteadOfClicking() {
        engage()
        feed(FakeHand.point(), for: 0.7)
        let turnedOn = feed(FakeHand.threeFingers(), for: 0.8)
        XCTAssertTrue(turnedOn.contains(.toggleDraw(true)))

        let drawn = feed(FakeHand.point(), for: 0.2) + feed(FakeHand.pinch(), for: 0.2)
        XCTAssertTrue(drawn.contains { if case .drawPoint = $0 { return true } else { return false } })
        XCTAssertFalse(drawn.contains { if case .mouseDown = $0 { return true } else { return false } })
    }

    func testScreenEdgesAreReachedBeforeTheHandLeavesTheZone() {
        engage()
        let config = engine.config
        let halfHeight = config.zoneSize.height / 2

        // Nine tenths of the way down the zone, so the hand is still comfortably framed.
        let low = config.zoneCenter.y + halfHeight * 0.9
        feed(FakeHand.point(at: CGPoint(x: 0.5, y: low)), for: 1.0)
        XCTAssertEqual(Double(engine.snapshot.pointer?.y ?? 0), 1.0, accuracy: 0.01)

        let high = config.zoneCenter.y - halfHeight * 0.9
        feed(FakeHand.point(at: CGPoint(x: 0.5, y: high)), for: 1.0)
        XCTAssertEqual(Double(engine.snapshot.pointer?.y ?? 1), 0.0, accuracy: 0.01)
    }

    func testPinchClicks() {
        engage()
        feed(FakeHand.point(), for: 0.3)
        let actions = feed(FakeHand.pinch(), for: 0.2) + feed(FakeHand.point(), for: 0.2)
        XCTAssertTrue(actions.contains { if case .mouseDown(_, 1) = $0 { return true } else { return false } })
        XCTAssertTrue(actions.contains { if case .mouseUp(_, 1) = $0 { return true } else { return false } })
    }

    func testPalmSwipeLeft() {
        engage()
        feed(FakeHand.palm(), for: 0.5) // wait out the post-engage cooldown
        var actions: [GestureAction] = []
        // Move the open hand left quickly.
        for i in 0..<8 {
            let x = 0.5 - Double(i) * 0.04
            actions += engine.process(hands: [FakeHand.palm(at: CGPoint(x: x, y: 0.55))], time: t)
            t += dt
        }
        XCTAssertTrue(actions.contains(.swipe(.left)))
    }

    func testFistPullDownMinimizes() {
        engage()
        feed(FakeHand.point(), for: 0.3)
        var actions = feed(FakeHand.fist(), for: 0.1)
        for i in 0..<8 {
            let y = 0.55 + Double(i) * 0.03
            actions += engine.process(hands: [FakeHand.fist(at: CGPoint(x: 0.5, y: y))], time: t)
            t += dt
        }
        XCTAssertTrue(actions.contains(.minimize))
    }

    func testFistHoldPauses() {
        engage()
        feed(FakeHand.point(), for: 0.3)
        let actions = feed(FakeHand.fist(), for: 1.5)
        XCTAssertTrue(actions.contains(.paused))
        XCTAssertFalse(engine.snapshot.engaged)
    }

    func testHandLeavingPauses() {
        engage()
        let actions = feed(nil, for: 2)
        XCTAssertTrue(actions.contains(.paused))
    }

    func testVictoryScrolls() {
        engage()
        feed(FakeHand.victory(), for: 0.2)
        var actions: [GestureAction] = []
        for i in 0..<6 {
            let y = 0.55 + Double(i) * 0.01
            actions += engine.process(hands: [FakeHand.victory(at: CGPoint(x: 0.5, y: y))], time: t)
            t += dt
        }
        XCTAssertTrue(actions.contains { if case .scroll(_, let dy) = $0 { return dy > 0 } else { return false } })
    }

    func testShakaFiresOnce() {
        engage()
        feed(FakeHand.point(), for: 0.2)
        let actions = feed(FakeHand.shaka(), for: 1.5)
        XCTAssertEqual(actions.filter { $0 == .shortcut }.count, 1)
    }
}

final class OneEuroFilterTests: XCTestCase {
    func testConvergesToConstantInput() {
        var filter = OneEuroFilter()
        var value = 0.0
        _ = filter.filter(0, time: 0)
        for i in 1...60 { value = filter.filter(1, time: Double(i) / 30) }
        XCTAssertEqual(value, 1, accuracy: 0.01)
    }
}
