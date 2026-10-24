import Foundation

public enum ActivityType: String, Codable, Sendable, CaseIterable {
    case stationary, walking, running, cycling, automotive, unknown

    public var isMoving: Bool { self == .walking || self == .running || self == .cycling }
}

public enum Confidence: String, Codable, Sendable { case low, medium, high }

public enum LocationSource: String, Codable, Sendable { case standard, significantChange, visit }

public enum InteractionSource: String, Codable, Sendable { case app, checkIn, watchApp }

/// One measurement. `timestamp` is when it was measured — never when it was uploaded.
public enum TelemetrySample: Codable, Sendable, Hashable, Identifiable {
    case heartRate(HeartRate)
    case location(Location)
    case activity(Activity)
    case steps(Steps)
    case interaction(Interaction)

    public struct HeartRate: Codable, Sendable, Hashable {
        public var sampleId: String
        public var timestamp: Date
        public var bpm: Double
        public var sourceDevice: String
        public var simulated: Bool?
        public init(sampleId: String = UUID().uuidString, timestamp: Date, bpm: Double, sourceDevice: String, simulated: Bool? = nil) {
            self.sampleId = sampleId; self.timestamp = timestamp; self.bpm = bpm; self.sourceDevice = sourceDevice; self.simulated = simulated
        }
    }

    public struct Location: Codable, Sendable, Hashable {
        public var sampleId: String
        public var timestamp: Date
        public var latitude: Double
        public var longitude: Double
        public var horizontalAccuracy: Double
        public var source: LocationSource
        public var simulated: Bool?
        public init(sampleId: String = UUID().uuidString, timestamp: Date, latitude: Double, longitude: Double, horizontalAccuracy: Double,
                    source: LocationSource, simulated: Bool? = nil) {
            self.sampleId = sampleId; self.timestamp = timestamp; self.latitude = latitude; self.longitude = longitude
            self.horizontalAccuracy = horizontalAccuracy; self.source = source; self.simulated = simulated
        }
    }

    public struct Activity: Codable, Sendable, Hashable {
        public var sampleId: String
        public var timestamp: Date
        public var activityType: ActivityType
        public var confidence: Confidence
        public var simulated: Bool?
        public init(sampleId: String = UUID().uuidString, timestamp: Date, activityType: ActivityType, confidence: Confidence, simulated: Bool? = nil) {
            self.sampleId = sampleId; self.timestamp = timestamp; self.activityType = activityType; self.confidence = confidence; self.simulated = simulated
        }
    }

    public struct Steps: Codable, Sendable, Hashable {
        public var sampleId: String
        public var timestamp: Date
        public var endTimestamp: Date
        public var count: Int
        public var simulated: Bool?
        public init(sampleId: String = UUID().uuidString, timestamp: Date, endTimestamp: Date, count: Int, simulated: Bool? = nil) {
            self.sampleId = sampleId; self.timestamp = timestamp; self.endTimestamp = endTimestamp; self.count = count; self.simulated = simulated
        }
    }

    public struct Interaction: Codable, Sendable, Hashable {
        public var sampleId: String
        public var timestamp: Date
        public var source: InteractionSource
        public var simulated: Bool?
        public init(sampleId: String = UUID().uuidString, timestamp: Date, source: InteractionSource, simulated: Bool? = nil) {
            self.sampleId = sampleId; self.timestamp = timestamp; self.source = source; self.simulated = simulated
        }
    }

    private enum Kind: String, Codable { case heartRate, location, activity, steps, interaction }
    private enum CodingKeys: String, CodingKey { case kind }

    public init(from decoder: Decoder) throws {
        let kind = try decoder.container(keyedBy: CodingKeys.self).decode(Kind.self, forKey: .kind)
        switch kind {
        case .heartRate: self = .heartRate(try HeartRate(from: decoder))
        case .location: self = .location(try Location(from: decoder))
        case .activity: self = .activity(try Activity(from: decoder))
        case .steps: self = .steps(try Steps(from: decoder))
        case .interaction: self = .interaction(try Interaction(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .heartRate(let v): try c.encode(Kind.heartRate, forKey: .kind); try v.encode(to: encoder)
        case .location(let v): try c.encode(Kind.location, forKey: .kind); try v.encode(to: encoder)
        case .activity(let v): try c.encode(Kind.activity, forKey: .kind); try v.encode(to: encoder)
        case .steps(let v): try c.encode(Kind.steps, forKey: .kind); try v.encode(to: encoder)
        case .interaction(let v): try c.encode(Kind.interaction, forKey: .kind); try v.encode(to: encoder)
        }
    }

    public var id: String {
        switch self {
        case .heartRate(let v): v.sampleId
        case .location(let v): v.sampleId
        case .activity(let v): v.sampleId
        case .steps(let v): v.sampleId
        case .interaction(let v): v.sampleId
        }
    }

    public var timestamp: Date {
        switch self {
        case .heartRate(let v): v.timestamp
        case .location(let v): v.timestamp
        case .activity(let v): v.timestamp
        case .steps(let v): v.timestamp
        case .interaction(let v): v.timestamp
        }
    }
}

public enum DeviceEventType: String, Codable, Sendable {
    case fallCandidate, systemFallDetected, fallUserOk, fallNeedHelp, fallNoResponse, manualHelpRequest, lowBattery, locationUnavailable
}

public struct DeviceEvent: Codable, Sendable, Hashable, Identifiable {
    public var eventId: String
    public var type: DeviceEventType
    public var detectedAt: Date
    public var relatedEventId: String?
    public var confidence: Double?
    public var countdownSeconds: Int?
    public var details: [String: JSONScalar]?
    public var simulated: Bool?
    public var id: String { eventId }

    public init(eventId: String = UUID().uuidString, type: DeviceEventType, detectedAt: Date, relatedEventId: String? = nil, confidence: Double? = nil,
                countdownSeconds: Int? = nil, details: [String: JSONScalar]? = nil, simulated: Bool? = nil) {
        self.eventId = eventId
        self.type = type
        self.detectedAt = detectedAt
        self.relatedEventId = relatedEventId
        self.confidence = confidence
        self.countdownSeconds = countdownSeconds
        self.details = details
        self.simulated = simulated
    }
}

public struct TelemetryBatch: Codable, Sendable {
    public var deviceId: String
    public var samples: [TelemetrySample]
    public var events: [DeviceEvent]
    public init(deviceId: String, samples: [TelemetrySample], events: [DeviceEvent]) {
        self.deviceId = deviceId
        self.samples = samples
        self.events = events
    }
}

public struct IngestResult: Codable, Sendable {
    public struct AlertRef: Codable, Sendable { public var alertId: String; public var type: String; public var status: String; public var created: Bool }
    public var accepted: Int
    public var dropped: Int
    public var eventsProcessed: Int
    public var eventsDuplicate: Int
    public var alerts: [AlertRef]
    public var settingsVersion: Int
    public var serverTime: Date
}

// MARK: - History responses

public struct LocationHistory: Codable, Sendable {
    public var from: Date
    public var to: Date
    public var samples: [TelemetrySample.Location]
    public var cursor: String?
}

public struct HeartRateHistory: Codable, Sendable {
    public struct Stats: Codable, Sendable { public var min: Double; public var max: Double; public var count: Int }
    public struct Thresholds: Codable, Sendable { public var upperBpm: Double; public var lowerBpm: Double }
    public var from: Date
    public var to: Date
    public var samples: [TelemetrySample.HeartRate]
    public var stats: Stats?
    public var thresholds: Thresholds
    public var cursor: String?
}

public struct ActivityHistory: Codable, Sendable {
    public var from: Date
    public var to: Date
    public var activity: [TelemetrySample.Activity]
    public var steps: [TelemetrySample.Steps]
    public var interactions: [TelemetrySample.Interaction]
}
