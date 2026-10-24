import DesignSystem
import SharedModels
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ProgressView("Loading…")
            case .signedOut:
                SignInView()
            case .needsProfile:
                OnboardingView()
            case .ready:
                if let profile = model.profile {
                    MainView(profile: profile)
                } else {
                    ProgressView()
                }
            }
        }
        .animation(.default, value: model.phase)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var model
    let profile: UserProfile

    var body: some View {
        VStack(spacing: 0) {
            if model.simulationEnabled && model.activeRole == .alpha { SimulationBanner() }
            switch model.activeRole {
            case .alpha:
                if let monitor = model.alphaMonitor {
                    AlphaRootView(monitor: monitor, profile: profile)
                } else {
                    ProgressView()
                }
            case .beta:
                BetaRootView(profile: profile)
            }
        }
    }
}
