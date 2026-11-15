import AirTouchCore
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

struct FrameResult {
    var hands: [Hand]
    var time: Double
    /// Small mirrored camera image, only produced while the AirTouch window is open.
    var preview: CGImage?
}

/// Camera → Vision → results on the main thread. Runs detection on the camera queue.
final class TrackingPipeline {
    private let camera = CameraManager()
    private let detector = HandDetector()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()

    private var _mirror = true
    private var _previewEnabled = false

    // Only touched on the camera queue.
    private var frameIndex = 0
    private var lastHandTime: Double = 0

    /// Delivered on the main actor.
    var onResult: (@MainActor (FrameResult) -> Void)?

    var mirror: Bool {
        get { locked { _mirror } }
        set { locked { _mirror = newValue } }
    }

    var previewEnabled: Bool {
        get { locked { _previewEnabled } }
        set { locked { _previewEnabled = newValue } }
    }

    func start() throws {
        camera.onFrame = { [weak self] buffer, time in
            self?.process(buffer, time: time)
        }
        try camera.start()
    }

    func stop() {
        camera.stop()
    }

    private func process(_ buffer: CVPixelBuffer, time: Double) {
        frameIndex += 1

        // Battery saver: no hand for 3s → only look at every 3rd frame (~10 fps).
        let idle = time - lastHandTime > 3
        if idle, frameIndex % 3 != 0 { return }

        let mirror = self.mirror
        detector.mirror = mirror
        let hands = detector.detect(in: buffer)
        if !hands.isEmpty { lastHandTime = time }

        var preview: CGImage?
        if previewEnabled, frameIndex % 2 == 0 {
            preview = makePreview(buffer, mirror: mirror)
        }

        let result = FrameResult(hands: hands, time: time, preview: preview)
        guard let handler = onResult else { return }
        Task { @MainActor in handler(result) }
    }

    private func makePreview(_ buffer: CVPixelBuffer, mirror: Bool) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer)
        if mirror { image = image.oriented(.upMirrored) }
        image = image.transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        return ciContext.createCGImage(image, from: image.extent)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
