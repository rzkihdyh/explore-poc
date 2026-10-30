import Foundation
import simd

/// One Euro filter (Casiez et al.): heavy smoothing when the hand is still,
/// low lag when it moves fast. Also yields a smoothed velocity used for prediction.
nonisolated struct OneEuroFilter2D: Sendable {
    var minCutoff: Float
    var beta: Float
    var derivativeCutoff: Float

    private(set) var value: SIMD2<Float> = .zero
    private(set) var velocity: SIMD2<Float> = .zero
    private var initialized = false

    init(minCutoff: Float = 1.6, beta: Float = 0.9, derivativeCutoff: Float = 1.2) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func reset() {
        initialized = false
        velocity = .zero
    }

    mutating func filter(_ sample: SIMD2<Float>, dt: Float) -> SIMD2<Float> {
        guard initialized, dt > 0 else {
            value = sample
            velocity = .zero
            initialized = true
            return sample
        }
        let rawVelocity = (sample - value) / dt
        velocity += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (rawVelocity - velocity)
        let cutoff = minCutoff + beta * simd_length(velocity)
        value += Self.alpha(cutoff: cutoff, dt: dt) * (sample - value)
        return value
    }

    private static func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
