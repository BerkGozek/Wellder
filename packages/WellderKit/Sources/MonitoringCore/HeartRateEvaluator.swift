import Foundation
import SharedModels

/// Mirrors backend/src/domain/heartRate.ts. The backend is authoritative for alerts; the device
/// uses this only to show the Alpha a local hint. Keep the two in sync (both have tests).
public enum HeartRateEvaluator {
    public struct Finding: Sendable, Equatable {
        public enum Direction: Sendable { case high, low }
        public var direction: Direction
        public var firstAbnormalAt: Date
        public var lastAbnormalAt: Date
        public var readings: Int
        public var extremeBpm: Double
    }

    public static func evaluate(_ samples: [TelemetrySample.HeartRate], thresholds t: MonitoringSettings.HeartRate) -> Finding? {
        guard t.enabled else { return nil }
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        func classify(_ bpm: Double) -> Finding.Direction? {
            bpm > Double(t.upperBpm) ? .high : bpm < Double(t.lowerBpm) ? .low : nil
        }
        guard let newest = sorted.last, let dir = classify(newest.bpm) else { return nil }
        var first = newest
        var extreme = newest.bpm
        var count = 0
        for s in sorted.reversed() {
            guard classify(s.bpm) == dir else { break }
            first = s
            count += 1
            extreme = dir == .high ? max(extreme, s.bpm) : min(extreme, s.bpm)
        }
        let span = newest.timestamp.timeIntervalSince(first.timestamp)
        if t.persistenceSeconds > 0 && (count < 2 || span < TimeInterval(t.persistenceSeconds)) { return nil }
        return Finding(direction: dir, firstAbnormalAt: first.timestamp, lastAbnormalAt: newest.timestamp, readings: count, extremeBpm: extreme)
    }
}
