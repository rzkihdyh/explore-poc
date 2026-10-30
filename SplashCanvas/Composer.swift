import AVFoundation
import QuartzCore
import simd

/// Owns the audio graph: synth → echo → hall reverb → speakers.
final class MusicEngine {
    private let engine = AVAudioEngine()
    private let echo = AVAudioUnitDelay()
    private let reverb = AVAudioUnitReverb()
    private var dsp: MusicDSP?
    private var muted = false
    private var lastRestartAttempt: Double = 0

    func start() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Plays even with the silent switch on; mixes with whatever else is playing.
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif

        if dsp == nil {
            let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            let sampleRate = hardwareRate > 0 ? hardwareRate : 48_000
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
            let dsp = MusicDSP(sampleRate: Float(sampleRate))
            dsp.setMuted(muted)
            let source = AVAudioSourceNode(format: format, renderBlock: dsp.makeRenderBlock())

            echo.delayTime = 0.375
            echo.feedback = 32
            echo.lowPassCutoff = 3200
            echo.wetDryMix = 16
            reverb.loadFactoryPreset(.cathedral)
            reverb.wetDryMix = 36

            engine.attach(source)
            engine.attach(echo)
            engine.attach(reverb)
            engine.connect(source, to: echo, format: format)
            engine.connect(echo, to: reverb, format: format)
            engine.connect(reverb, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.9
            self.dsp = dsp
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("Audio engine failed to start: \(error)")
            }
        }
    }

    func pause() {
        if engine.isRunning { engine.pause() }
    }

    func play(_ event: NoteEvent) {
        dsp?.trigger(event)
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        dsp?.setMuted(muted)
    }

    func setControls(energy: Float, stir: Float, swell: Float, brightness: Float, night: Bool, now: Double) {
        dsp?.setControls(energy: energy, stir: stir, swell: swell, brightness: brightness, night: night)
        // Route changes (headphones etc.) stop the engine; bring it back quietly.
        if dsp != nil && !engine.isRunning && now - lastRestartAttempt > 1 {
            lastRestartAttempt = now
            try? engine.start()
        }
    }
}

/// Turns painting into music. Everything is quantized to D major pentatonic,
/// so any movement sounds pleasant: higher on screen = higher pitch, left/right = stereo position,
/// faster = louder.
final class Composer {
    let engine = MusicEngine()
    var isMuted = false {
        didSet { engine.setMuted(isMuted) }
    }

    /// D major pentatonic, D4 … E6.
    private static let scale: [Float] = [62, 64, 66, 69, 71, 74, 76, 78, 81, 83, 86, 88]

    private var travel: [Int: Float] = [:]
    private var lastNote: [Int: Double] = [:]
    private var energy: Float = 0
    private var frameStir: Float = 0
    private var frameSwell: Float = 0

    func start() { engine.start() }
    func pause() { engine.pause() }

    private func degree(forHeight y: Float) -> Int {
        let count = Self.scale.count
        return min(max(Int((1 - y) * Float(count)), 0), count - 1)
    }

    private func frequency(_ degree: Int) -> Float {
        let count = Self.scale.count
        let octave = degree >= 0 ? degree / count : (degree - count + 1) / count
        let index = degree - octave * count
        return MusicDSP.hz(Self.scale[index] + Float(octave * 12))
    }

    private func pan(_ uv: SIMD2<Float>) -> Float { (uv.x * 2 - 1) * 0.8 }

    /// Index-finger painting: a note every time the brush travels a little way, like running a finger over a harp.
    func paint(hand id: Int, at uv: SIMD2<Float>, distance: Float, speed: Float, now: Double, night: Bool) {
        energy = min(1, energy + distance * 0.6)
        let step: Float = 0.085
        let total = min((travel[id] ?? 0) + distance, step * 2)
        travel[id] = total
        guard total >= step, now - (lastNote[id] ?? 0) >= 0.075 else { return }
        travel[id] = 0
        lastNote[id] = now
        let velocity = 0.3 + 0.7 * smoothStep(0.2, 3.0, speed)
        engine.play(NoteEvent(frequency: frequency(degree(forHeight: uv.y)), velocity: velocity,
                              pan: pan(uv), delay: 0, bell: night))
    }

    /// Open hand: a soft three-note strum while the hand moves.
    func strum(hand id: Int, at uv: SIMD2<Float>, distance: Float, speed: Float, now: Double, night: Bool) {
        energy = min(1, energy + distance * 0.5)
        let total = min((travel[id] ?? 0) + distance, 0.4)
        travel[id] = total
        guard total >= 0.14, now - (lastNote[id] ?? 0) >= 0.22 else { return }
        travel[id] = 0
        lastNote[id] = now
        let root = max(degree(forHeight: uv.y) - 4, 0)
        let velocity = 0.25 + 0.5 * smoothStep(0.2, 3.0, speed)
        for (k, offset) in [0, 2, 4].enumerated() {
            engine.play(NoteEvent(frequency: frequency(root + offset), velocity: velocity * (1 - Float(k) * 0.12),
                                  pan: pan(uv) + Float(k - 1) * 0.25, delay: Float(k) * 0.035, bell: night))
        }
    }

    /// Flick: a sparkling run up the scale.
    func splash(at uv: SIMD2<Float>, speed: Float) {
        energy = min(1, energy + 0.25)
        let start = max(degree(forHeight: uv.y), 4)
        let count = 5 + Int(smoothStep(3, 7, speed) * 3)
        for k in 0..<count {
            engine.play(NoteEvent(frequency: frequency(start + k), velocity: 0.75 - Float(k) * 0.06,
                                  pan: pan(uv) + Float.random(in: -0.3...0.3), delay: Float(k) * 0.045, bell: true))
        }
    }

    /// Picking a color: a little two-note chime, one pitch per swatch.
    func pick(index: Int) {
        let base = 5 + index % 6
        engine.play(NoteEvent(frequency: frequency(base), velocity: 0.6, pan: 0, delay: 0, bell: true))
        engine.play(NoteEvent(frequency: frequency(base + 2), velocity: 0.5, pan: 0.2, delay: 0.09, bell: true))
    }

    /// Washing the canvas: a cascading run down the scale.
    func wash() {
        for k in 0..<12 {
            engine.play(NoteEvent(frequency: frequency(11 - k), velocity: 0.55, pan: Float(k % 2 == 0 ? -0.4 : 0.4),
                                  delay: Float(k) * 0.05, bell: true))
        }
    }

    /// Pinch-stirring: a breathy whoosh that follows hand speed.
    func stir(speed: Float) {
        frameStir = max(frameStir, smoothStep(0.05, 2.5, speed))
        energy = min(1, energy + 0.004)
    }

    /// Holding a fist: the pad swells as the wash charges.
    func swell(_ progress: Float) {
        frameSwell = max(frameSwell, progress)
    }

    /// Once per rendered frame, after all hands are processed.
    func endFrame(dt: Float, now: Double, night: Bool) {
        energy *= exp(-dt / 2.5)
        engine.setControls(energy: energy, stir: frameStir, swell: frameSwell, brightness: energy,
                           night: night, now: now)
        frameStir = 0
        frameSwell = 0
    }

    func forget(hand id: Int) {
        travel[id] = nil
        lastNote[id] = nil
    }
}
