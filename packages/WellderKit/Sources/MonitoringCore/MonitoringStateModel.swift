import Foundation
import SharedModels

/// Inputs that determine what the Alpha's device can actually monitor right now.
public struct MonitoringInputs: Sendable, Equatable {
    public var monitoringEnabled: Bool
    public var locationAuthorized: Bool
    public var locationAlways: Bool
    public var healthAuthorized: Bool
    public var motionAuthorized: Bool
    public var isNight: Bool
    public var lowPowerMode: Bool
    public var lastSuccessfulUpload: Date?
    public var networkReachable: Bool

    public init(monitoringEnabled: Bool = true, locationAuthorized: Bool = false, locationAlways: Bool = false, healthAuthorized: Bool = false,
                motionAuthorized: Bool = false, isNight: Bool = false, lowPowerMode: Bool = false, lastSuccessfulUpload: Date? = nil,
                networkReachable: Bool = true) {
        self.monitoringEnabled = monitoringEnabled
        self.locationAuthorized = locationAuthorized
        self.locationAlways = locationAlways
        self.healthAuthorized = healthAuthorized
        self.motionAuthorized = motionAuthorized
        self.isNight = isNight
        self.lowPowerMode = lowPowerMode
        self.lastSuccessfulUpload = lastSuccessfulUpload
        self.networkReachable = networkReachable
    }
}

public enum MonitoringStateModel {
    /// Precedence: disabled > no permissions > disconnected > stale > night > reduced > active.
    public static func state(_ i: MonitoringInputs, now: Date, staleAfter: TimeInterval = 2 * 3600) -> MonitoringState {
        if !i.monitoringEnabled { return .disabled }
        if !i.locationAuthorized && !i.healthAuthorized && !i.motionAuthorized { return .permissionsUnavailable }
        if !i.networkReachable { return .temporarilyDisconnected }
        if let last = i.lastSuccessfulUpload, now.timeIntervalSince(last) > staleAfter { return .dataStale }
        if i.isNight { return .night }
        let partial = !i.locationAlways || !i.healthAuthorized || !i.motionAuthorized
        if i.lowPowerMode || partial { return .reduced }
        return .active
    }

    /// Plain-language explanation for the Alpha's status screen (no jargon).
    public static func explanation(_ s: MonitoringState) -> String {
        switch s {
        case .active: "Sharing is on. Your caregivers can see the information you chose to share."
        case .reduced: "Sharing is on, but some information is limited by your settings or permissions."
        case .night: "Night mode: location sharing is paused. Help requests still work."
        case .temporarilyDisconnected: "Can't reach the Wellder server right now. Information is saved and will be sent when the connection is back."
        case .permissionsUnavailable: "Wellder doesn't have permission to read your location, health or motion."
        case .dataStale: "Information hasn't been sent for a while. Open the app while connected to the internet."
        case .disabled: "Sharing is turned off."
        }
    }
}
