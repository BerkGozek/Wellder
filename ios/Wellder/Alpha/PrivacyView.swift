import DesignSystem
import Networking
import SharedModels
import SwiftUI

struct PrivacyView: View {
    @Environment(AppModel.self) private var model
    let monitor: AlphaMonitor
    @State private var audit: [AuditEntry] = []
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section("Permissions on this iPhone") {
                    LabeledContent("Location", value: monitor.permissions.location)
                    LabeledContent("Apple Health", value: monitor.permissions.healthAsked ? "Asked (iOS doesn't reveal the answer)" : "Not asked")
                    LabeledContent("Motion & Fitness", value: monitor.permissions.motion ? "On" : "Off")
                    LabeledContent("Notifications", value: monitor.permissions.notifications ? "On" : "Off")
                    Button("Review permissions") { Task { await monitor.requestPermissions() } }
                    Button("Open iPhone Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section {
                    LabeledContent("Experimental fall detection", value: monitor.experimentalFallDetectionRunning ? "Running (app open)" : "Not running")
                    Text("Wellder cannot see how you use your phone or other apps. \"Last opened\" means the last time you opened Wellder.")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("What is measured")
                }
                Section("Recent changes") {
                    if audit.isEmpty { Text("No changes yet").foregroundStyle(.secondary) }
                    ForEach(audit.prefix(30)) { e in
                        VStack(alignment: .leading) {
                            Text(e.action.auditDescription).font(.subheadline)
                            Text(e.at, style: .date).font(.caption).foregroundStyle(.secondary) + Text(" ") + Text(e.at, style: .time).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button("Delete my account and all data", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("Removes your shared history, alerts, settings and every caregiver connection from Wellder's servers.")
                }
            }
            .navigationTitle("Privacy")
            .task { audit = (try? await model.api.auditLog()) ?? [] }
            .refreshable { audit = (try? await model.api.auditLog()) ?? [] }
            .confirmationDialog("Delete everything?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete account", role: .destructive) { Task { await model.deleteAccount() } }
            } message: {
                Text("This cannot be undone. Your caregivers will lose access immediately.")
            }
        }
    }
}

extension String {
    var auditDescription: String {
        switch self {
        case "alpha.onboarded": "You started sharing"
        case "invitation.created": "Invitation created"
        case "invitation.cancelled": "Invitation cancelled"
        case "relationship.requested": "A caregiver asked to connect"
        case "relationship.approved": "You approved a caregiver"
        case "relationship.rejected": "You declined a caregiver"
        case "relationship.revoked": "A connection was ended"
        case "relationship.removed": "A caregiver deleted their account"
        case "relationship.permissions_changed": "Sharing permissions changed"
        case "settings.updated": "You changed settings"
        case "settings.change_requested": "A caregiver suggested a settings change"
        case "settings.change_approved": "You approved a settings change"
        case "settings.change_rejected": "You declined a settings change"
        case "alert.acknowledged": "A caregiver acknowledged an alert"
        case "alert.resolved": "An alert was resolved"
        default: self
        }
    }
}
