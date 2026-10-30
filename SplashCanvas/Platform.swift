import SwiftUI
import MetalKit
import AVFoundation
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#else
import UIKit
#endif

// Everything that differs between iPhone/iPad and Mac lives here.

enum Platform {
    #if os(macOS)
    private static var awakeActivity: NSObjectProtocol?
    #endif

    /// Nobody touches the device while painting with hands — keep the display awake.
    static func keepAwake() {
        #if os(macOS)
        if awakeActivity == nil {
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Painting with hand gestures")
        }
        #else
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
    }

    static func openCameraSettings() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    #if os(macOS)
    static func savePNG(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Splash Canvas.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
    #endif

    static func configure(_ connection: AVCaptureConnection?) {
        guard let connection else { return }
        if connection.isVideoRotationAngleSupported(HandTracker.rotationAngle) {
            connection.videoRotationAngle = HandTracker.rotationAngle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = HandTracker.mirrored
        }
    }
}

extension View {
    /// Full-bleed, no system chrome where the platform allows it.
    @ViewBuilder
    func immersive() -> some View {
        #if os(iOS)
        self.statusBarHidden().persistentSystemOverlays(.hidden)
        #else
        self
        #endif
    }
}

/// Shows the share sheet for a finished snapshot (iOS). On Mac a save panel opens instead.
struct SnapshotSheet: ViewModifier {
    @Bindable var studio: Studio

    func body(content: Content) -> some View {
        #if os(iOS)
        content.sheet(item: $studio.snapshot) { snapshot in
            ShareSheet(items: [UIImage(cgImage: snapshot.cgImage)])
        }
        #else
        content
        #endif
    }
}

// MARK: - Metal canvas view

private func configureCanvas(_ view: CanvasMTKView, studio: Studio) {
    view.studio = studio
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = true
    view.preferredFramesPerSecond = 60
    view.isPaused = false
    view.enableSetNeedsDisplay = false
    view.clearColor = MTLClearColor(red: 0.97, green: 0.96, blue: 0.94, alpha: 1)
}

final class CanvasCoordinator {
    var renderer: CanvasRenderer?
}

#if os(macOS)

struct CanvasView: NSViewRepresentable {
    let studio: Studio

    func makeCoordinator() -> CanvasCoordinator { CanvasCoordinator() }

    func makeNSView(context: Context) -> CanvasMTKView {
        let view = CanvasMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        configureCanvas(view, studio: studio)
        context.coordinator.renderer = CanvasRenderer(view: view, studio: studio)
        view.delegate = context.coordinator.renderer
        return view
    }

    func updateNSView(_ nsView: CanvasMTKView, context: Context) {}
}

/// MTKView that reports its size to the studio and turns mouse drags into strokes.
final class CanvasMTKView: MTKView {
    weak var studio: Studio?

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        studio?.updateLayout(size: bounds.size, safeTop: safeAreaInsets.top, safeBottom: safeAreaInsets.bottom)
    }

    private func normalized(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        let y = isFlipped ? p.y / h : 1 - p.y / h
        return SIMD2(Float(p.x / w), Float(y))
    }

    override func mouseDown(with event: NSEvent) { studio?.touchBegan(at: normalized(event)) }
    override func mouseDragged(with event: NSEvent) { studio?.touchMoved(to: normalized(event)) }
    override func mouseUp(with event: NSEvent) { studio?.touchEnded() }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            layer = previewLayer
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            Platform.configure(previewLayer.connection)
        }
    }

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView(frame: .zero)
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {}
}

#else

struct CanvasView: UIViewRepresentable {
    let studio: Studio

    func makeCoordinator() -> CanvasCoordinator { CanvasCoordinator() }

    func makeUIView(context: Context) -> CanvasMTKView {
        let view = CanvasMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        configureCanvas(view, studio: studio)
        view.isMultipleTouchEnabled = false
        context.coordinator.renderer = CanvasRenderer(view: view, studio: studio)
        view.delegate = context.coordinator.renderer
        return view
    }

    func updateUIView(_ uiView: CanvasMTKView, context: Context) {}
}

/// MTKView that reports its size/safe area to the studio and forwards touches.
final class CanvasMTKView: MTKView {
    weak var studio: Studio?

    override func layoutSubviews() {
        super.layoutSubviews()
        studio?.updateLayout(size: bounds.size, safeTop: safeAreaInsets.top, safeBottom: safeAreaInsets.bottom)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    private func normalized(_ touches: Set<UITouch>) -> SIMD2<Float>? {
        guard let touch = touches.first else { return nil }
        let p = touch.location(in: self)
        return SIMD2(Float(p.x / max(bounds.width, 1)), Float(p.y / max(bounds.height, 1)))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let uv = normalized(touches) { studio?.touchBegan(at: uv) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let uv = normalized(touches) { studio?.touchMoved(to: uv) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        studio?.touchEnded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        studio?.touchEnded()
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            Platform.configure(previewLayer.connection)
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#endif
