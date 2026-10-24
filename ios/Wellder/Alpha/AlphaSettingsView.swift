import DesignSystem
import SharedModels
import SwiftUI

struct AlphaSettingsView: View {
    @Bindable var monitor: AlphaMonitor
    @State private var draft: MonitoringSettings?
    @State private var saving = false
    @State private var savedAt: Date?

    var body: some View {
        NavigationStack {
            Form {
                if !monitor.pendingSettingsRequests.isEmpty {
                    Section("Suggestions from caregivers") {
                        ForEach(monitor.pendingSettingsRequests) { req in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(req.requestedByName) suggests changing \(req.changes.sectionNames)").font(.headline)
                                if let reason = req.reason { Text("“\(reason)”").font(.callout).foregroundStyle(.secondary) }
                                HStack {
                                    Button("Approve") { Task { await monitor.decide(req, approve: true); draft = monitor.settings } }
                                        .buttonStyle(.borderedProminent).accessibilityIdentifier("approveSettingsRequest")
                                    Button("Decline", role: .destructive) { Task { await monitor.decide(req, approve: false) } }.buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
                if let e = monitor.lastError { Section { Text(e).foregroundStyle(.red) } }
                if draft != nil {
                    Section {
                        Label(saving ? "Saving…" : draft != monitor.settings ? "Unsaved changes" : savedAt != nil ? "Changes saved" : "Changes save automatically",
                              systemImage: saving ? "arrow.triangle.2.circlepath" : draft != monitor.settings ? "pencil" : "checkmark.circle.fill")
                            .foregroundStyle(draft != monitor.settings && !saving ? .orange : .secondary)
                            .accessibilityIdentifier("settingsSaveStatus")
                    }
                    SettingsEditor(settings: Binding(get: { draft ?? monitor.settings }, set: { draft = $0 }))
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                    .disabled(saving || draft == monitor.settings)
                    .accessibilityIdentifier("saveSettings")
                }
            }
            // Save automatically shortly after the last change: a Save button alone was easy to
            // miss, and an unsaved alert threshold silently does nothing.
            .task(id: draft) {
                guard draft != nil, draft != monitor.settings, !saving else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await save()
            }
            .task {
                await monitor.refreshSettings()
                await monitor.loadSettingsRequests()
                draft = monitor.settings
            }
            .refreshable {
                await monitor.refreshSettings()
                await monitor.loadSettingsRequests()
                draft = monitor.settings
            }
        }
    }
}

extension AlphaSettingsView {
    private func save() async {
        guard let draft, draft != monitor.settings, !saving else { return }
        saving = true
        if await monitor.update(draft) { savedAt = Date() }
        // Keep edits made while the request was in flight; they trigger another save.
        if self.draft == draft { self.draft = monitor.settings }
        saving = false
    }
}

extension SettingsChanges {
    var sectionNames: String {
        var names: [String] = []
        if sleepSchedule != nil { names.append("night schedule") }
        if heartRate != nil { names.append("heart-rate alerts") }
        if movement != nil { names.append("movement & location") }
        if fallDetection != nil { names.append("fall detection") }
        if notifications != nil { names.append("notifications") }
        if emergency != nil { names.append("emergency contacts") }
        if dataRetention != nil { names.append("data retention") }
        if staleAfterMinutes != nil { names.append("data freshness") }
        return names.joined(separator: ", ")
    }
}
