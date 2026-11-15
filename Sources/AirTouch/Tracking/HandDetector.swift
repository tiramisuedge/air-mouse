import AirTouchCore
import CoreGraphics
import CoreVideo
import Vision

/// Runs Apple Vision's on-device hand pose model on a camera frame.
final class HandDetector {
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()

    /// Mirror x so the coordinates match what you see in a mirror.
    var mirror = true
    /// Landmarks below this confidence are dropped.
    var minimumConfidence: Float = 0.3

    func detect(in pixelBuffer: CVPixelBuffer) -> [Hand] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let observations = request.results else { return [] }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let aspect = height > 0 ? Double(width) / Double(height) : 16.0 / 9.0

        return observations.compactMap { observation in
            guard let recognized = try? observation.recognizedPoints(.all) else { return nil }
            var points: [Joint: CGPoint] = [:]
            for (name, point) in recognized where point.confidence >= minimumConfidence {
                guard let joint = HandDetector.jointMap[name] else { continue }
                // Vision: origin bottom-left. AirTouch: origin top-left, mirrored.
                let x = mirror ? 1 - point.location.x : point.location.x
                points[joint] = CGPoint(x: x, y: 1 - point.location.y)
            }
            return points.count >= 8 ? Hand(points: points, aspect: aspect) : nil
        }
    }

    static let jointMap: [VNHumanHandPoseObservation.JointName: Joint] = [
        .wrist: .wrist,
        .thumbCMC: .thumbCMC, .thumbMP: .thumbMP, .thumbIP: .thumbIP, .thumbTip: .thumbTip,
        .indexMCP: .indexMCP, .indexPIP: .indexPIP, .indexDIP: .indexDIP, .indexTip: .indexTip,
        .middleMCP: .middleMCP, .middlePIP: .middlePIP, .middleDIP: .middleDIP, .middleTip: .middleTip,
        .ringMCP: .ringMCP, .ringPIP: .ringPIP, .ringDIP: .ringDIP, .ringTip: .ringTip,
        .littleMCP: .littleMCP, .littlePIP: .littlePIP, .littleDIP: .littleDIP, .littleTip: .littleTip,
    ]
}
