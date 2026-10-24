import DesignSystem
import MonitoringCore
import Networking
import SharedModels
import SwiftUI

struct AlphaDetailView: View {
    @Environment(AppModel.self) private var model
    let alphaId: String
    let initial: AlphaSummary?
    let onChange: () async -> Void
    @State private var summary: AlphaSummary?
    @State private var tab: DetailTab = .overview
    @State private var error: String?

    enum DetailTab: String, CaseIterable, Identifiable {
        case overview = "Overview", location = "Location", heart = "Heart", activity = "Activity", alerts = "Alerts", settings = "Settings"
        var id: String { rawValue }
    }

    var current: AlphaSummary? { summary ?? initial }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(availableTabs) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityIdentifier("detailTabs")
            if let error { ErrorBanner(error) { Task { await load() } }.padding(.horizontal) }
            Group {
                switch tab {
                case .overview: OverviewSection(summary: current)
                case .location: LocationHistoryView(alphaId: alphaId, canSeeHistory: current?.permissions.allows(.viewMovementHistory) ?? false)
                case .heart: HeartRateView(alphaId: alphaId)
                case .activity: ActivityView(alphaId: alphaId)
                case .alerts: AlphaAlertsView(alphaId: alphaId) { await load(); await onChange() }
                case .settings: BetaSettingsView(alphaId: alphaId, permissions: current?.permissions ?? .granted(PermissionSet()))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle(current?.name ?? "")
        .task { await load() }
    }

    private var availableTabs: [DetailTab] {
        guard let p = current?.permissions else { return [.overview] }
        return DetailTab.allCases.filter { t in
            switch t {
            case .overview, .settings: true
            case .location: p.allows(.viewLocation)
            case .heart: p.allows(.viewHeartRate)
            case .activity: p.allows(.viewActivity)
            case .alerts: p.allows(.receiveAlerts)
            }
        }
    }

    private func load() async {
        do {
            summary = try await model.api.summary(alphaId: alphaId)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct OverviewSection: View {
    let summary: AlphaSummary?

    var body: some View {
        ScrollView {
            if let s = summary {
                let now = Date()
                let snap = s.snapshot
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        StatusBadge(s.status)
                        Spacer()
                        if snap.simulated == true { Label("Simulated", systemImage: "testtube.2").font(.caption.bold()).foregroundStyle(.purple) }
                    }
                    Text(s.statusReason).font(.title3.weight(.semibold)).accessibilityIdentifier("statusReason")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        if s.permissions.allows(.viewHeartRate) {
                            MetricTile(title: "Heart rate", systemImage: "heart.fill", value: snap.lastHeartRate.map { "\(Int($0.bpm))" }, unit: "bpm",
                                       timestamp: snap.lastHeartRate?.timestamp, freshness: MetricFreshness.heartRate(snap.lastHeartRate?.timestamp, now: now), now: now)
                                .accessibilityIdentifier("heartRateTile")
                        }
                        if s.permissions.allows(.viewActivity) {
                            MetricTile(title: "Last movement", systemImage: "figure.walk", value: snap.lastMovementAt.map { RelativeTime.short($0, now: now) },
                                       timestamp: snap.lastMovementAt, freshness: MetricFreshness.activity(snap.lastMovementAt, now: now), now: now)
                            MetricTile(title: "Recent steps", systemImage: "shoeprints.fill", value: snap.recentSteps.map { "\($0.count)" },
                                       timestamp: snap.recentSteps?.to, freshness: MetricFreshness.activity(snap.recentSteps?.to, now: now), now: now)
                            MetricTile(title: "Opened Wellder", systemImage: "hand.tap.fill", value: snap.lastInteractionAt.map { RelativeTime.short($0, now: now) },
                                       timestamp: snap.lastInteractionAt, freshness: MetricFreshness.activity(snap.lastInteractionAt, now: now), now: now)
                        }
                        if s.permissions.allows(.viewLocation) {
                            MetricTile(title: "Location", systemImage: "location.fill",
                                       value: snap.lastLocation.map { "±\(Int($0.horizontalAccuracy)) m" },
                                       timestamp: snap.lastLocation?.timestamp, freshness: MetricFreshness.location(snap.lastLocation?.timestamp, now: now), now: now)
                        }
                        MetricTile(title: "Last sync", systemImage: "arrow.triangle.2.circlepath", value: snap.lastSyncAt.map { RelativeTime.short($0, now: now) },
                                   timestamp: snap.lastSyncAt, freshness: MetricFreshness.sync(snap.lastSyncAt, now: now, staleAfterMinutes: s.staleAfterMinutes), now: now)
                    }
                    if let state = snap.monitoringState {
                        Label("Their phone reports: \(state.title)", systemImage: state.symbol).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let b = snap.batteryLevel { Label("Phone battery \(Int(b * 100))%", systemImage: "battery.50percent").font(.subheadline).foregroundStyle(.secondary) }
                    if s.isNight { Label("Night mode — location sharing reduced", systemImage: "moon.fill").font(.subheadline) }
                    Text("Heart rate is measured periodically by Apple Watch, not continuously. \"Last movement\" comes from the phone's motion sensors and only reflects movement while the phone is carried.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            } else {
                ProgressView().padding()
            }
        }
    }
}
