import Foundation
import SharedModels

/// Splits a location history into continuous segments. Two consecutive points further apart in
/// time than `maxGap` start a new segment, so the map never draws a line that implies confirmed
/// movement through an unrecorded period. Low-accuracy points are kept but flagged.
public struct LocationTrail: Sendable {
    public struct Segment: Sendable, Identifiable {
        public var id: Int
        public var points: [TelemetrySample.Location]
    }

    public struct Gap: Sendable, Identifiable, Equatable {
        public var id: Date { from }
        public var from: Date
        public var to: Date
        public var duration: TimeInterval { to.timeIntervalSince(from) }
    }

    public var segments: [Segment]
    public var gaps: [Gap]
    public var first: TelemetrySample.Location?
    public var last: TelemetrySample.Location?

    public static let defaultMaxGap: TimeInterval = 15 * 60
    public static let poorAccuracyMeters: Double = 200

    public init(samples: [TelemetrySample.Location], maxGap: TimeInterval = LocationTrail.defaultMaxGap) {
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        var segments: [Segment] = []
        var gaps: [Gap] = []
        var current: [TelemetrySample.Location] = []
        for p in sorted {
            if let prev = current.last, p.timestamp.timeIntervalSince(prev.timestamp) > maxGap {
                segments.append(Segment(id: segments.count, points: current))
                gaps.append(Gap(from: prev.timestamp, to: p.timestamp))
                current = []
            }
            current.append(p)
        }
        if !current.isEmpty { segments.append(Segment(id: segments.count, points: current)) }
        self.segments = segments
        self.gaps = gaps
        self.first = sorted.first
        self.last = sorted.last
    }

    /// Also reports missing data at the edges of the requested window.
    public func gaps(within from: Date, to: Date, maxGap: TimeInterval = LocationTrail.defaultMaxGap) -> [Gap] {
        guard let first, let last else { return [Gap(from: from, to: to)] }
        var all = gaps
        if first.timestamp.timeIntervalSince(from) > maxGap { all.insert(Gap(from: from, to: first.timestamp), at: 0) }
        if to.timeIntervalSince(last.timestamp) > maxGap { all.append(Gap(from: last.timestamp, to: to)) }
        return all
    }
}

/// Time-range presets for movement history.
public enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case m30 = "30m", h1 = "1h", h6 = "6h", h12 = "12h", h24 = "24h", custom = "Custom"
    public var id: String { rawValue }
    public var duration: TimeInterval? {
        switch self {
        case .m30: 30 * 60
        case .h1: 3600
        case .h6: 6 * 3600
        case .h12: 12 * 3600
        case .h24: 24 * 3600
        case .custom: nil
        }
    }
    public var label: String {
        switch self {
        case .m30: "30 min"
        case .h1: "1 h"
        case .h6: "6 h"
        case .h12: "12 h"
        case .h24: "24 h"
        case .custom: "Custom"
        }
    }
}
