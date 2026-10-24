import Foundation
import Testing
@testable import SharedModels

/// Decodes JSON produced by the real backend (simulations/generate-fixtures.ts). If a TypeScript
/// model changes without its Swift mirror, these fail.
struct ContractTests {
    func fixture<T: Decodable>(_ name: String, as: T.Type = T.self) throws -> T {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try WireJSON.decoder().decode(T.self, from: Data(contentsOf: url))
    }

    struct ProfileEnvelope: Decodable { var profile: UserProfile }
    struct InvitationsEnvelope: Decodable { var invitations: [Invitation] }
    struct SettingsEnvelope: Decodable { var settings: MonitoringSettings }
    struct RequestEnvelope: Decodable { var request: SettingsChangeRequest }
    struct RequestsEnvelope: Decodable { var requests: [SettingsChangeRequest] }
    struct AuditEnvelope: Decodable { var entries: [AuditEntry] }

    @Test func dashboard() throws {
        let d = try fixture("dashboard", as: DashboardResponse.self)
        let a = try #require(d.alphas.first)
        #expect(a.status == .red)
        #expect(a.permissions.allows(.viewHeartRate))
        #expect(!a.permissions.allows(.manageSettings))
        #expect(a.snapshot.lastHeartRate?.bpm == 69)
        let alert = try #require(a.openAlerts.first)
        #expect(alert.type == .possibleFall)
        #expect(alert.simulated)
        #expect(alert.status == .open)
        #expect(alert.evidence?["detector"] == .string("experimental"))
    }

    @Test func selfSummaryUsesSelfPermissions() throws {
        let s = try fixture("summary", as: SummaryResponse.self)
        #expect(s.summary.permissions == .self)
    }

    @Test func histories() throws {
        let loc = try fixture("locations", as: LocationHistory.self)
        #expect(loc.samples.count == 4)
        let hr = try fixture("heart-rate", as: HeartRateHistory.self)
        #expect(hr.stats?.count == 4)
        #expect(hr.thresholds.upperBpm == 120)
        let act = try fixture("activity", as: ActivityHistory.self)
        #expect(act.steps.first?.count == 412)
        #expect(act.interactions.first?.source == .checkIn)
    }

    @Test func alertsAndDeliveries() throws {
        let list = try fixture("alerts", as: AlertList.self)
        #expect(!list.alerts.isEmpty)
        let detail = try fixture("alert-detail", as: AlertDetail.self)
        #expect(detail.deliveries.contains { $0.channel == .inApp })
    }

    @Test func accountPairingAndSettings() throws {
        _ = try fixture("profile", as: ProfileEnvelope.self)
        let created = try fixture("invitation-created", as: CreatedInvitation.self)
        #expect(created.code.count == 8)
        _ = try fixture("invitations", as: InvitationsEnvelope.self)
        let rels = try fixture("relationships", as: RelationshipsResponse.self)
        #expect(rels.asBeta.first?.status == .active)
        let settings = try fixture("settings", as: SettingsEnvelope.self).settings
        #expect(settings.emergency.automaticEmergencyServices == false)
        let req = try fixture("settings-request", as: RequestEnvelope.self).request
        #expect(req.changes.sleepSchedule?.override?.mode == .forceNight)
        #expect(req.changes.heartRate == nil)
        _ = try fixture("settings-requests", as: RequestsEnvelope.self)
        let audit = try fixture("audit", as: AuditEnvelope.self)
        #expect(audit.entries.contains { $0.action == "relationship.approved" })
        _ = try fixture("ingest-result", as: IngestResult.self)
    }

    @Test func telemetryRoundTrip() throws {
        let batch = TelemetryBatch(deviceId: "dev-1234", samples: [
            .heartRate(.init(timestamp: Date(timeIntervalSince1970: 1_700_000_000), bpm: 72, sourceDevice: "Watch")),
            .location(.init(timestamp: Date(timeIntervalSince1970: 1_700_000_100), latitude: 1, longitude: 2, horizontalAccuracy: 5, source: .visit)),
            .steps(.init(timestamp: Date(timeIntervalSince1970: 1_700_000_000), endTimestamp: Date(timeIntervalSince1970: 1_700_000_600), count: 10)),
        ], events: [DeviceEvent(type: .manualHelpRequest, detectedAt: Date(timeIntervalSince1970: 1_700_000_000))])
        let data = try WireJSON.encoder().encode(batch)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""kind":"heartRate""#))
        #expect(json.contains("2023-11-14T22:13:20.000Z"))
        let back = try WireJSON.decoder().decode(TelemetryBatch.self, from: data)
        #expect(back.samples == batch.samples)
    }

    @Test func settingsDiffOnlyIncludesChangedSections() {
        let a = MonitoringSettings.defaults(alphaId: "a", timeZone: "UTC")
        var b = a
        b.heartRate.upperBpm = 110
        let diff = SettingsChanges.diff(from: a, to: b)
        #expect(diff.heartRate?.upperBpm == 110)
        #expect(diff.sleepSchedule == nil)
        #expect(SettingsChanges.diff(from: a, to: a).isEmpty)
    }
}
