import SwiftUI
import AVFoundation

/// Everything drawn over the canvas. All positions come from `studio.layout`
/// (full-screen points), which the gesture engine also uses for hover-to-pick.
struct HUDView: View {
    @Bindable var studio: Studio
    let session: AVCaptureSession

    private var layout: HUDLayout { studio.layout }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.allowsHitTesting(false)
            if layout.itemCenters.count == Palette.items.count {
                palette
                statusChip
                bottomControls
                if studio.showCameraPreview && studio.cameraStatus == .running {
                    cameraPreview
                }
            }
            if let message = studio.flashMessage {
                Text(message)
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .position(x: layout.size.width / 2, y: layout.size.height * 0.45)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .allowsHitTesting(false)
            }
            if studio.showGuide {
                GestureGuideView { withAnimation(.easeOut(duration: 0.3)) { studio.showGuide = false } }
                    .transition(.opacity)
            }
            if studio.cameraStatus == .denied || studio.cameraStatus == .unavailable {
                CameraNoticeView(denied: studio.cameraStatus == .denied)
                    .position(x: layout.size.width / 2, y: layout.size.height / 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, studio.style == .night ? .dark : .light)
        .animation(.easeOut(duration: 0.25), value: studio.flashMessage)
        .modifier(SnapshotSheet(studio: studio))
    }

    // MARK: Palette

    private var palette: some View {
        let count = CGFloat(Palette.items.count)
        let first = layout.itemCenters[0]
        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(.ultraThinMaterial)
                .frame(width: layout.itemSpacing * count + 10, height: layout.itemDiameter + 16)
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .position(x: layout.size.width / 2, y: first.y)
                .allowsHitTesting(false)

            ForEach(Array(Palette.items.enumerated()), id: \.offset) { index, item in
                SwatchView(item: item,
                           selected: item == studio.selection,
                           dwell: studio.dwellItem == item ? studio.dwellProgress : 0,
                           style: studio.style,
                           diameter: layout.itemDiameter)
                    .position(layout.itemCenters[index])
                    .onTapGesture { studio.select(item, at: index) }
            }
        }
    }

    // MARK: Status

    private var status: (symbol: String, text: String)? {
        switch studio.cameraStatus {
        case .starting:
            return ("camera", "Starting camera…")
        case .denied, .unavailable:
            return ("hand.tap", "Touch to paint")
        case .running:
            break
        }
        if studio.dwellItem != nil { return ("scope", "Hold to pick") }
        switch studio.primaryPose {
        case .idle: return ("hand.wave.fill", "Raise your hand to paint")
        case .point: return ("hand.point.up.left.fill", "Painting · flick to splash")
        case .pinch: return ("hand.pinch.fill", "Stirring")
        case .open: return ("hand.raised.fingers.spread.fill", "Five-finger paint")
        case .fist: return ("drop.fill", "Hold to wash…")
        }
    }

    @ViewBuilder
    private var statusChip: some View {
        if let status {
            Label(status.text, systemImage: status.symbol)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .position(x: layout.size.width / 2, y: layout.bandBottom + 18)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: status.text)
        }
    }

    // MARK: Controls (touch shortcuts)

    private var bottomControls: some View {
        HStack(spacing: 10) {
            ControlButton(symbol: studio.musicOn ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                studio.toggleMusic()
            }
            ControlButton(symbol: "questionmark") {
                withAnimation { studio.showGuide = true }
            }
            ControlButton(symbol: studio.showCameraPreview ? "video.fill" : "video.slash.fill") {
                studio.showCameraPreview.toggle()
            }
            ControlButton(symbol: "square.and.arrow.up") { studio.requestSnapshot() }
            ControlButton(symbol: "drop.fill") { studio.clearCanvas() }
        }
        .position(x: layout.size.width - 16 - 131, y: layout.size.height - max(layout.safeBottom, 12) - 30)
    }

    // MARK: Camera picture-in-picture

    private var cameraPreview: some View {
        let width: CGFloat = studio.imageAspect > 1 ? 168 : 92
        let height = width / max(studio.imageAspect, 0.3)
        return ZStack {
            CameraPreview(session: session)
            Canvas { context, size in
                for hand in studio.previewHands {
                    for joint in hand {
                        let p = CGPoint(x: joint.x * size.width, y: joint.y * size.height)
                        context.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                                     with: .color(.white))
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.7), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .position(x: 16 + width / 2, y: layout.size.height - max(layout.safeBottom, 12) - 10 - height / 2)
        .allowsHitTesting(false)
    }
}

private struct SwatchView: View {
    let item: PaletteItem
    let selected: Bool
    let dwell: Double
    let style: CanvasStyle
    let diameter: CGFloat

    var body: some View {
        ZStack {
            fill
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
            if selected {
                Circle()
                    .stroke(Color.primary.opacity(0.85), lineWidth: 2.5)
                    .frame(width: diameter + 8, height: diameter + 8)
            }
            if dwell > 0 {
                Circle()
                    .trim(from: 0, to: dwell)
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: diameter + 14, height: diameter + 14)
            }
        }
        .scaleEffect(selected ? 1.08 : (dwell > 0 ? 1 + dwell * 0.15 : 1))
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: selected)
        .frame(width: diameter + 16, height: diameter + 16)
        .contentShape(Circle())
    }

    @ViewBuilder
    private var fill: some View {
        switch item {
        case .paint(let index):
            Circle().fill(Palette.color(Palette.paints[index]))
        case .rainbow:
            Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red],
                                          center: .center))
        case .style:
            ZStack {
                Circle().fill(style == .paper ? Color(white: 0.12) : Color(white: 0.96))
                Image(systemName: style == .paper ? "moon.stars.fill" : "sun.max.fill")
                    .font(.system(size: diameter * 0.45, weight: .semibold))
                    .foregroundStyle(style == .paper ? Color.yellow : Color.orange)
            }
        }
    }
}

private struct ControlButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

private struct GestureGuideView: View {
    let dismiss: () -> Void

    private struct Row: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private let rows: [Row] = [
        Row(symbol: "hand.point.up.left.fill", title: "Point", detail: "Draw flowing paint with your index finger"),
        Row(symbol: "wind", title: "Flick", detail: "Move fast to throw a splash"),
        Row(symbol: "hand.pinch.fill", title: "Pinch", detail: "Stir and swirl the paint without adding color"),
        Row(symbol: "hand.raised.fingers.spread.fill", title: "Open hand", detail: "Five fingers, five colors"),
        Row(symbol: "scope", title: "Hover a swatch", detail: "Hold your fingertip over a color to pick it"),
        Row(symbol: "drop.fill", title: "Hold a fist", detail: "Wash the canvas clean"),
        Row(symbol: "music.note", title: "Listen", detail: "Your strokes play music: higher on screen, higher notes"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 16) {
                Text("Splash Canvas")
                    .font(.largeTitle.weight(.bold))
                Text("Face the camera and paint in the air, about an arm's length away.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(rows) { row in
                    HStack(spacing: 14) {
                        Image(systemName: row.symbol)
                            .font(.title2)
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.headline)
                            Text(row.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Raise your hand to start · tap to close")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(24)
            .onTapGesture(perform: dismiss)
        }
    }
}

private struct CameraNoticeView: View {
    let denied: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash.fill").font(.largeTitle)
            Text(denied ? "Camera access is off" : "No front camera available")
                .font(.headline)
            Text(denied
                 ? "Splash Canvas needs the camera to follow your hands. Video never leaves your device. You can still paint by touch."
                 : "You can still paint by touching the screen.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if denied {
                Button("Open Settings") { Platform.openCameraSettings() }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
