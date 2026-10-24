import DesignSystem
import MonitoringCore
import Networking
import SharedModels
import SwiftUI
import UIKit

struct BetaRootView: View {
    @Environment(AppModel.self) private var model
    let profile: UserProfile
    @State private var dashboard = DashboardModel()

    var body: some View {
        @Bindable var dashboard = dashboard
        TabView {
            Tab("People", systemImage: "person.2.fill") { DashboardView(dashboard: dashboard) }
            Tab("Alerts", systemImage: "bell.badge.fill") { AllAlertsView(dashboard: dashboard) }
                .badge(dashboard.unacknowledgedCount)
        }
        .task {
            dashboard.api = model.api
            dashboard.setOvernightAlarm(dashboard.overnightAlarm)
            // Polling lives here, not in a tab, so it keeps running whichever tab is open (and in
            // the background while Overnight alarm keeps the app awake).
            await dashboard.poll()
        }
        .fullScreenCover(item: $dashboard.ringing) { alert in
            AlarmView(alert: alert, alphaName: dashboard.name(of: alert.alphaId)) {
                await dashboard.acknowledgeRinging()
            } silence: {
                dashboard.silenceRinging()
            }
        }
    }
}

/// Full-screen alarm for a new alert. The sound loops until the caregiver acknowledges or silences.
struct AlarmView: View {
    let alert: SharedModels.Alert
    let alphaName: String
    let acknowledge: () async -> Void
    let silence: () -> Void
    @State private var busy = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 72)).foregroundStyle(.white)
                .symbolEffect(.pulse)
            if alert.simulated { Text("SIMULATION").font(.headline).foregroundStyle(.white.opacity(0.9)) }
            Text(alphaName).font(.largeTitle.bold()).foregroundStyle(.white)
            Text(alert.title).font(.title2.bold()).foregroundStyle(.white).multilineTextAlignment(.center)
            Text(alert.message).font(.body).foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.center)
            Spacer()
            Button {
                busy = true
                Task { await acknowledge(); busy = false }
            } label: {
                Text("I'm on it — acknowledge").font(.title3.bold()).frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.red).disabled(busy)
            .accessibilityIdentifier("acknowledgeAlarm")
            Button("Silence alarm", action: silence).foregroundStyle(.white)
                .accessibilityIdentifier("silenceAlarm")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.red.gradient)
        .interactiveDismissDisabled()
    }
}

@MainActor
@Observable
final class DashboardModel {
    var api: APIClient?
    var alphas: [AlphaSummary] = []
    var pending: [MonitoringRelationship] = []
    var loading = false
    var loadedOnce = false
    var error: String?
    var lastRefreshed: Date?
    /// The alert currently sounding the alarm, if any.
    var ringing: SharedModels.Alert?
    var overnightAlarm = UserDefaults.standard.bool(forKey: "beta.overnightAlarm")
    /// Alerts silenced on this phone without acknowledging; they don't ring again while the app
    /// runs. Static, because SwiftUI can rebuild this screen (and this model) at any time, e.g.
    /// when the profile finishes loading; a per-instance set re-rang silenced alarms.
    private static var silenced: Set<String> = []
    private var silenced: Set<String> {
        get { Self.silenced }
        set { Self.silenced = newValue }
    }

    var unacknowledgedCount: Int { alphas.flatMap(\.openAlerts).filter(\.needsAttention).count }

    func refresh() async {
        guard let api else { return }
        loading = true
        defer { loading = false; loadedOnce = true }
        do {
            let d = try await api.dashboard()
            alphas = d.alphas
            pending = d.pending
            lastRefreshed = Date()
            error = nil
            ringIfNeeded()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func name(of alphaId: String) -> String { alphas.first { $0.alphaId == alphaId }?.name ?? "Someone you look after" }

    /// Rings for any open alert nobody has acknowledged yet ("awaiting response" fall prompts wait
    /// for the Alpha's answer first).
    private func ringIfNeeded() {
        guard ringing == nil,
              let alert = alphas.flatMap(\.openAlerts).first(where: { $0.status == .open && !silenced.contains($0.alertId) }) else { return }
        ringing = alert
        let title = "\(name(of: alert.alphaId)): \(alert.title)"
        Task {
            // System alarm first (breaks through silent and Focus); in-app alarm as the fallback.
            if await SystemAlarm.ring(alertId: alert.alertId, title: title) { return }
            AlarmPlayer.shared.start()
            if UIApplication.shared.applicationState != .active {
                AlarmPlayer.notify(id: alert.alertId, title: title, body: alert.message)
            }
        }
    }

    func acknowledgeRinging() async {
        guard let alert = ringing, let api else { return }
        do {
            _ = try await api.acknowledge(alphaId: alert.alphaId, alertId: alert.alertId)
            silenced.insert(alert.alertId)
            stopRinging()
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func silenceRinging() {
        if let id = ringing?.alertId { silenced.insert(id) }
        stopRinging()
    }

    private func stopRinging() {
        if let id = ringing?.alertId { SystemAlarm.stop(alertId: id) }
        ringing = nil
        AlarmPlayer.shared.stop()
    }

    func setOvernightAlarm(_ on: Bool) {
        overnightAlarm = on
        UserDefaults.standard.set(on, forKey: "beta.overnightAlarm")
        AlarmPlayer.shared.keepAwake(on)
    }

    /// Polling every 30 s while the app runs. Push notifications cover urgent changes while
    /// backgrounded when configured (paid team); see docs/architecture.md for why this isn't a WebSocket.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(30))
        }
    }
}

struct DashboardView: View {
    @Environment(AppModel.self) private var model
    let dashboard: DashboardModel
    @State private var showRedeem = false

    var body: some View {
        NavigationStack {
            List {
                if let e = dashboard.error { ErrorBanner(e) { Task { await dashboard.refresh() } }.listRowSeparator(.hidden) }
                if !dashboard.pending.isEmpty {
                    Section("Waiting for approval") {
                        ForEach(dashboard.pending) { rel in
                            Label("\(rel.alphaName) hasn't approved you yet", systemImage: "hourglass").foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(dashboard.alphas) { alpha in
                        NavigationLink(value: alpha.alphaId) { AlphaCard(summary: alpha) }
                            .accessibilityIdentifier("alphaCard-\(alpha.name)")
                    }
                } footer: {
                    if let at = dashboard.lastRefreshed {
                        Text("Updated \(at, style: .time). Green means no concern was detected — not a guarantee of safety.")
                    }
                }
                Section {
                    Toggle(isOn: Binding(get: { dashboard.overnightAlarm }, set: { dashboard.setOvernightAlarm($0) })) {
                        Label("Overnight alarm", systemImage: "alarm.fill")
                    }
                    .accessibilityIdentifier("overnightAlarm")
                } footer: {
                    Text("Keeps Wellder running so an alert sounds a loud alarm even when this phone is locked or on silent. Uses more battery: keep the phone charging, with the volume up. Without it, alarms only sound while the app is open.")
                }
                if dashboard.loadedOnce && dashboard.alphas.isEmpty && dashboard.pending.isEmpty {
                    ContentUnavailableView {
                        Label("No one yet", systemImage: "person.2.slash")
                    } description: {
                        Text("Ask the person you look after to create an invitation in their Wellder app, then enter their code.")
                    } actions: {
                        Button("Enter invitation code") { showRedeem = true }.buttonStyle(.borderedProminent)
                    }
                    .accessibilityIdentifier("emptyDashboard")
                }
            }
            .navigationTitle("People")
            .navigationDestination(for: String.self) { alphaId in
                AlphaDetailView(alphaId: alphaId, initial: dashboard.alphas.first { $0.alphaId == alphaId }) { await dashboard.refresh() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showRedeem = true } label: { Image(systemName: "person.badge.plus").accessibilityLabel("Add a person") }
                        .accessibilityIdentifier("addAlpha")
                }
                AccountMenu()
            }
            .refreshable { await dashboard.refresh() }
            .onChange(of: model.dashboardRefreshToken) { Task { await dashboard.refresh() } }
            .sheet(isPresented: $showRedeem) { RedeemInviteView { await dashboard.refresh() } }
            .onChange(of: model.pendingInviteCode, initial: true) { _, code in if code != nil { showRedeem = true } }
        }
    }
}

struct AlphaCard: View {
    let summary: AlphaSummary

    var body: some View {
        let now = Date()
        let s = summary.snapshot
        HStack(alignment: .top, spacing: 12) {
            InitialsAvatar(name: summary.name, level: summary.status)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(summary.name).font(.headline)
                    Spacer()
                    StatusBadge(summary.status, compact: true)
                }
                Text(summary.statusReason).font(.subheadline).foregroundStyle(summary.status == .red ? .red : .primary)
                if s.simulated == true { Label("Simulated data", systemImage: "testtube.2").font(.caption).foregroundStyle(.purple) }
                Group {
                    if let hr = s.lastHeartRate {
                        let f = MetricFreshness.heartRate(hr.timestamp, now: now)
                        Label("\(Int(hr.bpm)) bpm · \(RelativeTime.short(hr.timestamp, now: now))\(f == .stale ? " (old)" : "")", systemImage: "heart.fill")
                    }
                    if let m = s.lastMovementAt { Label("Moved \(RelativeTime.short(m, now: now))", systemImage: "figure.walk") }
                    if let l = s.lastLocation { Label("Location \(RelativeTime.short(l.timestamp, now: now))", systemImage: "location.fill") }
                    Label(s.lastSyncAt.map { "Last sync \(RelativeTime.short($0, now: now))" } ?? "Never synced", systemImage: "arrow.triangle.2.circlepath")
                    if summary.isNight { Label("Night mode", systemImage: "moon.fill") }
                    if !summary.openAlerts.isEmpty { Label("\(summary.openAlerts.count) open alert(s)", systemImage: "bell.fill").foregroundStyle(.orange) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct RedeemInviteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onDone: () async -> Void
    @State private var code = ""
    @State private var result: String?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("8-character code", text: $code)
                        .font(.title2.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("inviteCodeField")
                } footer: {
                    Text("The person you look after creates this code in their app. They'll then approve you.")
                }
                if let result { Section { Label(result, systemImage: "checkmark.circle").accessibilityIdentifier("redeemResult") } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button("Send request") {
                        busy = true
                        Task {
                            do {
                                let rel = try await model.api.redeemInvitation(code: code)
                                result = "Request sent. \(rel.alphaName) needs to approve you."
                                error = nil
                                await onDone()
                            } catch {
                                self.error = error.localizedDescription
                            }
                            busy = false
                        }
                    }
                    .disabled(busy || code.filter(\.isLetter).count + code.filter(\.isNumber).count < 8)
                    .accessibilityIdentifier("redeemInvite")
                }
            }
            .navigationTitle("Add a person")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("redeemDone") } }
            .onAppear {
                if let c = model.pendingInviteCode { code = c; model.pendingInviteCode = nil }
            }
        }
    }
}

struct AllAlertsView: View {
    let dashboard: DashboardModel

    var body: some View {
        NavigationStack {
            List {
                let items = dashboard.alphas.flatMap { a in a.openAlerts.map { (a, $0) } }
                if items.isEmpty {
                    ContentUnavailableView("No open alerts", systemImage: "bell.slash", description: Text("Alerts that need attention appear here."))
                }
                ForEach(items, id: \.1.alertId) { alpha, alert in
                    NavigationLink {
                        AlertDetailView(alphaId: alpha.alphaId, alertId: alert.alertId) { await dashboard.refresh() }
                    } label: {
                        AlertRow(alert: alert, name: alpha.name)
                    }
                }
            }
            .navigationTitle("Alerts")
            .refreshable { await dashboard.refresh() }
        }
    }
}
