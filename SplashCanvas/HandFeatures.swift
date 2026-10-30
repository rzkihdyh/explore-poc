import Foundation
import simd

enum HandPose: Equatable {
    case idle, point, pinch, open, fist
}

/// Geometry pulled out of one Vision observation, in camera-image space.
struct HandFeatures {
    var wrist: SIMD2<Float>
    var indexTip: SIMD2<Float>
    var thumbTip: SIMD2<Float>?
    var palm: SIMD2<Float>
    /// thumb, index, middle, ring, little (palm when a tip is missing)
    var tips: [SIMD2<Float>]
    var extendedCount: Int
    var indexExtended: Bool
    /// thumb-to-index distance in hand sizes
    var pinchRatio: Float
    /// index-tip-to-wrist distance in hand sizes
    var indexReach: Float

    init?(_ hand: HandObservation, aspect: Float) {
        guard let wrist = hand[.wrist], let indexTip = hand[.indexTip] else { return nil }
        // Image x and y have different pixel scales; correct for it when measuring distances.
        let scale = SIMD2<Float>(aspect, 1)
        func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float { simd_distance(a * scale, b * scale) }

        let knuckles = [hand[.indexMCP], hand[.middleMCP], hand[.ringMCP], hand[.littleMCP]].compactMap { $0 }
        let palmPoints = [wrist] + knuckles
        let palm = palmPoints.reduce(SIMD2<Float>.zero, +) / Float(palmPoints.count)
        let middleKnuckle = hand[.middleMCP] ?? hand[.indexMCP] ?? palm
        let handSize = max(distance(wrist, middleKnuckle), 0.02)

        func isExtended(_ tip: HandJoint, _ pip: HandJoint) -> Bool? {
            guard let t = hand[tip], let p = hand[pip] else { return nil }
            return distance(t, wrist) > distance(p, wrist) * 1.15
        }
        let fingers = [
            isExtended(.indexTip, .indexPIP),
            isExtended(.middleTip, .middlePIP),
            isExtended(.ringTip, .ringPIP),
            isExtended(.littleTip, .littlePIP),
        ]

        let thumb = hand[.thumbTip]
        var ratio: Float = 10
        if let thumb { ratio = distance(thumb, indexTip) / handSize }

        let rawTips: [SIMD2<Float>?] = [thumb, indexTip, hand[.middleTip], hand[.ringTip], hand[.littleTip]]

        self.wrist = wrist
        self.indexTip = indexTip
        self.thumbTip = thumb
        self.palm = palm
        self.tips = rawTips.map { $0 ?? palm }
        self.extendedCount = fingers.reduce(0) { $0 + ($1 == true ? 1 : 0) }
        self.indexExtended = fingers[0] ?? true
        self.pinchRatio = ratio
        self.indexReach = distance(indexTip, wrist) / handSize
    }

    /// Instantaneous pose. `wasPinching` adds hysteresis so pinches don't flicker.
    func classify(wasPinching: Bool) -> HandPose {
        let pinchThreshold: Float = wasPinching ? 0.45 : 0.28
        // In a fist the thumb also touches the index, but the index tip sits near the palm.
        if pinchRatio < pinchThreshold && indexReach > 1.05 { return .pinch }
        if extendedCount >= 4 { return .open }
        if extendedCount == 0 && !indexExtended { return .fist }
        return .point
    }

    /// The point that drives the main cursor for a pose.
    func anchor(for pose: HandPose) -> SIMD2<Float> {
        switch pose {
        case .pinch:
            if let thumbTip { return (thumbTip + indexTip) * 0.5 }
            return indexTip
        case .open, .fist:
            return palm
        case .point, .idle:
            return indexTip
        }
    }
}

/// Per-hand state, kept across camera frames and render frames.
struct TrackedHand {
    let id: Int
    var slot: Int
    var isTouch = false

    // Pose (updated at camera rate)
    var pose: HandPose
    var candidatePose: HandPose = .idle
    var candidateFrames = 0
    var isPinching = false
    var wrist: SIMD2<Float> = .zero
    var lastSample: Double

    // Filtered targets in canvas UV
    var mainFilter = OneEuroFilter2D()
    var tipFilters = [OneEuroFilter2D](repeating: OneEuroFilter2D(), count: 5)
    var mainTarget: SIMD2<Float> = .zero
    var mainVelocity: SIMD2<Float> = .zero
    var tipTargets = [SIMD2<Float>](repeating: .zero, count: 5)
    var tipVelocities = [SIMD2<Float>](repeating: .zero, count: 5)

    // Rendered cursor (updated at display rate)
    var hasCursor = false
    var cursor: SIMD2<Float> = .zero
    var previousCursor: SIMD2<Float> = .zero
    var tips = [SIMD2<Float>](repeating: .zero, count: 5)
    var previousTips = [SIMD2<Float>](repeating: .zero, count: 5)
    var presence: Float = 0

    // Interaction state
    var settle: Float = 0
    var travel: Float = 0
    var speed: Float = 0
    var fistTime: Float = 0
    var washFired = false
    var splashCooldown: Float = 0
    var dwellIndex: Int?
    var dwellTime: Float = 0
    var dwellFired = false

    init(id: Int, slot: Int, pose: HandPose, lastSample: Double, isTouch: Bool = false) {
        self.id = id
        self.slot = slot
        self.pose = pose
        self.lastSample = lastSample
        self.isTouch = isTouch
    }
}
