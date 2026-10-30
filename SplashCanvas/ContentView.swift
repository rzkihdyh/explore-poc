import SwiftUI

struct ContentView: View {
    @State private var studio = Studio()
    @State private var tracker = HandTracker()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            CanvasView(studio: studio)
            HUDView(studio: studio, session: tracker.session)
        }
        .ignoresSafeArea()
        .immersive()
        .onAppear {
            Platform.keepAwake()
            studio.composer.start()
            startTracking()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                studio.composer.start()
                startTracking()
            case .background:
                tracker.stop()
                studio.composer.pause()
            default: break
            }
        }
    }

    private func startTracking() {
        let studio = studio
        tracker.onFrame = { frame in studio.ingest(frame) }
        tracker.start { status in
            switch status {
            case .running: studio.cameraStatus = .running
            case .denied: studio.cameraStatus = .denied
            case .unavailable: studio.cameraStatus = .unavailable
            }
        }
    }
}
