import Foundation
import SharedModels

// Typed wrappers for every backend route (see docs/api.md).

public struct ProfileResponse: Codable, Sendable { public var profile: UserProfile? }
public struct InvitationsResponse: Codable, Sendable { public var invitations: [Invitation] }
public struct RelationshipResponse: Codable, Sendable { public var relationship: MonitoringRelationship }
public struct SettingsResponse: Codable, Sendable { public var settings: MonitoringSettings }
public struct SettingsRequestResponse: Codable, Sendable { public var request: SettingsChangeRequest }
public struct SettingsRequestsResponse: Codable, Sendable { public var requests: [SettingsChangeRequest] }
public struct DecisionResponse: Codable, Sendable { public var request: SettingsChangeRequest; public var settings: MonitoringSettings }
public struct AlertResponse: Codable, Sendable { public var alert: Alert }
public struct AuditResponse: Codable, Sendable { public var entries: [AuditEntry] }
public struct DeleteResponse: Codable, Sendable { public var deleted: Int }

private struct CodeBody: Codable, Sendable { var code: String }
private struct PermissionsBody: Codable, Sendable { var permissions: PermissionSet }
private struct SettingsUpdateBody: Codable, Sendable { var version: Int; var changes: SettingsChanges }
private struct SettingsRequestBody: Codable, Sendable { var changes: SettingsChanges; var reason: String? }
private struct ResolveBody: Codable, Sendable { var resolution: String }
private struct RespondBody: Codable, Sendable { var response: String }
private struct OptionalAlertResponse: Codable, Sendable { var alert: Alert? }

/// The monitored person's answer during an alert's false-alarm window.
public enum AlarmResponse: String, Sendable {
    /// False alarm: resolves the alert; caregivers are never notified.
    case ok
    /// Notify caregivers now, as urgent.
    case help
    /// The countdown ran out on the device: notify caregivers now.
    case noResponse
}

public extension APIClient {
    // Account
    func me() async throws -> UserProfile? { try await send("GET", "v1/me", as: ProfileResponse.self).profile }
    func saveProfile(_ input: ProfileInput) async throws -> UserProfile {
        guard let p = try await send("PUT", "v1/me", body: input, as: ProfileResponse.self).profile else { throw APIError.decoding("missing profile") }
        return p
    }
    func deleteAccount() async throws -> Int { try await send("DELETE", "v1/me", as: DeleteResponse.self).deleted }
    func registerDevice(id: String, _ registration: DeviceRegistration) async throws {
        _ = try await send("PUT", "v1/devices/\(id)", body: registration, as: [String: Device].self)
    }

    // Pairing
    func createInvitation(permissions: PermissionSet) async throws -> CreatedInvitation {
        try await send("POST", "v1/invitations", body: PermissionsBody(permissions: permissions))
    }
    func invitations() async throws -> [Invitation] { try await send("GET", "v1/invitations", as: InvitationsResponse.self).invitations }
    func cancelInvitation(_ id: String) async throws { _ = try await send("DELETE", "v1/invitations/\(id)", as: [String: Bool].self) }
    func redeemInvitation(code: String) async throws -> MonitoringRelationship {
        try await send("POST", "v1/invitations/redeem", body: CodeBody(code: code), as: RelationshipResponse.self).relationship
    }
    func relationships() async throws -> RelationshipsResponse { try await send("GET", "v1/relationships") }
    func approve(_ relationshipId: String, permissions: PermissionSet) async throws -> MonitoringRelationship {
        try await send("POST", "v1/relationships/\(relationshipId)/approve", body: PermissionsBody(permissions: permissions), as: RelationshipResponse.self).relationship
    }
    func reject(_ relationshipId: String) async throws -> MonitoringRelationship {
        try await send("POST", "v1/relationships/\(relationshipId)/reject", as: RelationshipResponse.self).relationship
    }
    func revoke(_ relationshipId: String) async throws -> MonitoringRelationship {
        try await send("POST", "v1/relationships/\(relationshipId)/revoke", as: RelationshipResponse.self).relationship
    }
    func updatePermissions(_ relationshipId: String, _ permissions: PermissionSet) async throws -> MonitoringRelationship {
        try await send("PUT", "v1/relationships/\(relationshipId)/permissions", body: PermissionsBody(permissions: permissions), as: RelationshipResponse.self).relationship
    }

    // Telemetry
    func uploadTelemetry(_ batch: TelemetryBatch) async throws -> IngestResult { try await send("POST", "v1/telemetry", body: batch) }

    // Monitoring reads
    func dashboard() async throws -> DashboardResponse { try await send("GET", "v1/dashboard") }
    func summary(alphaId: String) async throws -> AlphaSummary { try await send("GET", "v1/alphas/\(alphaId)/summary", as: SummaryResponse.self).summary }
    func locations(alphaId: String, from: Date, to: Date) async throws -> LocationHistory {
        try await send("GET", "v1/alphas/\(alphaId)/locations", query: range(from, to))
    }
    func heartRate(alphaId: String, from: Date, to: Date) async throws -> HeartRateHistory {
        try await send("GET", "v1/alphas/\(alphaId)/heart-rate", query: range(from, to))
    }
    func activity(alphaId: String, from: Date, to: Date) async throws -> ActivityHistory {
        try await send("GET", "v1/alphas/\(alphaId)/activity", query: range(from, to))
    }
    func alerts(alphaId: String, limit: Int = 50) async throws -> AlertList {
        try await send("GET", "v1/alphas/\(alphaId)/alerts", query: [URLQueryItem(name: "limit", value: String(limit))])
    }
    func alertDetail(alphaId: String, alertId: String) async throws -> AlertDetail { try await send("GET", "v1/alphas/\(alphaId)/alerts/\(alertId)") }
    func acknowledge(alphaId: String, alertId: String) async throws -> Alert {
        try await send("POST", "v1/alphas/\(alphaId)/alerts/\(alertId)/acknowledge", as: AlertResponse.self).alert
    }
    @discardableResult
    func respond(alphaId: String, alertId: String, _ response: AlarmResponse) async throws -> Alert? {
        try await send("POST", "v1/alphas/\(alphaId)/alerts/\(alertId)/respond", body: RespondBody(response: response.rawValue), as: OptionalAlertResponse.self).alert
    }

    func resolve(alphaId: String, alertId: String, falseAlarm: Bool = false) async throws -> Alert {
        try await send("POST", "v1/alphas/\(alphaId)/alerts/\(alertId)/resolve", body: ResolveBody(resolution: falseAlarm ? "falseAlarm" : "betaResolved"),
                       as: AlertResponse.self).alert
    }

    // Settings & consent
    func settings(alphaId: String) async throws -> MonitoringSettings { try await send("GET", "v1/alphas/\(alphaId)/settings", as: SettingsResponse.self).settings }
    func updateOwnSettings(version: Int, changes: SettingsChanges) async throws -> MonitoringSettings {
        try await send("PUT", "v1/me/settings", body: SettingsUpdateBody(version: version, changes: changes), as: SettingsResponse.self).settings
    }
    func requestSettingsChange(alphaId: String, changes: SettingsChanges, reason: String?) async throws -> SettingsChangeRequest {
        try await send("POST", "v1/alphas/\(alphaId)/settings-requests", body: SettingsRequestBody(changes: changes, reason: reason), as: SettingsRequestResponse.self).request
    }
    func settingsRequests(alphaId: String) async throws -> [SettingsChangeRequest] {
        try await send("GET", "v1/alphas/\(alphaId)/settings-requests", as: SettingsRequestsResponse.self).requests
    }
    func decideSettingsRequest(_ requestId: String, approve: Bool) async throws -> DecisionResponse {
        try await send("POST", "v1/me/settings-requests/\(requestId)/\(approve ? "approve" : "reject")")
    }
    func auditLog() async throws -> [AuditEntry] { try await send("GET", "v1/me/audit", as: AuditResponse.self).entries }

    private func range(_ from: Date, _ to: Date) -> [URLQueryItem] {
        [URLQueryItem(name: "from", value: WireJSON.formatISO8601(from)), URLQueryItem(name: "to", value: WireJSON.formatISO8601(to))]
    }
}

/// Server's device record (only decoded to confirm registration).
public struct Device: Codable, Sendable { public var deviceId: String }
