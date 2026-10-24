import Foundation

public struct MonitorSnapshot: Codable, Sendable, Hashable {
    public struct LastHeartRate: Codable, Sendable, Hashable { public var bpm: Double; public var timestamp: Date; public var sourceDevice: String }
    public struct LastLocation: Codable, Sendable, Hashable {
        public var latitude: Double; public var longitude: Double; public var horizontalAccuracy: Double; public var timestamp: Date
    }
    public struct LastActivity: Codable, Sendable, Hashable { public var activityType: ActivityType; public var confidence: Confidence; public var timestamp: Date }
    public struct RecentSteps: Codable, Sendable, Hashable { public var count: Int; public var from: Date; public var to: Date }

    public var alphaId: String
    public var lastSyncAt: Date?
    public var lastHeartRate: LastHeartRate?
    public var lastLocation: LastLocation?
    public var lastActivity: LastActivity?
    public var lastMovementAt: Date?
    public var lastInteractionAt: Date?
    public var recentSteps: RecentSteps?
    public var monitoringState: MonitoringState?
    public var batteryLevel: Double?
    public var simulated: Bool?
}

public enum StatusLevel: String, Codable, Sendable {
    /// No currently detected concern — NOT a guarantee of safety.
    case green
    case yellow
    case red
    /// Data unavailable or stale. Missing data is never shown as green.
    case gray
}

/// Either the caller is the Alpha ("self") or a Beta with a specific permission set.
public enum SummaryPermissions: Codable, Sendable, Hashable {
    case `self`
    case granted(PermissionSet)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self), s == "self" { self = .self } else { self = .granted(try c.decode(PermissionSet.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .self: try c.encode("self")
        case .granted(let p): try c.encode(p)
        }
    }

    public func allows(_ p: Permission) -> Bool {
        switch self {
        case .self: true
        case .granted(let set): set[p]
        }
    }
}

public struct AlphaSummary: Codable, Sendable, Hashable, Identifiable {
    public var alphaId: String
    public var name: String
    public var permissions: SummaryPermissions
    public var status: StatusLevel
    public var statusReason: String
    public var isNight: Bool
    public var snapshot: MonitorSnapshot
    public var openAlerts: [Alert]
    public var staleAfterMinutes: Int
    public var id: String { alphaId }
}

public struct DashboardResponse: Codable, Sendable {
    public var alphas: [AlphaSummary]
    public var pending: [MonitoringRelationship]
}

public struct SummaryResponse: Codable, Sendable { public var summary: AlphaSummary }

public struct APIErrorBody: Codable, Sendable {
    public struct Inner: Codable, Sendable { public var code: String; public var message: String }
    public var error: Inner
}
