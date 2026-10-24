import CoreImage.CIFilterBuiltins
import DesignSystem
import Networking
import SharedModels
import SwiftUI

struct CaregiversView: View {
    @Environment(AppModel.self) private var model
    let monitor: AlphaMonitor
    @State private var relationships: [MonitoringRelationship] = []
    @State private var invitation: CreatedInvitation?
    @State private var invitePermissions = PermissionSet.defaults
    @State private var showInviteSheet = false
    @State private var error: String?
    @State private var loading = false

    var pending: [MonitoringRelationship] { relationships.filter { $0.status == .pendingAlphaApproval } }
    var active: [MonitoringRelationship] { relationships.filter { $0.status == .active } }

    var body: some View {
        NavigationStack {
            List {
                if let error { ErrorBanner(error) { Task { await load() } } }
                if !pending.isEmpty {
                    Section("Waiting for your approval") {
                        ForEach(pending) { rel in
                            NavigationLink(value: rel) {
                                Label("\(rel.betaName) wants to connect", systemImage: "person.badge.clock").accessibilityIdentifier("pending-\(rel.betaName)")
                            }
                        }
                    }
                }
                Section {
                    if active.isEmpty && !loading {
                        Text("Nobody can see your information yet.").foregroundStyle(.secondary)
                    }
                    ForEach(active) { rel in
                        NavigationLink(value: rel) {
                            HStack {
                                InitialsAvatar(name: rel.betaName)
                                VStack(alignment: .leading) {
                                    Text(rel.betaName).font(.headline)
                                    Text(sharedSummary(rel.permissions)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityIdentifier("caregiver-\(rel.betaName)")
                    }
                } header: {
                    Text("Your caregivers")
                }
                Section {
                    Button { showInviteSheet = true } label: { Label("Invite a caregiver", systemImage: "person.badge.plus") }
                        .accessibilityIdentifier("inviteCaregiver")
                }
            }
            .navigationTitle("Caregivers")
            .navigationDestination(for: MonitoringRelationship.self) { rel in
                RelationshipDetailView(relationship: rel) { await load() }
            }
            .task { await load() }
            .refreshable { await load() }
            .sheet(isPresented: $showInviteSheet) { inviteSheet }
        }
    }

    private var inviteSheet: some View {
        NavigationStack {
            Form {
                if let invitation {
                    Section {
                        VStack(spacing: 16) {
                            Text("Give this code to your caregiver").font(.headline)
                            Text(invitation.code.chunked)
                                .font(.system(size: 40, weight: .bold, design: .monospaced))
                                .accessibilityIdentifier("inviteCode")
                                .accessibilityLabel(invitation.code.map(String.init).joined(separator: " "))
                            if let qr = QRCode.image(for: invitation.link) {
                                Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(width: 200, height: 200)
                                    .accessibilityLabel("QR code for the invitation")
                            }
                            Text("They can scan the QR code with their iPhone camera. The code works once and expires \(invitation.invitation.expiresAt, style: .relative).")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            ShareLink(item: "Join me on Wellder with code \(invitation.code): \(invitation.link)")
                        }
                        .frame(maxWidth: .infinity)
                    } footer: {
                        Text("When they enter it, you'll be asked to approve them here. They see nothing until you do.")
                    }
                } else {
                    Section("What this person will be able to see") {
                        PermissionToggles(permissions: $invitePermissions)
                    }
                    Section {
                        Button("Create invitation code") {
                            Task {
                                do { invitation = try await model.api.createInvitation(permissions: invitePermissions) } catch { self.error = error.localizedDescription }
                            }
                        }
                        .accessibilityIdentifier("createInvite")
                    }
                }
            }
            .navigationTitle("Invite")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showInviteSheet = false; invitation = nil; Task { await load() } }.accessibilityIdentifier("inviteDone")
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            relationships = try await model.api.relationships().asAlpha
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sharedSummary(_ p: PermissionSet) -> String {
        let shared = Permission.allCases.filter { p[$0] }.map(\.title)
        return shared.isEmpty ? "Sees nothing" : shared.joined(separator: " · ")
    }
}

struct PermissionToggles: View {
    @Binding var permissions: PermissionSet
    var body: some View {
        ForEach(Permission.allCases) { p in
            Toggle(p.title, isOn: Binding(get: { permissions[p] }, set: { permissions[p] = $0 }))
                .accessibilityIdentifier("perm-\(p.rawValue)")
        }
    }
}

struct RelationshipDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var relationship: MonitoringRelationship
    let onChange: () async -> Void
    @State private var confirmRevoke = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: relationship.betaName)
                LabeledContent("Email", value: relationship.betaEmail)
            }
            Section {
                PermissionToggles(permissions: $relationship.permissions)
            } header: {
                Text("What \(relationship.betaName) can see and do")
            } footer: {
                Text("\"Suggest\" permissions let them propose changes; nothing changes unless you approve.")
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if relationship.status == .pendingAlphaApproval {
                Section {
                    Button("Approve \(relationship.betaName)") { Task { await act { try await model.api.approve(relationship.relationshipId, permissions: relationship.permissions) } } }
                        .accessibilityIdentifier("approveCaregiver")
                    Button("Decline", role: .destructive) { Task { await act { try await model.api.reject(relationship.relationshipId) } } }
                }
            } else {
                Section {
                    Button("Save changes") { Task { await act { try await model.api.updatePermissions(relationship.relationshipId, relationship.permissions) } } }
                    Button("Stop sharing with \(relationship.betaName)", role: .destructive) { confirmRevoke = true }
                        .accessibilityIdentifier("revokeCaregiver")
                }
            }
        }
        .navigationTitle(relationship.betaName)
        .confirmationDialog("Stop sharing?", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("Stop sharing", role: .destructive) { Task { await act { try await model.api.revoke(relationship.relationshipId) } } }
                .accessibilityIdentifier("confirmRevoke")
        } message: {
            Text("\(relationship.betaName) will immediately lose access to everything you share.")
        }
    }

    private func act(_ op: () async throws -> MonitoringRelationship) async {
        do {
            relationship = try await op()
            await onChange()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum QRCode {
    static func image(for string: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension String {
    /// "ABCD EFGH" for readability.
    var chunked: String { count == 8 ? "\(prefix(4)) \(suffix(4))" : self }
}
