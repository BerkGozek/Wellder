import DesignSystem
import MonitoringCore
import SharedModels
import SwiftUI

struct AlphaRootView: View {
    @Bindable var monitor: AlphaMonitor
    let profile: UserProfile

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") { AlphaHomeView(monitor: monitor, profile: profile) }
            Tab("Caregivers", systemImage: "person.2.fill") { CaregiversView(monitor: monitor) }
            Tab("Settings", systemImage: "gearshape.fill") { AlphaSettingsView(monitor: monitor) }
            Tab("Privacy", systemImage: "hand.raised.fill") { PrivacyView(monitor: monitor) }
        }
        .fullScreenCover(isPresented: $monitor.showFallPrompt) { FallPromptView(monitor: monitor) }
        .fullScreenCover(isPresented: Binding(get: { monitor.falseAlarm != nil }, set: { if !$0 { monitor.stopOwnAlarm() } })) {
            FalseAlarmView(monitor: monitor)
        }
    }
}

struct AlphaHomeView: View {
    @Environment(AppModel.self) private var model
    let monitor: AlphaMonitor
    let profile: UserProfile
    @State private var confirmHelp = false
    @State private var helpSent = false
    @State private var checkedIn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statusCard
                    if monitor.needsPermissions {
                        ErrorBanner("Wellder needs permission to share your information.") { Task { await monitor.requestPermissions() } }
                    }
                    BigButton(helpSent ? "Help request sent" : "Get help", systemImage: "sos", tint: .red) { confirmHelp = true }
                        .accessibilityIdentifier("helpButton")
                        .accessibilityHint("Asks you to confirm, then alerts your caregivers")
                    BigButton(checkedIn ? "Thanks! Caregivers can see you checked in" : "I'm okay today", systemImage: "hand.thumbsup.fill", tint: .green) {
                        Task { await monitor.checkIn(); checkedIn = true }
                    }
                    .accessibilityIdentifier("checkInButton")
                    EmergencyCallButton(number: monitor.settings.emergency.emergencyNumber)
                    if model.simulationEnabled { SimulationControlsView(monitor: monitor) }
                    Text(MonitoringDisclaimer.short).font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Hello, \(profile.name.split(separator: " ").first.map(String.init) ?? profile.name)")
            .toolbar { AccountMenu() }
            .refreshable { await monitor.runCycle(reason: "pull") }
            .confirmationDialog("Send a help request to your caregivers?", isPresented: $confirmHelp, titleVisibility: .visible) {
                Button("Yes, alert my caregivers", role: .destructive) { Task { await monitor.requestHelp(); helpSent = true } }
                    .accessibilityIdentifier("confirmHelp")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This does not call emergency services. If you are in danger, use \"Call \(monitor.settings.emergency.emergencyNumber)\".")
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(monitor.state.title, systemImage: monitor.state.symbol)
                .font(.title2.bold())
                .foregroundStyle(monitor.state.tint)
                .accessibilityIdentifier("monitoringState")
            Text(MonitoringStateModel.explanation(monitor.state)).font(.body)
            if let last = monitor.lastUpload {
                Text("Last shared \(RelativeTime.short(last, now: Date()))").font(.subheadline).foregroundStyle(.secondary)
            }
            if monitor.pendingItems > 0 {
                Text("\(monitor.pendingItems) update(s) waiting to be sent").font(.subheadline).foregroundStyle(.orange)
                    .accessibilityIdentifier("pendingItems")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

/// Manual emergency call using the system phone UI (iOS asks for confirmation).
/// Wellder never dials emergency services automatically.
struct EmergencyCallButton: View {
    let number: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: "tel://\(number)") { openURL(url) }
        } label: {
            Label("Call \(number)", systemImage: "phone.fill")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .accessibilityHint("Opens the phone app to call emergency services")
    }
}

struct FallPromptView: View {
    @Bindable var monitor: AlphaMonitor

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "figure.fall").font(.system(size: 80)).foregroundStyle(.red).accessibilityHidden(true)
            if let outcome = monitor.lastFallOutcome {
                Text(outcome == .needHelp ? "Your caregivers are being alerted." : "No answer — your caregivers are being alerted.")
                    .font(.title.bold()).multilineTextAlignment(.center)
                EmergencyCallButton(number: monitor.settings.emergency.emergencyNumber)
                Button("Close") { monitor.dismissFallPrompt() }.font(.title3)
            } else {
                Text("Possible fall detected").font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text("Are you okay?").font(.title)
                if let remaining = monitor.fall.secondsRemaining(now: monitor.fallNow) {
                    Text("Caregivers will be alerted in \(remaining) s").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("fallCountdown")
                }
                BigButton("I'm okay", systemImage: "checkmark.circle.fill", tint: .green) { monitor.respondToFall(.userOk) }
                    .accessibilityIdentifier("fallOk")
                BigButton("I need help", systemImage: "exclamationmark.triangle.fill", tint: .red) { monitor.respondToFall(.needHelp) }
                    .accessibilityIdentifier("fallHelp")
            }
            Spacer()
            if monitor.simulation { Text("SIMULATION").font(.caption.bold()).foregroundStyle(.purple) }
        }
        .padding(24)
    }
}

/// Red alarm with the false-alarm countdown. Caregivers are alerted only if it runs out (or the
/// Alpha asks for help).
struct FalseAlarmView: View {
    @Bindable var monitor: AlphaMonitor
    @State private var busy = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "heart.fill").font(.system(size: 80)).foregroundStyle(.white).symbolEffect(.pulse).accessibilityHidden(true)
            Text(monitor.falseAlarm?.text ?? "").font(.largeTitle.bold()).foregroundStyle(.white).multilineTextAlignment(.center)
            if let deadline = monitor.falseAlarm?.deadline {
                let remaining = max(0, Int(deadline.timeIntervalSince(monitor.falseAlarmNow).rounded(.up)))
                Text("Your caregivers will be alerted in").font(.title3).foregroundStyle(.white.opacity(0.9))
                Text("\(remaining) s").font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(.white)
                    .accessibilityIdentifier("falseAlarmCountdown")
                Spacer()
                answer("False alarm — I'm okay", icon: "checkmark.circle.fill", fg: .green, id: "falseAlarmOk") { await monitor.answerFalseAlarm(.ok) }
                answer("Get help now", icon: "exclamationmark.triangle.fill", fg: .red, id: "falseAlarmHelp") { await monitor.answerFalseAlarm(.help) }
            } else {
                Text("Your caregivers have been alerted.").font(.title2.bold()).foregroundStyle(.white).multilineTextAlignment(.center)
                Spacer()
                EmergencyCallButton(number: monitor.settings.emergency.emergencyNumber)
                Button { monitor.stopOwnAlarm() } label: {
                    Text("Stop alarm").font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.red)
                .accessibilityIdentifier("stopOwnAlarm")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.red.gradient)
        .interactiveDismissDisabled()
    }

    private func answer(_ title: String, icon: String, fg: Color, id: String, action: @escaping () async -> Void) -> some View {
        Button {
            busy = true
            Task { await action(); busy = false }
        } label: {
            Label(title, systemImage: icon).font(.title2.bold()).frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(fg).disabled(busy)
        .accessibilityIdentifier(id)
    }
}
