import DesignSystem
import Networking
import SharedModels
import SwiftUI

/// Caregivers can view settings and — with permission — PROPOSE changes. Nothing changes until
/// the Alpha approves the request in their app.
struct BetaSettingsView: View {
    @Environment(AppModel.self) private var model
    let alphaId: String
    let permissions: SummaryPermissions
    @State private var original: MonitoringSettings?
    @State private var draft: MonitoringSettings?
    @State private var reason = ""
    @State private var requests: [SettingsChangeRequest] = []
    @State private var message: String?
    @State private var error: String?

    var editable: Set<SettingsEditor.Section> {
        var s: Set<SettingsEditor.Section> = []
        if permissions.allows(.manageSettings) { s.formUnion([.sleep, .heartRate, .movement, .fall, .notifications, .retention]) }
        if permissions.allows(.manageEmergencyContacts) { s.insert(.emergency) }
        return s
    }

    var body: some View {
        Form {
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if editable.isEmpty {
                Section { Text("You can view these settings. Ask them for permission to suggest changes.").foregroundStyle(.secondary) }
            }
            if draft != nil {
                SettingsEditor(settings: Binding(get: { draft ?? original! }, set: { draft = $0 }), editable: editable)
            }
            if !editable.isEmpty, let draft, let original, draft != original {
                Section("Send suggestion") {
                    TextField("Why? (optional)", text: $reason)
                    Button("Ask them to approve this change") {
                        Task {
                            do {
                                _ = try await model.api.requestSettingsChange(alphaId: alphaId, changes: SettingsChanges.diff(from: original, to: draft),
                                                                              reason: reason.isEmpty ? nil : reason)
                                message = "Sent. It will apply once they approve it."
                                self.draft = original
                                await load()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .accessibilityIdentifier("sendSettingsRequest")
                }
            }
            if let message { Section { Label(message, systemImage: "paperplane").accessibilityIdentifier("settingsRequestSent") } }
            if !requests.isEmpty {
                Section("Your suggestions") {
                    ForEach(requests) { r in LabeledContent(r.changes.sectionNames, value: r.status.rawValue) }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let s = try await model.api.settings(alphaId: alphaId)
            original = s
            draft = s
            requests = (try? await model.api.settingsRequests(alphaId: alphaId)) ?? []
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
