import Foundation

public enum Role: String, Codable, Sendable, CaseIterable, Hashable {
    case alpha, beta
}

public struct UserProfile: Codable, Sendable, Hashable, Identifiable {
    public var userId: String
    public var name: String
    public var email: String
    public var phoneNumber: String?
    public var roles: [Role]
    public var createdAt: Date
    public var updatedAt: Date
    public var id: String { userId }

    public init(userId: String, name: String, email: String, phoneNumber: String? = nil, roles: [Role], createdAt: Date, updatedAt: Date) {
        self.userId = userId
        self.name = name
        self.email = email
        self.phoneNumber = phoneNumber
        self.roles = roles
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ProfileInput: Codable, Sendable {
    public var name: String
    public var phoneNumber: String?
    public var roles: [Role]
    public var timeZone: String
    public init(name: String, phoneNumber: String?, roles: [Role], timeZone: String) {
        self.name = name
        self.phoneNumber = phoneNumber
        self.roles = roles
        self.timeZone = timeZone
    }
}

// MARK: - Relationships

public enum Permission: String, Codable, Sendable, CaseIterable, Identifiable {
    case viewLocation, viewMovementHistory, viewHeartRate, viewActivity, receiveAlerts, manageSettings, manageEmergencyContacts
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .viewLocation: "See current location"
        case .viewMovementHistory: "See where you've been"
        case .viewHeartRate: "See heart rate"
        case .viewActivity: "See activity and steps"
        case .receiveAlerts: "Receive alerts"
        case .manageSettings: "Suggest monitoring settings"
        case .manageEmergencyContacts: "Suggest emergency contacts"
        }
    }
}

public struct PermissionSet: Codable, Sendable, Hashable {
    public var viewLocation: Bool
    public var viewMovementHistory: Bool
    public var viewHeartRate: Bool
    public var viewActivity: Bool
    public var receiveAlerts: Bool
    public var manageSettings: Bool
    public var manageEmergencyContacts: Bool

    public init(viewLocation: Bool = true, viewMovementHistory: Bool = true, viewHeartRate: Bool = true, viewActivity: Bool = true,
                receiveAlerts: Bool = true, manageSettings: Bool = false, manageEmergencyContacts: Bool = false) {
        self.viewLocation = viewLocation
        self.viewMovementHistory = viewMovementHistory
        self.viewHeartRate = viewHeartRate
        self.viewActivity = viewActivity
        self.receiveAlerts = receiveAlerts
        self.manageSettings = manageSettings
        self.manageEmergencyContacts = manageEmergencyContacts
    }

    public static let defaults = PermissionSet()

    public subscript(_ p: Permission) -> Bool {
        get {
            switch p {
            case .viewLocation: viewLocation
            case .viewMovementHistory: viewMovementHistory
            case .viewHeartRate: viewHeartRate
            case .viewActivity: viewActivity
            case .receiveAlerts: receiveAlerts
            case .manageSettings: manageSettings
            case .manageEmergencyContacts: manageEmergencyContacts
            }
        }
        set {
            switch p {
            case .viewLocation: viewLocation = newValue
            case .viewMovementHistory: viewMovementHistory = newValue
            case .viewHeartRate: viewHeartRate = newValue
            case .viewActivity: viewActivity = newValue
            case .receiveAlerts: receiveAlerts = newValue
            case .manageSettings: manageSettings = newValue
            case .manageEmergencyContacts: manageEmergencyContacts = newValue
            }
        }
    }
}

public enum RelationshipStatus: String, Codable, Sendable {
    case pendingAlphaApproval, active, rejected, revoked
}

public struct MonitoringRelationship: Codable, Sendable, Hashable, Identifiable {
    public var relationshipId: String
    public var alphaId: String
    public var betaId: String
    public var alphaName: String
    public var betaName: String
    public var betaEmail: String
    public var permissions: PermissionSet
    public var status: RelationshipStatus
    public var createdAt: Date
    public var approvedAt: Date?
    public var revokedAt: Date?
    public var id: String { relationshipId }
}

public struct RelationshipsResponse: Codable, Sendable {
    public var asAlpha: [MonitoringRelationship]
    public var asBeta: [MonitoringRelationship]
}

public struct Invitation: Codable, Sendable, Hashable, Identifiable {
    public var invitationId: String
    public var alphaId: String
    public var alphaName: String
    public var permissions: PermissionSet
    public var createdAt: Date
    public var expiresAt: Date
    public var codeHint: String
    public var id: String { invitationId }
}

public struct CreatedInvitation: Codable, Sendable {
    public var invitation: Invitation
    /// Shown once; the server stores only a hash.
    public var code: String
    public var link: String
}

// MARK: - Devices

public enum MonitoringState: String, Codable, Sendable, CaseIterable {
    case active, reduced, night, temporarilyDisconnected, permissionsUnavailable, dataStale, disabled
}

public struct DeviceCapabilities: Codable, Sendable, Hashable {
    public var healthKit: Bool
    public var heartRate: Bool
    public var backgroundLocation: Bool
    public var motionActivity: Bool
    public var pedometer: Bool
    public var systemFallDetection: Bool
    public var experimentalFallDetection: Bool
    public var pushNotifications: Bool

    public init(healthKit: Bool = false, heartRate: Bool = false, backgroundLocation: Bool = false, motionActivity: Bool = false,
                pedometer: Bool = false, systemFallDetection: Bool = false, experimentalFallDetection: Bool = false, pushNotifications: Bool = false) {
        self.healthKit = healthKit
        self.heartRate = heartRate
        self.backgroundLocation = backgroundLocation
        self.motionActivity = motionActivity
        self.pedometer = pedometer
        self.systemFallDetection = systemFallDetection
        self.experimentalFallDetection = experimentalFallDetection
        self.pushNotifications = pushNotifications
    }
}

public struct DeviceRegistration: Codable, Sendable {
    public enum DeviceType: String, Codable, Sendable { case iPhone, appleWatch }
    public var deviceType: DeviceType
    public var model: String?
    public var osVersion: String?
    public var appVersion: String
    public var apnsToken: String?
    public var apnsEnvironment: String?
    public var capabilities: DeviceCapabilities
    public var monitoringState: MonitoringState
    public var batteryLevel: Double?

    public init(deviceType: DeviceType, model: String?, osVersion: String?, appVersion: String, apnsToken: String?, apnsEnvironment: String?,
                capabilities: DeviceCapabilities, monitoringState: MonitoringState, batteryLevel: Double?) {
        self.deviceType = deviceType
        self.model = model
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.apnsToken = apnsToken
        self.apnsEnvironment = apnsEnvironment
        self.capabilities = capabilities
        self.monitoringState = monitoringState
        self.batteryLevel = batteryLevel
    }
}
