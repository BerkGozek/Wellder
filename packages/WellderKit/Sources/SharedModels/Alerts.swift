import Foundation

public enum AlertType: String, Codable, Sendable, CaseIterable {
    case possibleFall, heartRateHigh, heartRateLow, prolongedInactivity, manualHelpRequest
    case monitoringInterrupted, deviceDisconnected, lowBattery, locationUnavailable

    public var symbolName: String {
        switch self {
        case .possibleFall: "figure.fall"
        case .heartRateHigh, .heartRateLow: "heart.text.square"
        case .prolongedInactivity: "figure.stand"
        case .manualHelpRequest: "sos"
        case .monitoringInterrupted, .deviceDisconnected: "antenna.radiowaves.left.and.right.slash"
        case .lowBattery: "battery.25percent"
        case .locationUnavailable: "location.slash"
        }
    }
}

public enum AlertCategory: String, Codable, Sendable { case safety, technical }
public enum AlertSeverity: String, Codable, Sendable { case critical, warning, info }
public enum AlertStatus: String, Codable, Sendable { case awaitingAlphaResponse, open, acknowledged, resolved }
public enum AlertResolution: String, Codable, Sendable { case alphaOk, betaResolved, conditionCleared, falseAlarm }

public struct Alert: Codable, Sendable, Hashable, Identifiable {
    public var alertId: String
    public var alphaId: String
    public var type: AlertType
    public var category: AlertCategory
    public var severity: AlertSeverity
    public var status: AlertStatus
    public var title: String
    public var message: String
    public var simulated: Bool
    public var occurrences: Int
    public var detectedAt: Date
    public var receivedAt: Date
    public var firstNotificationSentAt: Date?
    public var firstDeliveryConfirmedAt: Date?
    public var acknowledgedAt: Date?
    public var acknowledgedBy: String?
    public var resolvedAt: Date?
    public var resolution: AlertResolution?
    public var escalationStep: Int
    public var nextEscalationAt: Date?
    public var evidence: [String: JSONScalar]?
    public var id: String { alertId }

    public var isUnresolved: Bool { status != .resolved }
    public var needsAttention: Bool { status == .open || status == .awaitingAlphaResponse }
}

public enum DeliveryChannel: String, Codable, Sendable { case inApp, push, sms, voice }
public enum DeliveryStatus: String, Codable, Sendable { case sent, delivered, failed, skipped }

public struct AlertDelivery: Codable, Sendable, Hashable, Identifiable {
    public var deliveryId: String
    public var alertId: String
    public var betaId: String
    public var channel: DeliveryChannel
    public var escalationStep: Int
    public var status: DeliveryStatus
    public var attemptedAt: Date
    public var deliveredAt: Date?
    public var detail: String?
    public var id: String { deliveryId }
}

public struct AlertDetail: Codable, Sendable {
    public var alert: Alert
    public var deliveries: [AlertDelivery]
}

public struct AlertList: Codable, Sendable {
    public var alerts: [Alert]
    public var cursor: String?
}
