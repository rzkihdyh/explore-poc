# Splash Canvas — hand-gesture fluid painting (iOS)

A native take on Google Arts & Culture's Splash Canvas: a full-screen, real-time fluid paint simulation you play with by moving your hand in front of the front camera.

- **Hand tracking:** AVFoundation + Vision (`VNDetectHumanHandPoseRequest`), up to 2 hands, 60 fps capture when the camera supports it. Everything runs on the device.
- **Rendering:** a Metal compute fluid solver (stable fluids, vorticity confinement, Jacobi pressure solve) with a high-resolution paint field, plus a glossy wet-paint display shader in two styles (Paper and Night glow).

## Run it on a Mac (laptop)

1. Open `SplashCanvas.xcodeproj` in Xcode 26.
2. In the toolbar's run destination menu, pick **My Mac**.
3. Target → Signing & Capabilities: choose your team, then press **⌘R**.
4. Allow camera access when macOS asks. Sit back a little and raise your hand in front of the FaceTime camera.
   Mouse dragging paints too. The share button opens a save panel (PNG).

## Run it on iPhone / iPad

1. Open `SplashCanvas.xcodeproj` in Xcode 26 (iOS 17+ deployment target).
2. Target → Signing & Capabilities: choose your team and adjust the bundle id (`com.ihsanlab.SplashCanvas`) if needed.
3. Run on a **real iPhone or iPad**. Prop it up and stand or sit about an arm's length away.
   In the Simulator there's no camera, but touch painting still works.

## Gestures

| Gesture | Effect |
|---|---|
| ☝️ Point (index finger) | Paints a flowing stroke that drags the fluid along |
| Fast flick | Throws a splash of droplets and streaks |
| 🤏 Pinch | Stirs and swirls the paint without adding color |
| 🖐 Open hand | Five fingertips paint five neighboring colors |
| Hover a swatch (point at the top bar) | Picks that color after ~0.6 s (ring fills up) |
| ✊ Hold a fist (~1 s) | Washes the canvas clean |

The bottom-right buttons (help, camera preview, share, wash) are touch shortcuts.

## How the pieces fit

| File | Role |
|---|---|
| `HandTracker.swift` | Camera session (upright, mirrored buffers) + Vision hand pose on a background queue |
| `HandFeatures.swift` | Finger extension, pinch ratio and pose classification (with hysteresis) |
| `OneEuroFilter.swift` | Adaptive smoothing: steady when slow, low lag when fast. Also gives velocity for prediction |
| `Studio.swift` | Interaction model: hand matching, pose debouncing, prediction, brushes, splashes, hover-to-pick, HUD state |
| `FluidSimulator.swift` / `Shaders.metal` | GPU fluid solver and display shader |
| `Platform.swift` | iOS vs. macOS differences: canvas view, camera preview, touch/mouse input, sharing/saving |
| `CanvasRenderer.swift` | `MTKView` frame loop: hands → splats → fluid step → display; snapshots for sharing |
| `HUDView.swift` | Palette, status chip, camera preview with tracked joints, gesture guide |
| `Tuning.swift` | Every feel-related constant in one place |

### Latency and smoothness
Camera frames arrive at 30–60 Hz while the canvas renders at 60 Hz. Each hand point is One-Euro filtered at camera rate; at render rate the cursor eases toward a target **predicted** from the filtered velocity, so strokes stay smooth and keep up with the hand. Each brush dab is a capsule from the last cursor position to the new one, so fast strokes never break into dots.

## Tuning tips
- **Can't reach the edges / too twitchy:** change `Tuning.reachMin` / `reachMax` (the part of the camera image that maps to the whole canvas).
- **Strokes move the wrong way:** flip `HandTracker.mirrored` or change `rotationAngle`.
- **More or less swirl:** `FluidSimulator.Settings.paper/night` (`curl`, `velocityDissipation`).
- **Paint fades too fast/slow:** `dyeDissipation` (Paper keeps paint, Night lets it glow and fade).
- **Pinch/fist misfires:** thresholds in `HandFeatures.classify`.
