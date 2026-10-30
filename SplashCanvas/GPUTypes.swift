import simd

// These structs are copied byte-for-byte into Metal buffers.
// Their layouts must match the structs of the same name in Shaders.metal.

/// A capsule-shaped brush dab from `start` to `end`.
/// Velocity: v += falloff * (velocity - drag * v)  → drag 1 = blend toward, drag 0 = impulse.
/// Dye:      dye = dye * (1 - falloff * cover) + color * falloff
struct Splat {
    var start: SIMD2<Float>      // canvas UV, y down
    var end: SIMD2<Float>
    var velocity: SIMD2<Float>   // UV per second (converted to grid cells per second on upload)
    var padding: SIMD2<Float> = .zero
    var color: SIMD4<Float>      // rgb premultiplied by amount, a = amount
    var radius: Float            // short-side units
    var drag: Float
    var cover: Float
    var swirl: Float             // grid cells per second of rotation at `radius`

    /// Drags the fluid along with the motion and lays down paint.
    static func stroke(from start: SIMD2<Float>, to end: SIMD2<Float>, velocity: SIMD2<Float>, blend: Float,
                       color: SIMD3<Float>, amount: Float, cover: Float, radius: Float) -> Splat {
        Splat(start: start, end: end, velocity: velocity * blend,
              color: SIMD4(color * amount, amount), radius: radius, drag: blend, cover: cover, swirl: 0)
    }

    /// Kicks the fluid (additive) — used for splashes.
    static func impulse(from start: SIMD2<Float>, to end: SIMD2<Float>, velocity: SIMD2<Float>,
                        color: SIMD3<Float>, amount: Float, cover: Float, radius: Float, swirl: Float = 0) -> Splat {
        Splat(start: start, end: end, velocity: velocity,
              color: SIMD4(color * amount, amount), radius: radius, drag: 0, cover: cover, swirl: swirl)
    }
}

/// A hand cursor drawn on top of the painting.
struct CursorMark {
    var position: SIMD2<Float>   // canvas UV
    var radius: Float            // short-side units
    var progress: Float          // 0…1 arc (dwell / wash), 0 = none
    var color: SIMD4<Float>
    var style: Float             // 0 point, 1 stir, 2 fingertip, 3 fist, 4 hover
    var alpha: Float
    var padding: SIMD2<Float> = .zero
}

struct DisplayUniforms {
    var viewSize: SIMD2<Float>
    var dyeTexel: SIMD2<Float>
    var mode: Float              // 0 paper … 1 night
    var time: Float
    var cursorCount: UInt32
    var padding: Float = 0
}

struct AdvectParams {
    var dt: Float
    var dissipation: Float
    var velocityTexel: SIMD2<Float>
}

struct VorticityParams {
    var dt: Float
    var strength: Float
}
