import Foundation
import SharedModels

/// Synthetic data for Simulation Mode and tests. Every sample is marked `simulated: true`, which
/// the backend propagates to alerts: simulated alerts are labelled "[SIMULATION]" and never use
/// SMS or voice.
public struct SimulationScenario: Sendable, Equatable, Codable {
    public enum HeartRatePattern: String, Sendable, Codable, CaseIterable { case normal, highEpisode, lowEpisode, none }
    public enum MovementPattern: String, Sendable, Codable, CaseIterable { case typicalDay, inactive, walkAround }

    public var heartRate: HeartRatePattern
    public var movement: MovementPattern
    public var home: SIMD2<Double> // latitude, longitude
    public var connectivityFailure: Bool

    public init(heartRate: HeartRatePattern = .normal, movement: MovementPattern = .typicalDay, home: SIMD2<Double> = SIMD2(40.7484, -73.9857),
                connectivityFailure: Bool = false) {
        self.heartRate = heartRate
        self.movement = movement
        self.home = home
        self.connectivityFailure = connectivityFailure
    }
}

public enum SyntheticTelemetry {
    // Generators cover the half-open window (from, to] so consecutive collection cycles never
    // produce the same sample twice.

    /// Deterministic pseudo-random value in [0, 1) from a timestamp and a salt.
    static func unit(_ t: Date, _ salt: UInt64) -> Double {
        var z = UInt64(bitPattern: Int64(t.timeIntervalSince1970.rounded())) &+ salt &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }

    /// Heart rate roughly every 5 minutes (similar cadence to Apple Watch background readings).
    public static func heartRate(_ s: SimulationScenario, from: Date, to: Date) -> [TelemetrySample] {
        guard s.heartRate != .none else { return [] }
        let step: TimeInterval = 300
        var t = Date(timeIntervalSince1970: (from.timeIntervalSince1970 / step).rounded(.down) * step + step)
        var out: [TelemetrySample] = []
        while t <= to {
            var bpm = 68 + 8 * sin(t.timeIntervalSince1970 / 3600) + 6 * unit(t, 1)
            let minutesToEnd = to.timeIntervalSince(t) / 60
            if minutesToEnd < 20 {
                if s.heartRate == .highEpisode { bpm = 132 + 6 * unit(t, 2) }
                if s.heartRate == .lowEpisode { bpm = 38 + 3 * unit(t, 3) }
            }
            out.append(.heartRate(.init(sampleId: "sim-hr-\(Int(t.timeIntervalSince1970))", timestamp: t, bpm: bpm.rounded(),
                                        sourceDevice: "Simulated Apple Watch", simulated: true)))
            t = t.addingTimeInterval(step)
        }
        return out
    }

    /// A wandering trail around home with a deliberate 25-minute gap in the middle of each hour.
    public static func locations(_ s: SimulationScenario, from: Date, to: Date) -> [TelemetrySample] {
        let step: TimeInterval = s.movement == .walkAround ? 60 : 180
        var t = Date(timeIntervalSince1970: (from.timeIntervalSince1970 / step).rounded(.down) * step + step)
        var out: [TelemetrySample] = []
        while t <= to {
            let minuteOfHour = Int(t.timeIntervalSince1970 / 60) % 60
            if !(25..<50).contains(minuteOfHour) {
                let phase = t.timeIntervalSince1970 / 1800
                let radius = s.movement == .inactive ? 0.00005 : 0.003
                let lat = s.home.x + radius * sin(phase) + 0.0002 * (unit(t, 4) - 0.5)
                let lon = s.home.y + radius * cos(phase * 0.7) + 0.0002 * (unit(t, 5) - 0.5)
                out.append(.location(.init(sampleId: "sim-loc-\(Int(t.timeIntervalSince1970))", timestamp: t, latitude: lat, longitude: lon,
                                           horizontalAccuracy: 10 + 40 * unit(t, 6), source: .standard, simulated: true)))
            }
            t = t.addingTimeInterval(step)
        }
        return out
    }

    public static func activity(_ s: SimulationScenario, from: Date, to: Date) -> [TelemetrySample] {
        let step: TimeInterval = 600
        var t = Date(timeIntervalSince1970: (from.timeIntervalSince1970 / step).rounded(.down) * step + step)
        var out: [TelemetrySample] = []
        while t <= to {
            let walking = s.movement != .inactive && unit(t, 7) > (s.movement == .walkAround ? 0.2 : 0.6)
            out.append(.activity(.init(sampleId: "sim-act-\(Int(t.timeIntervalSince1970))", timestamp: t,
                                       activityType: walking ? .walking : .stationary, confidence: .high, simulated: true)))
            if walking {
                out.append(.steps(.init(sampleId: "sim-steps-\(Int(t.timeIntervalSince1970))", timestamp: t, endTimestamp: t.addingTimeInterval(step),
                                        count: Int(200 + 600 * unit(t, 8)), simulated: true)))
            }
            t = t.addingTimeInterval(step)
        }
        return out.filter { sample in
            if case .steps(let st) = sample { return st.endTimestamp <= to }
            return true
        }
    }
}

/// Collectors that read from the synthetic generators.
public struct SimulatedCollector: TelemetryCollector {
    public enum Kind: String, Sendable { case heartRate, location, activity }
    public let kind: Kind
    public let scenario: @Sendable () -> SimulationScenario
    public var name: String { "sim.\(kind.rawValue)" }

    public init(_ kind: Kind, scenario: @escaping @Sendable () -> SimulationScenario) {
        self.kind = kind
        self.scenario = scenario
    }

    public func collect(since: Date, until: Date) async throws -> [TelemetrySample] {
        let s = scenario()
        switch kind {
        case .heartRate: return SyntheticTelemetry.heartRate(s, from: since, to: until)
        case .location: return SyntheticTelemetry.locations(s, from: since, to: until)
        case .activity: return SyntheticTelemetry.activity(s, from: since, to: until)
        }
    }
}

/// Wraps an uploader and fails while the scenario simulates a connectivity outage.
public struct FlakyUploader: TelemetryUploading {
    public struct SimulatedOutage: Error, CustomStringConvertible { public var description: String { "Simulated connectivity failure" } }
    public let base: TelemetryUploading
    public let failing: @Sendable () -> Bool
    public init(base: TelemetryUploading, failing: @escaping @Sendable () -> Bool) {
        self.base = base
        self.failing = failing
    }
    public func upload(_ batch: TelemetryOutbox.Batch) async throws -> Int {
        if failing() { throw UploadFailure.unreachable(SimulatedOutage().description) }
        return try await base.upload(batch)
    }
}
