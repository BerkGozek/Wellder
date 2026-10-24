import DesignSystem
import MonitoringCore
import Networking
import SharedModels
import SwiftUI

struct AlertRow: View {
    let alert: SharedModels.Alert
    var name: String?

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: alert.type.symbolName).foregroundStyle(alert.severity.color).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text((alert.simulated ? "[SIMULATION] " : "") + alert.title).font(.headline)
                if let name { Text(name).font(.subheadline) }
                Text("\(alert.status.label) · \(RelativeTime.short(alert.detectedAt, now: Date()))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension AlertStatus {
    var label: String {
        switch self {
        case .awaitingAlphaResponse: "Waiting for their answer"
        case .open: "Needs attention"
        case .acknowledged: "Acknowledged"
        case .resolved: "Resolved"
        }
    }
}

struct AlphaAlertsView: View {
    @Environment(AppModel.self) private var model
    let alphaId: String
    let onChange: () async -> Void
    @State private var alerts: [SharedModels.Alert] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        List {
            if let error { ErrorBanner(error) }
            let open = alerts.filter { $0.isUnresolved }
            let history = alerts.filter { !$0.isUnresolved }
            Section("Active") {
                if open.isEmpty && loaded { Text("No active alerts").foregroundStyle(.secondary) }
                ForEach(open) { a in link(a) }
            }
            Section("History") {
                ForEach(history) { a in link(a) }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func link(_ a: SharedModels.Alert) -> some View {
        NavigationLink {
            AlertDetailView(alphaId: alphaId, alertId: a.alertId) { await load(); await onChange() }
        } label: {
            AlertRow(alert: a)
        }
        .accessibilityIdentifier("alert-\(a.type.rawValue)")
    }

    private func load() async {
        do {
            alerts = try await model.api.alerts(alphaId: alphaId).alerts
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }
}

/// Shows each lifecycle stage separately — detected, received, notification sent, delivery
/// confirmed, acknowledged — because one never implies the next.
struct AlertDetailView: View {
    @Environment(AppModel.self) private var model
    let alphaId: String
    let alertId: String
    let onChange: () async -> Void
    @State private var detail: AlertDetail?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        List {
            if let error { ErrorBanner(error) }
            if let d = detail {
                let a = d.alert
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label((a.simulated ? "[SIMULATION] " : "") + a.title, systemImage: a.type.symbolName).font(.title3.bold()).foregroundStyle(a.severity.color)
                        Text(a.message)
                        Text(a.category == .safety ? "Safety alert" : "Technical alert — about monitoring, not about their health").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Timeline") {
                    stage("Detected", a.detectedAt)
                    stage("Received by server", a.receivedAt)
                    stage("Notification sent", a.firstNotificationSentAt, missing: a.status == .awaitingAlphaResponse ? "Waiting for their answer first" : "Not yet")
                    stage("Delivery confirmed", a.firstDeliveryConfirmedAt, missing: "Not confirmed (push delivery can't always be confirmed)")
                    stage("Acknowledged", a.acknowledgedAt)
                    stage("Resolved", a.resolvedAt)
                    if let next = a.nextEscalationAt { LabeledContent("Next escalation", value: next.formatted(date: .omitted, time: .shortened)) }
                    if a.occurrences > 1 { LabeledContent("Repeated", value: "\(a.occurrences) times") }
                }
                if let evidence = a.evidence, !evidence.isEmpty {
                    Section("Details") {
                        ForEach(evidence.keys.sorted(), id: \.self) { k in LabeledContent(k, value: evidence[k]?.description ?? "") }
                    }
                }
                Section("Notifications to you") {
                    if d.deliveries.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(d.deliveries) { del in
                        LabeledContent("\(del.channel.rawValue) · step \(del.escalationStep)", value: del.status.rawValue + (del.detail.map { " — \($0)" } ?? ""))
                            .font(.callout)
                    }
                }
                if a.isUnresolved {
                    Section {
                        if a.status != .acknowledged {
                            Button("I'm on it (acknowledge)") { Task { await act { _ = try await model.api.acknowledge(alphaId: alphaId, alertId: alertId) } } }
                                .disabled(busy).accessibilityIdentifier("acknowledgeAlert")
                        }
                        Button("Mark resolved") { Task { await act { _ = try await model.api.resolve(alphaId: alphaId, alertId: alertId) } } }.disabled(busy)
                            .accessibilityIdentifier("resolveAlert")
                        Button("False alarm") { Task { await act { _ = try await model.api.resolve(alphaId: alphaId, alertId: alertId, falseAlarm: true) } } }.disabled(busy)
                    } footer: {
                        Text("Acknowledging stops further escalation (texts and calls) to other caregivers.")
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Alert")
        .task { await load() }
    }

    private func stage(_ title: String, _ date: Date?, missing: String = "—") -> some View {
        LabeledContent(title, value: date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? missing)
    }

    private func act(_ op: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await op()
            await load()
            await onChange()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func load() async {
        do {
            detail = try await model.api.alertDetail(alphaId: alphaId, alertId: alertId)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
