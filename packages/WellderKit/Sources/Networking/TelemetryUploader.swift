import Foundation
import MonitoringCore
import SharedModels

/// Sends outbox batches to POST /v1/telemetry. Idempotent on the server (sample/event IDs), so
/// a batch that was received but whose response was lost is safe to resend.
public struct TelemetryUploader: TelemetryUploading {
    public let api: APIClient
    public let deviceId: String
    /// Alerts the server raised or updated because of this upload (e.g. a heart-rate threshold),
    /// so the uploading device can sound its own alarm.
    public let onAlerts: (@Sendable ([IngestResult.AlertRef]) -> Void)?

    public init(api: APIClient, deviceId: String, onAlerts: (@Sendable ([IngestResult.AlertRef]) -> Void)? = nil) {
        self.api = api
        self.deviceId = deviceId
        self.onAlerts = onAlerts
    }

    public func upload(_ batch: TelemetryOutbox.Batch) async throws -> Int {
        do {
            let result = try await api.uploadTelemetry(TelemetryBatch(deviceId: deviceId, samples: batch.samples, events: batch.events))
            if !result.alerts.isEmpty { onAlerts?(result.alerts) }
            return result.settingsVersion
        } catch APIError.transport(let code) {
            throw UploadFailure.unreachable(code)
        } catch APIError.badRequest(let message) {
            throw UploadFailure.rejected(message)
        }
    }
}

/// Where the app talks to. Read from Info.plist keys set per build configuration
/// (see Config/*.xcconfig).
public enum BackendConfiguration: Sendable, Equatable {
    case local(apiBaseURL: URL)
    case aws(apiBaseURL: URL, cognito: CognitoConfiguration)

    public var apiBaseURL: URL {
        switch self {
        case .local(let u): u
        case .aws(let u, _): u
        }
    }

    public var isLocal: Bool { if case .local = self { true } else { false } }

    public static func fromInfoDictionary(_ info: [String: Any]) -> BackendConfiguration {
        let mode = info["ABBackendMode"] as? String ?? "local"
        let api = (info["ABAPIBaseURL"] as? String).flatMap(URL.init(string:)) ?? URL(string: "http://127.0.0.1:8787")!
        if mode == "aws", let domain = (info["ABCognitoDomain"] as? String).flatMap(URL.init(string:)), let clientId = info["ABCognitoClientId"] as? String,
           !clientId.isEmpty {
            return .aws(apiBaseURL: api, cognito: CognitoConfiguration(domain: domain, clientId: clientId))
        }
        return .local(apiBaseURL: api)
    }
}
