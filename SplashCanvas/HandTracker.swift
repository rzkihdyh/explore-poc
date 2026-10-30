import AVFoundation
import Vision
import CoreGraphics

/// The hand joints the app cares about.
nonisolated enum HandJoint: Int, CaseIterable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexTip
    case middleMCP, middlePIP, middleTip
    case ringMCP, ringPIP, ringTip
    case littleMCP, littlePIP, littleTip

    var visionName: VNHumanHandPoseObservation.JointName {
        switch self {
        case .wrist: return .wrist
        case .thumbCMC: return .thumbCMC
        case .thumbMP: return .thumbMP
        case .thumbIP: return .thumbIP
        case .thumbTip: return .thumbTip
        case .indexMCP: return .indexMCP
        case .indexPIP: return .indexPIP
        case .indexTip: return .indexTip
        case .middleMCP: return .middleMCP
        case .middlePIP: return .middlePIP
        case .middleTip: return .middleTip
        case .ringMCP: return .ringMCP
        case .ringPIP: return .ringPIP
        case .ringTip: return .ringTip
        case .littleMCP: return .littleMCP
        case .littlePIP: return .littlePIP
        case .littleTip: return .littleTip
        }
    }
}

/// One detected hand. Joints are in the upright, mirrored camera image:
/// x grows to the right, y grows downward, both in 0...1.
nonisolated struct HandObservation: Sendable {
    var joints: [SIMD2<Float>?]
    var confidence: Float

    subscript(_ joint: HandJoint) -> SIMD2<Float>? { joints[joint.rawValue] }
}

nonisolated struct HandFrame: Sendable {
    var hands: [HandObservation]
    /// Width / height of the (portrait) camera image.
    var imageAspect: Float
}

/// Runs the front camera and Vision's hand-pose detector, entirely on device.
nonisolated final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Status: Sendable { case running, denied, unavailable }

    /// If strokes move the wrong way on your device, adjust these two values.
    #if os(macOS)
    static let rotationAngle: CGFloat = 0    // Mac cameras are already landscape-upright
    #else
    static let rotationAngle: CGFloat = 90   // portrait
    #endif
    static let mirrored = true                // behave like a mirror

    let session = AVCaptureSession()
    /// Set before calling `start`. Delivered on the main actor once per processed frame.
    var onFrame: (@MainActor @Sendable (HandFrame) -> Void)?

    private let sessionQueue = DispatchQueue(label: "splash.camera.session")
    private let videoQueue = DispatchQueue(label: "splash.camera.video", qos: .userInteractive)
    private var configured = false
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()

    func start(completion: @escaping @MainActor @Sendable (Status) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run(completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.run(completion)
                } else {
                    Task { @MainActor in completion(.denied) }
                }
            }
        default:
            Task { @MainActor in completion(.denied) }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func run(_ completion: @escaping @MainActor @Sendable (Status) -> Void) {
        sessionQueue.async {
            let ok = self.configureIfNeeded()
            if ok && !self.session.isRunning { self.session.startRunning() }
            Task { @MainActor in completion(ok ? .running : .unavailable) }
        }
    }

    private func configureIfNeeded() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addOutput(output)

        // Upright, mirrored buffers: Vision coordinates then map straight onto the screen.
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(Self.rotationAngle) {
                connection.videoRotationAngle = Self.rotationAngle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = Self.mirrored
            }
        }
        preferHighFrameRate(device)
        session.commitConfiguration()
        configured = true
        return true
    }

    /// Tracking at 60 fps roughly halves input latency. Falls back to the default 30 fps.
    private func preferHighFrameRate(_ device: AVCaptureDevice) {
        let candidates = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width >= 640 && size.width <= 1280
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 60 }
        }
        guard let best = candidates.min(by: {
            CMVideoFormatDescriptionGetDimensions($0.formatDescription).width <
                CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
        }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
            device.unlockForConfiguration()
        } catch {
            // Keep the default format.
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        var hands: [HandObservation] = []
        do {
            try handler.perform([request])
            for observation in request.results ?? [] {
                guard let points = try? observation.recognizedPoints(.all) else { continue }
                var joints = [SIMD2<Float>?](repeating: nil, count: HandJoint.allCases.count)
                for joint in HandJoint.allCases {
                    guard let point = points[joint.visionName], point.confidence > 0.3 else { continue }
                    // Vision uses a bottom-left origin; flip to top-left.
                    joints[joint.rawValue] = SIMD2(Float(point.location.x), Float(1 - point.location.y))
                }
                hands.append(HandObservation(joints: joints, confidence: observation.confidence))
            }
        } catch {
            // A failed frame is simply skipped.
        }

        let frame = HandFrame(hands: hands, imageAspect: Float(width) / Float(max(height, 1)))
        let callback = onFrame
        Task { @MainActor in callback?(frame) }
    }
}
