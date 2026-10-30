import Foundation
import simd

/// All the feel-related numbers in one place.
enum Tuning {
    // Camera → canvas. This box of the camera image spans the whole canvas,
    // so you can reach the edges without your hand leaving the camera's view.
    static let reachMin = SIMD2<Float>(0.12, 0.10)
    static let reachMax = SIMD2<Float>(0.88, 0.84)

    static let maxHands = 2
    static let matchDistance: Float = 0.3     // wrist jump allowed between frames (image units)
    static let lostAfter: Double = 0.22       // stop painting when a hand is unseen this long
    static let handTimeout: Double = 0.6      // forget it after this long

    static let followRate: Float = 26         // cursor easing toward the predicted target
    static let touchFollowRate: Float = 50
    static let predictionLead: Float = 0.02   // seconds of extra look-ahead
    static let maxPredictionAge: Float = 0.06
    static let settleTime: Float = 0.09       // no paint right after a pose change

    static let flickSpeed: Float = 3.2        // short-side units per second
    static let splashCooldown: Float = 0.28
    static let washHold: Float = 0.9          // seconds of fist to wash the canvas
    static let dwellTime: Float = 0.6         // seconds hovering a swatch to pick it

    static let simResolution: Float = 128
    static let dyeMinResolution: Float = 384
    static let dyeMaxResolution: Float = 768
}

struct BrushSpec {
    var radius: Float        // in short-side units
    var speedRadius: Float   // extra radius at high speed
    var amount: Float        // paint density laid down
    var cover: Float         // how much it covers paint underneath
    var dragGain: Float      // how hard it drags the fluid

    static let paint = BrushSpec(radius: 0.016, speedRadius: 0.012, amount: 0.8, cover: 0.45, dragGain: 1.25)
    static let finger = BrushSpec(radius: 0.010, speedRadius: 0.006, amount: 0.65, cover: 0.4, dragGain: 1.0)
    static let stir = BrushSpec(radius: 0.06, speedRadius: 0.02, amount: 0, cover: 0, dragGain: 1.8)
}

func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

func smoothStep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

func clampLength(_ v: SIMD2<Float>, _ maxLength: Float) -> SIMD2<Float> {
    let length = simd_length(v)
    return length > maxLength ? v * (maxLength / length) : v
}

enum ColorMath {
    static func rgb(hue: Float, saturation s: Float, value v: Float) -> SIMD3<Float> {
        let h = (hue - hue.rounded(.down)) * 6
        let c = v * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let base: SIMD3<Float>
        switch Int(h) {
        case 0: base = SIMD3(c, x, 0)
        case 1: base = SIMD3(x, c, 0)
        case 2: base = SIMD3(0, c, x)
        case 3: base = SIMD3(0, x, c)
        case 4: base = SIMD3(x, 0, c)
        default: base = SIMD3(c, 0, x)
        }
        return base + m
    }

    static func hsv(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let maxV = max(rgb.x, max(rgb.y, rgb.z))
        let minV = min(rgb.x, min(rgb.y, rgb.z))
        let d = maxV - minV
        var h: Float = 0
        if d > 1e-5 {
            if maxV == rgb.x {
                h = (rgb.y - rgb.z) / d
            } else if maxV == rgb.y {
                h = (rgb.z - rgb.x) / d + 2
            } else {
                h = (rgb.x - rgb.y) / d + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        return SIMD3(h, maxV == 0 ? 0 : d / maxV, maxV)
    }

    static func shiftHue(_ color: SIMD3<Float>, by amount: Float) -> SIMD3<Float> {
        let c = hsv(color)
        return rgb(hue: c.x + amount, saturation: c.y, value: c.z)
    }
}
