import AVFoundation
import os

/// A note request sent from the main thread to the audio thread.
nonisolated struct NoteEvent: Sendable {
    var frequency: Float
    var velocity: Float   // 0…1
    var pan: Float        // -1 left … 1 right
    var delay: Float      // seconds
    var bell: Bool        // glassy, long bell instead of a soft mallet
}

/// One FM voice (carrier + one modulator) with an attack/exponential-decay envelope.
nonisolated private struct PluckVoice {
    var active = false
    var delay = 0
    var frequency: Float = 440
    var carrierPhase: Float = 0
    var modPhase: Float = 0
    var modRatio: Float = 4
    var modIndex: Float = 1
    var modDecay: Float = 0.999
    var amplitude: Float = 0
    var peak: Float = 0
    var attackStep: Float = 0
    var attacking = true
    var decay: Float = 0.9999
    var left: Float = 0.7
    var right: Float = 0.7
}

nonisolated private struct Biquad {
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    mutating func setBandPass(frequency: Float, q: Float, sampleRate: Float) {
        let w0 = 2 * Float.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        b0 = alpha / a0
        b1 = 0
        b2 = -alpha / a0
        a1 = -2 * cos(w0) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

/// Real-time synthesizer for the canvas soundtrack:
/// - an evolving pad that walks through a chord progression,
/// - a pool of mallet/bell voices triggered by brush strokes,
/// - a filtered-noise "whoosh" for stirring.
/// The main thread only writes control values and queues notes; the audio thread never allocates or blocks.
nonisolated final class MusicDSP: @unchecked Sendable {
    // Dmaj9 → Bm11 → Gmaj9 → A6sus (all friendly with D major pentatonic)
    private static let chords: [[Float]] = [
        [50, 57, 64, 66],
        [47, 54, 62, 64],
        [43, 50, 59, 66],
        [45, 52, 57, 64],
    ]
    private static let chordLength: Float = 8
    private static let padCount = 8   // 4 chord tones × 2 detuned oscillators
    private static let voiceCount = 24
    private static let tableSize = 4096
    private static let queueCapacity = 64

    static func hz(_ midi: Float) -> Float { 440 * pow(2, (midi - 69) / 12) }

    private let sampleRate: Float

    // Main → audio
    private enum Control: Int { case energy, stir, swell, brightness, night, master }
    private let controls = UnsafeMutablePointer<Float>.allocate(capacity: 6)
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private let queue = UnsafeMutablePointer<NoteEvent>.allocate(capacity: queueCapacity)
    private var queueCount = 0   // guarded by `lock`

    // Audio-thread state
    private let table = UnsafeMutablePointer<Float>.allocate(capacity: tableSize)
    private let voices = UnsafeMutablePointer<PluckVoice>.allocate(capacity: voiceCount)
    private var nextVoice = 0
    private let padFrequency = UnsafeMutablePointer<Float>.allocate(capacity: padCount)
    private let padTarget = UnsafeMutablePointer<Float>.allocate(capacity: padCount)
    private let padPhase = UnsafeMutablePointer<Float>.allocate(capacity: padCount)
    private var chordIndex = 0
    private var chordTime: Float = 0
    private var padLevel: Float = 0
    private var lfoPhase: Float = 0
    private var lowLeft: Float = 0
    private var lowRight: Float = 0
    private var whoosh = Biquad()
    private var whooshGain: Float = 0
    private var noiseSeed: UInt32 = 0x1234_5678
    private var energy: Float = 0
    private var stir: Float = 0
    private var swell: Float = 0
    private var brightness: Float = 0
    private var master: Float = 0

    init(sampleRate: Float) {
        self.sampleRate = sampleRate
        lock.initialize(to: os_unfair_lock())
        controls.initialize(repeating: 0, count: 6)
        controls[Control.master.rawValue] = 1
        queue.initialize(repeating: NoteEvent(frequency: 0, velocity: 0, pan: 0, delay: 0, bell: false),
                         count: Self.queueCapacity)
        for i in 0..<Self.tableSize {
            table[i] = sin(2 * Float.pi * Float(i) / Float(Self.tableSize))
        }
        voices.initialize(repeating: PluckVoice(), count: Self.voiceCount)
        padFrequency.initialize(repeating: 0, count: Self.padCount)
        padTarget.initialize(repeating: 0, count: Self.padCount)
        padPhase.initialize(repeating: 0, count: Self.padCount)
        setChord(0)
        for i in 0..<Self.padCount {
            padFrequency[i] = padTarget[i]
            padPhase[i] = Float(i) * 0.137
        }
    }

    deinit {
        controls.deallocate()
        lock.deallocate()
        queue.deallocate()
        table.deallocate()
        voices.deallocate()
        padFrequency.deallocate()
        padTarget.deallocate()
        padPhase.deallocate()
    }

    // MARK: Main-thread API

    func trigger(_ event: NoteEvent) {
        os_unfair_lock_lock(lock)
        if queueCount < Self.queueCapacity {
            queue[queueCount] = event
            queueCount += 1
        }
        os_unfair_lock_unlock(lock)
    }

    func setControls(energy: Float, stir: Float, swell: Float, brightness: Float, night: Bool) {
        controls[Control.energy.rawValue] = energy
        controls[Control.stir.rawValue] = stir
        controls[Control.swell.rawValue] = swell
        controls[Control.brightness.rawValue] = brightness
        controls[Control.night.rawValue] = night ? 1 : 0
    }

    func setMuted(_ muted: Bool) {
        controls[Control.master.rawValue] = muted ? 0 : 1
    }

    func makeRenderBlock() -> AVAudioSourceNodeRenderBlock {
        return { _, _, frameCount, audioBufferList in
            self.render(frameCount: Int(frameCount), bufferList: audioBufferList)
            return noErr
        }
    }

    // MARK: Audio thread

    @inline(__always)
    private func sine(_ phase: Float) -> Float {
        let p = phase - phase.rounded(.down)
        let x = p * Float(Self.tableSize)
        let i = Int(x)
        let f = x - Float(i)
        let a = table[i & (Self.tableSize - 1)]
        let b = table[(i + 1) & (Self.tableSize - 1)]
        return a + (b - a) * f
    }

    private func setChord(_ index: Int) {
        let chord = Self.chords[index % Self.chords.count]
        for (i, midi) in chord.enumerated() {
            let f = Self.hz(midi)
            padTarget[i * 2] = f
            padTarget[i * 2 + 1] = f * 1.0045
        }
    }

    private func start(_ event: NoteEvent) {
        let bell = event.bell || controls[Control.night.rawValue] > 0.5
        var v = PluckVoice()
        v.active = true
        v.delay = Int(max(event.delay, 0) * sampleRate)
        v.frequency = event.frequency
        v.carrierPhase = 0
        v.modPhase = 0.25
        v.modRatio = bell ? 3.5 : 4.0
        v.modIndex = bell ? 2.2 : 1.4
        v.modDecay = exp(-1 / ((bell ? 0.5 : 0.08) * sampleRate))
        v.decay = exp(-6.9 / ((bell ? 2.6 : 0.9) * sampleRate))
        let pitchTilt = pow(min(1, 600 / max(event.frequency, 1)), 0.35)   // keep high notes gentle
        v.peak = max(0, min(event.velocity, 1)) * (bell ? 0.16 : 0.22) * pitchTilt
        v.attackStep = v.peak / (0.003 * sampleRate)
        v.amplitude = 0
        v.attacking = true
        let angle = (max(-1, min(event.pan, 1)) + 1) * Float.pi / 4
        v.left = cos(angle)
        v.right = sin(angle)
        voices[nextVoice] = v
        nextVoice = (nextVoice + 1) % Self.voiceCount
    }

    private func render(frameCount: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        // New notes (never block the audio thread: if the UI holds the lock, take them next buffer).
        if os_unfair_lock_trylock(lock) {
            for i in 0..<queueCount { start(queue[i]) }
            queueCount = 0
            os_unfair_lock_unlock(lock)
        }

        let block = Float(frameCount) / sampleRate
        func smooth(_ value: inout Float, _ target: Float, _ time: Float) {
            value += (target - value) * (1 - exp(-block / time))
        }
        smooth(&energy, controls[Control.energy.rawValue], 0.6)
        smooth(&stir, controls[Control.stir.rawValue], 0.08)
        smooth(&swell, controls[Control.swell.rawValue], 0.3)
        smooth(&brightness, controls[Control.brightness.rawValue], 0.8)

        chordTime += block
        if chordTime >= Self.chordLength {
            chordTime = 0
            chordIndex += 1
            setChord(chordIndex)
        }

        // Per-block parameters
        let padGlide = 1 - exp(-1 / (1.6 * sampleRate))
        let padTargetLevel: Float = 0.035 + 0.05 * energy + 0.11 * swell
        let padStep = 1 - exp(-1 / (0.5 * sampleRate))
        let cutoff = 450 + 2600 * brightness + 1800 * swell
        let lowpass = 1 - exp(-2 * Float.pi * cutoff / sampleRate)
        whoosh.setBandPass(frequency: 300 + 2800 * stir, q: 1.3, sampleRate: sampleRate)
        let whooshTarget = stir * 0.55
        let whooshStep = 1 - exp(-1 / (0.03 * sampleRate))
        let masterTarget = controls[Control.master.rawValue]
        let masterStep = 1 - exp(-1 / (0.15 * sampleRate))
        let lfoRate = 0.07 / sampleRate
        let inverseRate = 1 / sampleRate

        // Pad + whoosh
        for n in 0..<frameCount {
            var padL: Float = 0
            var padR: Float = 0
            for v in 0..<Self.padCount {
                padFrequency[v] += (padTarget[v] - padFrequency[v]) * padGlide
                var phase = padPhase[v] + padFrequency[v] * inverseRate
                if phase >= 1 { phase -= 1 }
                padPhase[v] = phase
                let s = sine(phase) + 0.22 * sine(phase * 2) + 0.06 * sine(phase * 3)
                if v % 2 == 0 { padL += s * 0.8; padR += s * 0.45 } else { padL += s * 0.45; padR += s * 0.8 }
            }
            lowLeft += (padL - lowLeft) * lowpass
            lowRight += (padR - lowRight) * lowpass
            lfoPhase += lfoRate
            if lfoPhase >= 1 { lfoPhase -= 1 }
            padLevel += (padTargetLevel - padLevel) * padStep
            let breath = padLevel * (0.82 + 0.18 * sine(lfoPhase))

            noiseSeed ^= noiseSeed << 13
            noiseSeed ^= noiseSeed >> 17
            noiseSeed ^= noiseSeed << 5
            let noise = Float(noiseSeed) / Float(UInt32.max) * 2 - 1
            whooshGain += (whooshTarget - whooshGain) * whooshStep
            let air = whoosh.process(noise) * whooshGain

            left[n] = lowLeft * breath + air * 0.9
            right[n] = lowRight * breath + air
        }

        // Mallets and bells
        for i in 0..<Self.voiceCount where voices[i].active {
            var v = voices[i]
            var startSample = 0
            if v.delay >= frameCount {
                v.delay -= frameCount
                voices[i] = v
                continue
            } else if v.delay > 0 {
                startSample = v.delay
                v.delay = 0
            }
            let carrierStep = v.frequency * inverseRate
            let modStep = v.frequency * v.modRatio * inverseRate
            for n in startSample..<frameCount {
                if v.attacking {
                    v.amplitude += v.attackStep
                    if v.amplitude >= v.peak {
                        v.amplitude = v.peak
                        v.attacking = false
                    }
                } else {
                    v.amplitude *= v.decay
                }
                v.modIndex *= v.modDecay
                v.carrierPhase += carrierStep
                if v.carrierPhase >= 1 { v.carrierPhase -= 1 }
                v.modPhase += modStep
                if v.modPhase >= 1 { v.modPhase -= 1 }
                let s = sine(v.carrierPhase + v.modIndex * 0.159 * sine(v.modPhase)) * v.amplitude
                left[n] += s * v.left
                right[n] += s * v.right
            }
            if !v.attacking && v.amplitude < 0.0004 { v.active = false }
            voices[i] = v
        }

        // Master fade (mute) + gentle saturation
        for n in 0..<frameCount {
            master += (masterTarget - master) * masterStep
            left[n] = tanh(left[n] * master)
            right[n] = tanh(right[n] * master)
        }
        for b in 2..<max(buffers.count, 2) {
            if let data = buffers[b].mData { memset(data, 0, Int(buffers[b].mDataByteSize)) }
        }
    }
}
