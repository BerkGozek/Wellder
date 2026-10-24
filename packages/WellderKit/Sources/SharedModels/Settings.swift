import Foundation

public struct SleepSchedule: Codable, Sendable, Hashable {
    public struct Override: Codable, Sendable, Hashable {
        public enum Mode: String, Codable, Sendable { case forceNight, forceDay }
        public var mode: Mode
        public var until: Date
        public init(mode: Mode, until: Date) { self.mode = mode; self.until = until }
    }
    public var enabled: Bool
    public var bedtime: String // "HH:mm"
    public var wakeTime: String
    public var timeZone: String // IANA
    public var keepFallDetectionAtNight: Bool
    public var override: Override?

    public init(enabled: Bool, bedtime: String, wakeTime: String, timeZone: String, keepFallDetectionAtNight: Bool, override: Override? = nil) {
        self.enabled = enabled
        self.bedtime = bedtime
        self.wakeTime = wakeTime
        self.timeZone = timeZone
        self.keepFallDetectionAtNight = keepFallDetectionAtNight
        self.override = override
    }
}

public struct EmergencyContact: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var phoneNumber: String
    public var relation: String?
    public var id: String { phoneNumber + name }
    public init(name: String, phoneNumber: String, relation: String? = nil) {
        self.name = name; self.phoneNumber = phoneNumber; self.relation = relation
    }
}

public struct MonitoringSettings: Codable, Sendable, Hashable {
    public struct HeartRate: Codable, Sendable, Hashable {
        public var enabled: Bool
        public var upperBpm: Int
        public var lowerBpm: Int
        public var persistenceSeconds: Int
        public var cooldownSeconds: Int
    }
    public struct Movement: Codable, Sendable, Hashable {
        public var enabled: Bool
        public var locationEnabled: Bool
        public var inactivityThresholdMinutes: Int
        public var locationHistoryRetentionDays: Int
    }
    public struct FallDetection: Codable, Sendable, Hashable {
        public var experimentalEnabled: Bool
        public var systemFallDetectionEnabled: Bool
        public var confirmationCountdownSeconds: Int
    }
    public struct Notifications: Codable, Sendable, Hashable {
        public var push: Bool
        public var sms: Bool
        public var voice: Bool
        public var escalationDelaySeconds: Int
        public var contactOrder: [String]
    }
    public struct Emergency: Codable, Sendable, Hashable {
        /// Always false in this version; the server rejects any other value.
        public var automaticEmergencyServices: Bool
        public var emergencyNumber: String
        public var contacts: [EmergencyContact]
    }
    public struct DataRetention: Codable, Sendable, Hashable {
        public var telemetryDays: Int
        public var alertDays: Int
    }

    public var alphaId: String
    public var version: Int
    public var sleepSchedule: SleepSchedule
    public var heartRate: HeartRate
    public var movement: Movement
    public var fallDetection: FallDetection
    public var notifications: Notifications
    public var emergency: Emergency
    public var dataRetention: DataRetention
    public var staleAfterMinutes: Int
    public var updatedAt: Date
    public var updatedBy: String

    /// Local fallback used before the first successful fetch (matches backend defaults).
    public static func defaults(alphaId: String, timeZone: String = TimeZone.current.identifier) -> MonitoringSettings {
        MonitoringSettings(
            alphaId: alphaId, version: 0,
            sleepSchedule: SleepSchedule(enabled: false, bedtime: "22:00", wakeTime: "07:00", timeZone: timeZone, keepFallDetectionAtNight: true),
            heartRate: HeartRate(enabled: true, upperBpm: 120, lowerBpm: 45, persistenceSeconds: 300, cooldownSeconds: 1800),
            movement: Movement(enabled: true, locationEnabled: true, inactivityThresholdMinutes: 240, locationHistoryRetentionDays: 30),
            fallDetection: FallDetection(experimentalEnabled: false, systemFallDetectionEnabled: true, confirmationCountdownSeconds: 60),
            notifications: Notifications(push: true, sms: false, voice: false, escalationDelaySeconds: 180, contactOrder: []),
            emergency: Emergency(automaticEmergencyServices: false, emergencyNumber: "911", contacts: []),
            dataRetention: DataRetention(telemetryDays: 30, alertDays: 365),
            staleAfterMinutes: 120, updatedAt: .distantPast, updatedBy: alphaId)
    }
}

/// A partial settings patch: each section present replaces that section whole.
public struct SettingsChanges: Codable, Sendable, Hashable {
    public var sleepSchedule: SleepSchedule?
    public var heartRate: MonitoringSettings.HeartRate?
    public var movement: MonitoringSettings.Movement?
    public var fallDetection: MonitoringSettings.FallDetection?
    public var notifications: MonitoringSettings.Notifications?
    public var emergency: MonitoringSettings.Emergency?
    public var dataRetention: MonitoringSettings.DataRetention?
    public var staleAfterMinutes: Int?

    public init(sleepSchedule: SleepSchedule? = nil, heartRate: MonitoringSettings.HeartRate? = nil, movement: MonitoringSettings.Movement? = nil,
                fallDetection: MonitoringSettings.FallDetection? = nil, notifications: MonitoringSettings.Notifications? = nil,
                emergency: MonitoringSettings.Emergency? = nil, dataRetention: MonitoringSettings.DataRetention? = nil, staleAfterMinutes: Int? = nil) {
        self.sleepSchedule = sleepSchedule
        self.heartRate = heartRate
        self.movement = movement
        self.fallDetection = fallDetection
        self.notifications = notifications
        self.emergency = emergency
        self.dataRetention = dataRetention
        self.staleAfterMinutes = staleAfterMinutes
    }

    /// Sections that differ between two settings values.
    public static func diff(from old: MonitoringSettings, to new: MonitoringSettings) -> SettingsChanges {
        SettingsChanges(
            sleepSchedule: old.sleepSchedule == new.sleepSchedule ? nil : new.sleepSchedule,
            heartRate: old.heartRate == new.heartRate ? nil : new.heartRate,
            movement: old.movement == new.movement ? nil : new.movement,
            fallDetection: old.fallDetection == new.fallDetection ? nil : new.fallDetection,
            notifications: old.notifications == new.notifications ? nil : new.notifications,
            emergency: old.emergency == new.emergency ? nil : new.emergency,
            dataRetention: old.dataRetention == new.dataRetention ? nil : new.dataRetention,
            staleAfterMinutes: old.staleAfterMinutes == new.staleAfterMinutes ? nil : new.staleAfterMinutes)
    }

    public var isEmpty: Bool { self == SettingsChanges() }
}

public struct SettingsChangeRequest: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, approved, rejected, superseded }
    public var requestId: String
    public var alphaId: String
    public var requestedBy: String
    public var requestedByName: String
    public var changes: SettingsChanges
    public var reason: String?
    public var status: Status
    public var createdAt: Date
    public var decidedAt: Date?
    public var id: String { requestId }
}

public struct AuditEntry: Codable, Sendable, Hashable, Identifiable {
    public var auditId: String
    public var actorId: String
    public var action: String
    public var at: Date
    public var detail: [String: JSONScalar]?
    public var id: String { auditId }
}
