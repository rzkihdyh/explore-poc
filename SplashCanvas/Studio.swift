import SwiftUI
import Observation
import QuartzCore
import simd

enum CanvasStyle: Equatable { case paper, night }

enum CameraStatus: Equatable { case starting, running, denied, unavailable }

/// Where the HUD lives, in full-screen points. Shared by SwiftUI (drawing) and the
/// gesture engine (hover-to-pick), so both always agree.
struct HUDLayout: Equatable {
    var size: CGSize = .zero
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat = 0
    var itemCenters: [CGPoint] = []
    var itemDiameter: CGFloat = 34
    var itemSpacing: CGFloat = 44
    var bandBottom: CGFloat = 0
}

struct SnapshotImage: Identifiable {
    let id = UUID()
    let cgImage: CGImage
}

struct FrameOutput {
    var splats: [Splat]
    var cursors: [CursorMark]
    var wash: Bool
}

/// The interaction model: turns hands (and touches) into paint, and holds the HUD state.
@Observable
final class Studio {
    // MARK: HUD state (observed by SwiftUI)
    var style: CanvasStyle = .paper
    var selection: PaletteItem = .rainbow
    var dwellItem: PaletteItem?
    var dwellProgress: Double = 0
    var primaryPose: HandPose = .idle
    var handCount = 0
    var cameraStatus: CameraStatus = .starting
    var showGuide = true
    var showCameraPreview = true
    var previewHands: [[CGPoint]] = []
    var imageAspect: CGFloat = 0.75
    var layout = HUDLayout()
    var snapshot: SnapshotImage?
    var flashMessage: String?
    var musicOn = true

    /// Generative soundtrack driven by the same gestures as the paint.
    @ObservationIgnored let composer = Composer()

    // MARK: Engine state (not observed — changes every frame)
    @ObservationIgnored var snapshotRequested = false
    @ObservationIgnored private var hands: [TrackedHand] = []
    @ObservationIgnored private var nextHandID = 1
    @ObservationIgnored private var pendingSplats: [Splat] = []
    @ObservationIgnored private var washRequested = false
    @ObservationIgnored private var seeded = false
    @ObservationIgnored private var handPresentTime: Float = 0
    @ObservationIgnored private var rainbowPhase: Float = 0
    @ObservationIgnored private var flashUntil: Double = 0

    // MARK: - Layout

    func updateLayout(size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        let count = Palette.items.count
        let available = min(size.width - 40, 520)
        let spacing = min(56, available / CGFloat(count))
        let diameter = min(40, spacing * 0.74)
        let y = safeTop + 14 + diameter / 2
        let startX = size.width / 2 - spacing * CGFloat(count - 1) / 2
        var next = HUDLayout()
        next.size = size
        next.safeTop = safeTop
        next.safeBottom = safeBottom
        next.itemSpacing = spacing
        next.itemDiameter = diameter
        next.itemCenters = (0..<count).map { CGPoint(x: startX + CGFloat($0) * spacing, y: y) }
        next.bandBottom = y + diameter / 2 + 20
        if next != layout { layout = next }
    }

    // Canvas UV (0…1 both axes) ↔ "units" where 1 = the screen's short side.
    private var unitScale: SIMD2<Float> {
        let w = Float(max(layout.size.width, 1))
        let h = Float(max(layout.size.height, 1))
        let s = min(w, h)
        return SIMD2(w / s, h / s)
    }
    private func toUnits(_ uv: SIMD2<Float>) -> SIMD2<Float> { uv * unitScale }
    private func toUV(_ units: SIMD2<Float>) -> SIMD2<Float> { units / unitScale }
    private func uv(of point: CGPoint) -> SIMD2<Float> {
        SIMD2(Float(point.x / max(layout.size.width, 1)), Float(point.y / max(layout.size.height, 1)))
    }
    private func point(of uv: SIMD2<Float>) -> CGPoint {
        CGPoint(x: CGFloat(uv.x) * layout.size.width, y: CGFloat(uv.y) * layout.size.height)
    }
    private func canvasUV(fromImage p: SIMD2<Float>) -> SIMD2<Float> {
        (p - Tuning.reachMin) / (Tuning.reachMax - Tuning.reachMin)
    }

    // MARK: - Camera input (camera rate)

    func ingest(_ frame: HandFrame) {
        let now = CACurrentMediaTime()
        let aspect = CGFloat(frame.imageAspect)
        if abs(aspect - imageAspect) > 0.001 { imageAspect = aspect }

        var available = hands.indices.filter { !hands[$0].isTouch }
        for observation in frame.hands {
            guard let features = HandFeatures(observation, aspect: frame.imageAspect) else { continue }
            var best: Int?
            var bestDistance = Tuning.matchDistance
            for index in available {
                let d = simd_distance(hands[index].wrist, features.wrist)
                if d < bestDistance {
                    bestDistance = d
                    best = index
                }
            }
            if let index = best {
                available.removeAll { $0 == index }
                var hand = hands[index]
                update(&hand, with: features, now: now, isNew: false)
                hands[index] = hand
            } else if hands.filter({ !$0.isTouch }).count < Tuning.maxHands {
                var hand = TrackedHand(id: nextHandID, slot: freeSlot(), pose: .point, lastSample: now)
                nextHandID += 1
                update(&hand, with: features, now: now, isNew: true)
                hands.append(hand)
            }
        }

        if showCameraPreview {
            previewHands = frame.hands.map { hand in
                hand.joints.compactMap { joint in
                    joint.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
                }
            }
        }
    }

    private func freeSlot() -> Int {
        let used = Set(hands.filter { !$0.isTouch }.map(\.slot))
        return used.contains(0) ? 1 : 0
    }

    private func requiredFrames(for pose: HandPose) -> Int {
        switch pose {
        case .pinch: return 1
        case .point, .idle: return 2
        case .open: return 3
        case .fist: return 4
        }
    }

    private func update(_ hand: inout TrackedHand, with features: HandFeatures, now: Double, isNew: Bool) {
        let dt = Float(min(max(now - hand.lastSample, 1.0 / 120.0), 0.1))
        let raw = features.classify(wasPinching: hand.isPinching)
        hand.isPinching = raw == .pinch

        var changed = false
        if isNew {
            hand.pose = raw
        } else if raw == hand.pose {
            hand.candidateFrames = 0
        } else {
            if raw == hand.candidatePose {
                hand.candidateFrames += 1
            } else {
                hand.candidatePose = raw
                hand.candidateFrames = 1
            }
            if hand.candidateFrames >= requiredFrames(for: raw) {
                hand.pose = raw
                hand.candidateFrames = 0
                changed = true
            }
        }
        if changed {
            hand.mainFilter.reset()
            hand.settle = Tuning.settleTime
        }

        let span = Tuning.reachMax - Tuning.reachMin
        let main = hand.mainFilter.filter(features.anchor(for: hand.pose), dt: dt)
        hand.mainTarget = canvasUV(fromImage: main)
        hand.mainVelocity = clampLength(hand.mainFilter.velocity / span, 6)
        for i in 0..<5 {
            let tip = hand.tipFilters[i].filter(features.tips[i], dt: dt)
            hand.tipTargets[i] = canvasUV(fromImage: tip)
            hand.tipVelocities[i] = clampLength(hand.tipFilters[i].velocity / span, 6)
        }
        hand.wrist = features.wrist
        hand.lastSample = now
    }

    // MARK: - Touch input (fallback; also lets the Simulator be used)

    func touchBegan(at uv: SIMD2<Float>) {
        hands.removeAll { $0.isTouch }
        var hand = TrackedHand(id: -1, slot: 0, pose: .point, lastSample: CACurrentMediaTime(), isTouch: true)
        hand.mainTarget = uv
        hand.tipTargets = Array(repeating: uv, count: 5)
        hands.append(hand)
    }

    func touchMoved(to uv: SIMD2<Float>) {
        guard let index = hands.firstIndex(where: { $0.isTouch }) else { return }
        hands[index].mainTarget = uv
        hands[index].lastSample = CACurrentMediaTime()
    }

    func touchEnded() {
        hands.removeAll { $0.isTouch }
    }

    // MARK: - Actions (HUD buttons and hover-to-pick)

    func select(_ item: PaletteItem, at index: Int) {
        let center = index < layout.itemCenters.count
            ? layout.itemCenters[index]
            : CGPoint(x: layout.size.width / 2, y: layout.bandBottom)
        switch item {
        case .style:
            style = style == .paper ? .night : .paper
            flash(style == .paper ? "Paper" : "Night glow")
        case .paint, .rainbow:
            selection = item
            var burst: [Splat] = []
            splash(at: uv(of: CGPoint(x: center.x, y: layout.bandBottom)), direction: SIMD2(0, 1),
                   speed: 3.5, colors: burstColors(for: item), into: &burst)
            pendingSplats.append(contentsOf: burst)
            composer.pick(index: index)
        }
    }

    func clearCanvas() {
        washRequested = true
        pendingSplats.append(.impulse(from: SIMD2(0.5, 0.5), to: SIMD2(0.5, 0.5), velocity: .zero,
                                      color: .zero, amount: 0, cover: 0, radius: 0.45, swirl: 220))
        composer.wash()
        flash("Fresh canvas")
    }

    func requestSnapshot() { snapshotRequested = true }

    func toggleMusic() {
        musicOn.toggle()
        composer.isMuted = !musicOn
        flash(musicOn ? "Music on" : "Music off")
    }

    func deliverSnapshot(_ image: CGImage?) {
        guard let image else { return }
        #if os(macOS)
        Platform.savePNG(image)
        #else
        snapshot = SnapshotImage(cgImage: image)
        #endif
    }

    private func flash(_ message: String) {
        flashMessage = message
        flashUntil = CACurrentMediaTime() + 1.4
    }

    // MARK: - Render-rate update

    func advance(dt: Float, now: Double) -> FrameOutput {
        var splats = pendingSplats
        pendingSplats.removeAll(keepingCapacity: true)
        var cursors: [CursorMark] = []
        rainbowPhase += dt * 0.04

        if !seeded && layout.size.width > 0 {
            seedArtwork(into: &splats)
            seeded = true
        }

        for hand in hands where !hand.isTouch && now - hand.lastSample > Tuning.handTimeout {
            composer.forget(hand: hand.id)
        }
        hands.removeAll { !$0.isTouch && now - $0.lastSample > Tuning.handTimeout }

        var bestDwell: (item: PaletteItem, progress: Double)?
        for index in hands.indices {
            var hand = hands[index]
            step(&hand, dt: dt, now: now, splats: &splats, cursors: &cursors, dwell: &bestDwell)
            hands[index] = hand
        }

        publishHUD(now: now, dt: dt, dwell: bestDwell)
        composer.endFrame(dt: dt, now: now, night: style == .night)

        let wash = washRequested
        washRequested = false
        return FrameOutput(splats: splats, cursors: cursors, wash: wash)
    }

    private func publishHUD(now: Double, dt: Float, dwell: (item: PaletteItem, progress: Double)?) {
        let item = dwell?.item
        let progress = ((dwell?.progress ?? 0) * 40).rounded() / 40
        if item != dwellItem { dwellItem = item }
        if progress != dwellProgress { dwellProgress = progress }

        let visible = hands.filter { !$0.isTouch && now - $0.lastSample < Tuning.lostAfter }
        if visible.count != handCount { handCount = visible.count }
        let pose = visible.first?.pose ?? .idle
        if pose != primaryPose { primaryPose = pose }

        if visible.isEmpty {
            handPresentTime = 0
        } else {
            handPresentTime += dt
            if showGuide && handPresentTime > 1.5 {
                withAnimation(.easeOut(duration: 0.4)) { showGuide = false }
            }
        }
        if flashMessage != nil && now > flashUntil { flashMessage = nil }
    }

    private func step(_ hand: inout TrackedHand, dt: Float, now: Double,
                      splats: inout [Splat], cursors: inout [CursorMark],
                      dwell: inout (item: PaletteItem, progress: Double)?) {
        let age = Float(now - hand.lastSample)
        let tracking = hand.isTouch || Double(age) < Tuning.lostAfter
        hand.presence += ((tracking ? 1 : 0) - hand.presence) * min(1, dt * 10)

        // Ease the cursor toward a slightly predicted target: camera frames arrive at
        // 30–60 Hz, the canvas draws at 60 Hz, and prediction hides the tracking latency.
        let lead: Float = hand.isTouch || !tracking ? 0 : min(age, Tuning.maxPredictionAge) + Tuning.predictionLead
        let follow = 1 - exp(-dt * (hand.isTouch ? Tuning.touchFollowRate : Tuning.followRate))
        let target = hand.mainTarget + hand.mainVelocity * lead
        if !hand.hasCursor {
            hand.cursor = target
            hand.previousCursor = target
            hand.tips = hand.tipTargets
            hand.previousTips = hand.tipTargets
            hand.hasCursor = true
        }
        hand.previousCursor = hand.cursor
        hand.cursor += (target - hand.cursor) * follow
        for i in 0..<5 {
            hand.previousTips[i] = hand.tips[i]
            hand.tips[i] += (hand.tipTargets[i] + hand.tipVelocities[i] * lead - hand.tips[i]) * follow
        }

        hand.settle -= dt
        hand.splashCooldown -= dt
        let motion = toUnits(hand.cursor - hand.previousCursor)
        let distance = simd_length(motion)
        let speed = distance / max(dt, 1e-4)
        hand.speed += (speed - hand.speed) * min(1, dt * 14)
        hand.travel += distance
        let canEmit = tracking && hand.settle <= 0

        // Hover-to-pick on the palette strip.
        var overPalette = false
        if hand.pose == .point {
            let p = point(of: hand.cursor)
            if p.y < layout.bandBottom {
                overPalette = true
                updateDwell(&hand, at: p, dt: dt)
                if let i = hand.dwellIndex, i < Palette.items.count {
                    let progress = Double(min(hand.dwellTime / Tuning.dwellTime, 1))
                    if dwell == nil || progress > dwell!.progress { dwell = (Palette.items[i], progress) }
                }
            }
        }
        if !overPalette {
            hand.dwellIndex = nil
            hand.dwellTime = 0
            hand.dwellFired = false
        }
        if hand.pose != .fist {
            hand.fistTime = 0
            hand.washFired = false
        }

        let alpha = hand.presence * (hand.isTouch ? 0.6 : 1)

        switch hand.pose {
        case .point, .idle:
            let color = paintColor(for: hand, offset: 0)
            if canEmit && !overPalette {
                emitStroke(from: hand.previousCursor, to: hand.cursor, dt: dt, speed: hand.speed,
                           color: color, brush: .paint, into: &splats)
                composer.paint(hand: hand.id, at: hand.cursor, distance: distance, speed: hand.speed,
                               now: now, night: style == .night)
                if hand.speed > Tuning.flickSpeed && hand.splashCooldown <= 0 && distance > 0 {
                    splash(at: hand.cursor, direction: motion / distance, speed: hand.speed,
                           colors: [color, ColorMath.shiftHue(color, by: 0.05), ColorMath.shiftHue(color, by: -0.05)],
                           into: &splats)
                    composer.splash(at: hand.cursor, speed: hand.speed)
                    hand.splashCooldown = Tuning.splashCooldown
                }
            }
            let progress: Float = overPalette ? min(hand.dwellTime / Tuning.dwellTime, 1) : 0
            cursors.append(CursorMark(position: hand.cursor, radius: overPalette ? 0.045 : 0.032,
                                      progress: progress, color: SIMD4(color, 1),
                                      style: overPalette ? 4 : 0, alpha: alpha))

        case .pinch:
            if canEmit {
                emitStroke(from: hand.previousCursor, to: hand.cursor, dt: dt, speed: hand.speed,
                           color: .zero, brush: .stir, into: &splats)
                composer.stir(speed: hand.speed)
            }
            cursors.append(CursorMark(position: hand.cursor, radius: 0.06, progress: 0,
                                      color: SIMD4(1, 1, 1, 1), style: 1, alpha: alpha))

        case .open:
            var colors: [SIMD3<Float>] = []
            for i in 0..<5 {
                let color = paintColor(for: hand, offset: i - 2)
                colors.append(color)
                if canEmit {
                    let tipMotion = simd_length(toUnits(hand.tips[i] - hand.previousTips[i])) / max(dt, 1e-4)
                    emitStroke(from: hand.previousTips[i], to: hand.tips[i], dt: dt, speed: tipMotion,
                               color: color, brush: .finger, into: &splats)
                }
                cursors.append(CursorMark(position: hand.tips[i], radius: 0.014, progress: 0,
                                          color: SIMD4(color, 1), style: 2, alpha: alpha))
            }
            if canEmit && hand.speed > Tuning.flickSpeed && hand.splashCooldown <= 0 && distance > 0 {
                splash(at: hand.cursor, direction: motion / distance, speed: hand.speed * 1.2,
                       colors: colors, into: &splats)
                composer.splash(at: hand.cursor, speed: hand.speed * 1.2)
                hand.splashCooldown = Tuning.splashCooldown
            }
            if canEmit {
                composer.strum(hand: hand.id, at: hand.cursor, distance: distance, speed: hand.speed,
                               now: now, night: style == .night)
            }

        case .fist:
            if tracking && !hand.washFired {
                hand.fistTime += dt
                if hand.fistTime >= Tuning.washHold {
                    hand.washFired = true
                    clearCanvas()
                }
            }
            let progress = hand.washFired ? 1 : min(hand.fistTime / Tuning.washHold, 1)
            if !hand.washFired { composer.swell(progress) }
            cursors.append(CursorMark(position: hand.cursor, radius: 0.05, progress: progress,
                                      color: SIMD4(0.35, 0.75, 1.0, 1), style: 3, alpha: alpha))
        }
    }

    private func updateDwell(_ hand: inout TrackedHand, at p: CGPoint, dt: Float) {
        var nearest: Int?
        var nearestDistance = layout.itemSpacing * 0.6
        for (i, center) in layout.itemCenters.enumerated() {
            let d = hypot(center.x - p.x, center.y - p.y)
            if d < nearestDistance {
                nearestDistance = d
                nearest = i
            }
        }
        if nearest == hand.dwellIndex {
            hand.dwellTime += dt
        } else {
            hand.dwellIndex = nearest
            hand.dwellTime = 0
            hand.dwellFired = false
        }
        if let i = nearest, !hand.dwellFired, hand.dwellTime >= Tuning.dwellTime, i < Palette.items.count {
            hand.dwellFired = true
            select(Palette.items[i], at: i)
        }
    }

    // MARK: - Paint generation

    private func paintColor(for hand: TrackedHand, offset: Int) -> SIMD3<Float> {
        switch selection {
        case .paint(let index):
            let count = Palette.paints.count
            let i = ((index + hand.slot * 2 + offset) % count + count) % count
            // A gentle hue drift along the stroke keeps single-color strokes lively.
            return ColorMath.shiftHue(Palette.paints[i], by: sin(hand.travel * 2.2) * 0.025)
        case .rainbow, .style:
            let hue = rainbowPhase + hand.travel * 0.22 + Float(offset) * 0.09 + Float(hand.slot) * 0.5
            return ColorMath.rgb(hue: hue, saturation: 0.82, value: 1)
        }
    }

    private func burstColors(for item: PaletteItem) -> [SIMD3<Float>] {
        switch item {
        case .paint(let i):
            let c = Palette.paints[i]
            return [c, ColorMath.shiftHue(c, by: 0.04), ColorMath.shiftHue(c, by: -0.04)]
        case .rainbow, .style:
            return (0..<6).map { ColorMath.rgb(hue: Float($0) / 6, saturation: 0.82, value: 1) }
        }
    }

    private func emitStroke(from a: SIMD2<Float>, to b: SIMD2<Float>, dt: Float, speed: Float,
                            color: SIMD3<Float>, brush: BrushSpec, into splats: inout [Splat]) {
        let moving = smoothStep(0.03, 0.6, speed)          // 0 = still … 1 = moving
        let radius = brush.radius + brush.speedRadius * smoothStep(0.3, 3.0, speed)
        let velocity = (b - a) / max(dt, 1e-4) * brush.dragGain
        // A still finger slowly pools paint; a moving one lays down a full stroke.
        let amount = brush.amount * lerp(0.02, 1, moving)
        let cover = brush.cover * lerp(0.02, 1, moving)
        splats.append(.stroke(from: a, to: b, velocity: velocity, blend: 0.85 * moving,
                              color: color, amount: amount, cover: cover, radius: radius))
    }

    /// Throws a burst of droplets and streaks along `direction` (short-side units, normalized).
    private func splash(at origin: SIMD2<Float>, direction: SIMD2<Float>, speed: Float,
                        colors: [SIMD3<Float>], into splats: inout [Splat]) {
        guard !colors.isEmpty else { return }
        let perp = SIMD2<Float>(-direction.y, direction.x)
        let power = min(speed, 7)
        let count = Int.random(in: 9...14)
        for k in 0..<count {
            let along = Float.random(in: 0.01...0.14) * (0.5 + power * 0.12)
            let side = Float.random(in: -0.06...0.06)
            let start = origin + toUV(direction * along + perp * side)
            let streak = direction * Float.random(in: 0.005...0.035) + perp * Float.random(in: -0.008...0.008)
            let kick = direction * power * Float.random(in: 0.15...0.45) + perp * Float.random(in: -0.35...0.35)
            let amount = Float.random(in: 0.8...1.4)
            splats.append(.impulse(from: start, to: start + toUV(streak), velocity: toUV(kick),
                                   color: colors[k % colors.count], amount: amount, cover: 0.6,
                                   radius: Float.random(in: 0.005...0.016)))
        }
    }

    /// A few flowing strokes so the canvas is alive on launch.
    private func seedArtwork(into splats: inout [Splat]) {
        for s in 0..<4 {
            var p = SIMD2<Float>(Float.random(in: 0.2...0.8), Float.random(in: 0.3...0.8))
            var angle = Float.random(in: 0...(2 * Float.pi))
            let turn = Float.random(in: -2.5...2.5)
            let color = Palette.paints[(s * 2 + Int.random(in: 0...1)) % Palette.paints.count]
            for _ in 0..<18 {
                let direction = SIMD2<Float>(cos(angle), sin(angle))
                let next = p + toUV(direction * 0.025)
                splats.append(.stroke(from: p, to: next, velocity: toUV(direction * 1.6), blend: 0.8,
                                      color: color, amount: 0.9, cover: 0.5, radius: 0.02))
                p = next
                angle += turn * 0.06
            }
        }
    }
}
