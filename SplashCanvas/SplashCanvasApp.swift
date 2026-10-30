import SwiftUI

@main
struct SplashCanvasApp: App {
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        #else
        WindowGroup {
            ContentView()
        }
        #endif
    }
}
