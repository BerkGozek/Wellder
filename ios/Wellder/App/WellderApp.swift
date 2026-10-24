import SwiftUI

@main
struct WellderApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
                .onOpenURL { delegate.model.handle(url: $0) }
                .task { await delegate.model.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await delegate.model.becameActive() } }
            if phase == .background { delegate.model.enteredBackground() }
        }
    }
}
