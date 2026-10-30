import MetalKit
import QuartzCore

/// Drives the frame loop: hands → splats → fluid step → display, all on the GPU.
final class CanvasRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fluid: FluidSimulator
    private let displayPipeline: MTLRenderPipelineState
    private let studio: Studio
    private var lastTime: CFTimeInterval = 0
    private let startTime = CACurrentMediaTime()
    private var displayMode: Float = 0

    init?(view: MTKView, studio: Studio) {
        guard let device = view.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let fluid = FluidSimulator(device: device, library: library) else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "displayFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        self.device = device
        self.queue = queue
        self.fluid = fluid
        self.displayPipeline = pipeline
        self.studio = studio
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        fluid.resize(to: size)
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(lastTime == 0 ? 1.0 / 60.0 : min(max(now - lastTime, 1.0 / 240.0), 1.0 / 20.0))
        lastTime = now

        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        fluid.resize(to: size)

        let frame = studio.advance(dt: dt, now: now)
        let night = studio.style == .night
        fluid.apply(night ? .night : .paper)
        if frame.wash { fluid.wash() }
        fluid.enqueue(frame.splats)
        displayMode += ((night ? 1 : 0) - displayMode) * min(1, dt * 5)

        guard let commandBuffer = queue.makeCommandBuffer() else { return }
        fluid.step(dt: dt, commandBuffer: commandBuffer)

        if let dye = fluid.dyeTexture,
           let pass = view.currentRenderPassDescriptor,
           let drawable = view.currentDrawable,
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            encodeDisplay(encoder, dye: dye, size: size, cursors: frame.cursors, time: Float(now - startTime))
            encoder.endEncoding()
            if studio.snapshotRequested {
                studio.snapshotRequested = false
                encodeSnapshot(commandBuffer, dye: dye, size: size)
            }
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    private func encodeDisplay(_ encoder: MTLRenderCommandEncoder, dye: MTLTexture, size: CGSize,
                               cursors: [CursorMark], time: Float) {
        var marks = Array(cursors.prefix(16))
        let count = UInt32(marks.count)
        if marks.isEmpty {
            marks.append(CursorMark(position: .zero, radius: 0, progress: 0, color: .zero, style: 0, alpha: 0))
        }
        var uniforms = DisplayUniforms(viewSize: SIMD2(Float(size.width), Float(size.height)),
                                       dyeTexel: SIMD2(1 / Float(dye.width), 1 / Float(dye.height)),
                                       mode: displayMode, time: time, cursorCount: count)
        encoder.setRenderPipelineState(displayPipeline)
        encoder.setFragmentTexture(dye, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<DisplayUniforms>.stride, index: 0)
        marks.withUnsafeBytes { raw in
            encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// Renders the painting (without cursors) into a CPU-readable texture for sharing.
    private func encodeSnapshot(_ commandBuffer: MTLCommandBuffer, dye: MTLTexture, size: CGSize) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: Int(size.width), height: Int(size.height),
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        #if os(macOS)
        descriptor.storageMode = .managed   // CPU-readable on Intel and Apple silicon Macs
        #else
        descriptor.storageMode = .shared
        #endif
        guard let target = device.makeTexture(descriptor: descriptor) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encodeDisplay(encoder, dye: dye, size: size, cursors: [], time: 0)
        encoder.endEncoding()
        #if os(macOS)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        #endif

        let studio = self.studio
        commandBuffer.addCompletedHandler(SnapshotReader.handler(for: target) { image in
            Task { @MainActor in studio.deliverSnapshot(image) }
        })
    }
}

/// Runs off the main thread when the GPU finishes.
nonisolated enum SnapshotReader {
    static func handler(for texture: MTLTexture,
                        completion: @escaping @Sendable (CGImage?) -> Void) -> MTLCommandBufferHandler {
        return { _ in completion(makeImage(from: texture)) }
    }

    static func makeImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
