import SwiftUI

@main
struct WellderWatchApp: App {
    @State private var model = WatchModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environment(model)
                .task { model.start() }
                .onChange(of: scenePhase, initial: true) { _, phase in model.setForeground(phase == .active) }
        }
    }
}
