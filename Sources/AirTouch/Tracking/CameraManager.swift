import AVFoundation
import CoreVideo

enum CameraError: LocalizedError {
    case noCamera
    case cannotUseCamera

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No built-in camera found."
        case .cannotUseCamera: return "The camera is busy or unavailable."
        }
    }
}

/// Streams frames from the Mac's built-in camera on a background queue.
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "airtouch.camera", qos: .userInteractive)
    private var configured = false

    /// Called on the camera queue for every frame: (pixels, timestamp in seconds).
    var onFrame: ((CVPixelBuffer, Double) -> Void)?

    func start() throws {
        if !configured {
            try configure()
            configured = true
        }
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() throws {
        guard let device = CameraManager.builtInCamera() else { throw CameraError.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotUseCamera }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw CameraError.cannotUseCamera }
        session.addOutput(output)
    }

    /// The MacBook's own FaceTime camera (ignores iPhone Continuity Camera / webcams).
    static func builtInCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        onFrame?(pixelBuffer, time)
    }
}
