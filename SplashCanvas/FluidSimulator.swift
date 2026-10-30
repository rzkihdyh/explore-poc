import Metal
import CoreGraphics
import simd

/// Two textures that swap roles every pass (read from one, write the other).
final class TexturePair {
    private(set) var read: MTLTexture
    private(set) var write: MTLTexture

    init(read: MTLTexture, write: MTLTexture) {
        self.read = read
        self.write = write
    }

    func swap() { (read, write) = (write, read) }
}

struct GridSize: Equatable {
    var width = 0
    var height = 0
}

/// GPU stable-fluids solver (Stam) with vorticity confinement, running entirely in Metal compute.
/// Velocity lives on a coarse grid; paint ("dye") is advected on a finer grid.
final class FluidSimulator {
    struct Settings: Equatable {
        var velocityDissipation: Float
        var dyeDissipation: Float
        var pressureDecay: Float
        var curl: Float
        var pressureIterations: Int

        static let paper = Settings(velocityDissipation: 0.6, dyeDissipation: 0.01, pressureDecay: 0.8,
                                    curl: 20, pressureIterations: 20)
        static let night = Settings(velocityDissipation: 0.4, dyeDissipation: 0.25, pressureDecay: 0.8,
                                    curl: 30, pressureIterations: 20)
    }

    private(set) var settings = Settings.paper
    private let device: MTLDevice

    private let clearPSO: MTLComputePipelineState
    private let splatVelocityPSO: MTLComputePipelineState
    private let splatDyePSO: MTLComputePipelineState
    private let curlPSO: MTLComputePipelineState
    private let vorticityPSO: MTLComputePipelineState
    private let divergencePSO: MTLComputePipelineState
    private let scalePSO: MTLComputePipelineState
    private let jacobiPSO: MTLComputePipelineState
    private let gradientPSO: MTLComputePipelineState
    private let advectPSO: MTLComputePipelineState

    private(set) var simSize = GridSize()
    private(set) var dyeSize = GridSize()
    private var velocity: TexturePair?
    private var dye: TexturePair?
    private var pressure: TexturePair?
    private var divergence: MTLTexture?
    private var curl: MTLTexture?
    private var needsClear = true
    private var pending: [Splat] = []
    private var washLevel: Float = 0

    /// The latest paint texture (with mipmaps), ready to display.
    var dyeTexture: MTLTexture? { dye?.read }

    init?(device: MTLDevice, library: MTLLibrary) {
        func make(_ name: String) -> MTLComputePipelineState? {
            guard let function = library.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: function)
        }
        guard let clear = make("clearTexture"),
              let splatVelocity = make("splatVelocity"),
              let splatDye = make("splatDye"),
              let curl = make("computeCurl"),
              let vorticity = make("applyVorticity"),
              let divergence = make("computeDivergence"),
              let scale = make("scaleTexture"),
              let jacobi = make("pressureJacobi"),
              let gradient = make("subtractGradient"),
              let advect = make("advect") else { return nil }
        self.device = device
        clearPSO = clear
        splatVelocityPSO = splatVelocity
        splatDyePSO = splatDye
        curlPSO = curl
        vorticityPSO = vorticity
        divergencePSO = divergence
        scalePSO = scale
        jacobiPSO = jacobi
        gradientPSO = gradient
        advectPSO = advect
    }

    func apply(_ newSettings: Settings) {
        if newSettings != settings { settings = newSettings }
    }

    func enqueue(_ splats: [Splat]) {
        pending.append(contentsOf: splats)
    }

    /// Paint dissolves away over about a second.
    func wash() { washLevel = 1 }

    // MARK: - Resources

    func resize(to drawableSize: CGSize) {
        let width = Float(max(drawableSize.width, 1))
        let height = Float(max(drawableSize.height, 1))
        let shortSide = min(width, height)
        func grid(_ resolution: Float) -> GridSize {
            let s = resolution / shortSide
            return GridSize(width: max(Int((width * s).rounded()), 8), height: max(Int((height * s).rounded()), 8))
        }
        let newSim = grid(Tuning.simResolution)
        let newDye = grid(min(max(shortSide * 0.5, Tuning.dyeMinResolution), Tuning.dyeMaxResolution))
        guard newSim != simSize || newDye != dyeSize else { return }

        guard let v0 = makeTexture(.rg16Float, newSim), let v1 = makeTexture(.rg16Float, newSim),
              let p0 = makeTexture(.r16Float, newSim), let p1 = makeTexture(.r16Float, newSim),
              let div = makeTexture(.r16Float, newSim), let crl = makeTexture(.r16Float, newSim),
              let d0 = makeTexture(.rgba16Float, newDye, mipmapped: true),
              let d1 = makeTexture(.rgba16Float, newDye, mipmapped: true) else { return }
        velocity = TexturePair(read: v0, write: v1)
        pressure = TexturePair(read: p0, write: p1)
        dye = TexturePair(read: d0, write: d1)
        divergence = div
        curl = crl
        simSize = newSim
        dyeSize = newDye
        needsClear = true
    }

    private func makeTexture(_ format: MTLPixelFormat, _ size: GridSize, mipmapped: Bool = false) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.width,
                                                                  height: size.height, mipmapped: mipmapped)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    // MARK: - Step

    func step(dt: Float, commandBuffer: MTLCommandBuffer) {
        guard let velocity, let dye, let pressure, let divergence, let curl,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        if needsClear {
            for texture in [velocity.read, velocity.write, dye.read, dye.write,
                            pressure.read, pressure.write, divergence, curl] {
                dispatch(encoder, clearPSO, GridSize(width: texture.width, height: texture.height), [texture])
            }
            needsClear = false
        }

        // 1. Brush input.
        if !pending.isEmpty {
            let cells = SIMD2<Float>(Float(simSize.width), Float(simSize.height))
            let batch = pending.map { splat -> Splat in
                var s = splat
                s.velocity *= cells   // UV/s → grid cells/s
                return s
            }
            pending.removeAll(keepingCapacity: true)
            var start = 0
            while start < batch.count {
                let end = min(start + 60, batch.count)   // 60 × 64 bytes stays under setBytes' 4 KB limit
                let chunk = Array(batch[start..<end])
                var count = UInt32(chunk.count)
                chunk.withUnsafeBytes { raw in
                    encoder.setBytes(raw.baseAddress!, length: raw.count, index: 0)
                }
                encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
                dispatch(encoder, splatVelocityPSO, simSize, [velocity.read, velocity.write])
                velocity.swap()
                dispatch(encoder, splatDyePSO, dyeSize, [dye.read, dye.write])
                dye.swap()
                start = end
            }
        }

        // 2. Vorticity confinement keeps swirls crisp.
        dispatch(encoder, curlPSO, simSize, [velocity.read, curl])
        var vorticity = VorticityParams(dt: dt, strength: settings.curl)
        encoder.setBytes(&vorticity, length: MemoryLayout<VorticityParams>.stride, index: 0)
        dispatch(encoder, vorticityPSO, simSize, [velocity.read, curl, velocity.write])
        velocity.swap()

        // 3. Projection: make the velocity field divergence-free.
        dispatch(encoder, divergencePSO, simSize, [velocity.read, divergence])
        var decay = settings.pressureDecay
        encoder.setBytes(&decay, length: MemoryLayout<Float>.size, index: 0)
        dispatch(encoder, scalePSO, simSize, [pressure.read, pressure.write])
        pressure.swap()
        for _ in 0..<settings.pressureIterations {
            dispatch(encoder, jacobiPSO, simSize, [pressure.read, divergence, pressure.write])
            pressure.swap()
        }
        dispatch(encoder, gradientPSO, simSize, [pressure.read, velocity.read, velocity.write])
        velocity.swap()

        // 4. Advection.
        let texel = SIMD2<Float>(1 / Float(simSize.width), 1 / Float(simSize.height))
        var advectVelocity = AdvectParams(dt: dt, dissipation: settings.velocityDissipation, velocityTexel: texel)
        encoder.setBytes(&advectVelocity, length: MemoryLayout<AdvectParams>.stride, index: 0)
        dispatch(encoder, advectPSO, simSize, [velocity.read, velocity.read, velocity.write])
        velocity.swap()

        var advectDye = AdvectParams(dt: dt, dissipation: settings.dyeDissipation + washLevel * 3.5,
                                     velocityTexel: texel)
        encoder.setBytes(&advectDye, length: MemoryLayout<AdvectParams>.stride, index: 0)
        dispatch(encoder, advectPSO, dyeSize, [velocity.read, dye.read, dye.write])
        dye.swap()
        encoder.endEncoding()

        // 5. Mip chain for the night-mode bloom.
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: dye.read)
            blit.endEncoding()
        }

        washLevel = max(0, washLevel - dt * 0.8)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState,
                          _ size: GridSize, _ textures: [MTLTexture]) {
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        let width = pipeline.threadExecutionWidth
        let height = max(1, min(pipeline.maxTotalThreadsPerThreadgroup / width, 16))
        encoder.dispatchThreads(MTLSize(width: size.width, height: size.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
    }
}
