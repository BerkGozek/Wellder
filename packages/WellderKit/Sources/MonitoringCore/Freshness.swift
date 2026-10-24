import Foundation

/// How current a measurement is. A stale or unavailable value is never presented as current.
public enum Freshness: Sendable, Equatable {
    case current      // within the metric's "live" window
    case recent       // older, but still within the stale threshold
    case stale        // older than the stale threshold
    case unavailable  // never received

    public static func of(_ timestamp: Date?, now: Date, currentWithin: TimeInterval, staleAfter: TimeInterval) -> Freshness {
        guard let timestamp else { return .unavailable }
        let age = now.timeIntervalSince(timestamp)
        if age <= currentWithin { return .current }
        if age <= staleAfter { return .recent }
        return .stale
    }

    public var isUsable: Bool { self == .current || self == .recent }
}

/// Per-metric freshness windows. Apple Watch heart-rate readings are periodic (often several
/// minutes apart, longer when moving or not worn), so "current" is deliberately generous and
/// labelled with the measurement time rather than implying live monitoring.
public enum MetricFreshness {
    public static func heartRate(_ t: Date?, now: Date) -> Freshness { .of(t, now: now, currentWithin: 15 * 60, staleAfter: 2 * 3600) }
    public static func location(_ t: Date?, now: Date) -> Freshness { .of(t, now: now, currentWithin: 15 * 60, staleAfter: 3 * 3600) }
    public static func activity(_ t: Date?, now: Date) -> Freshness { .of(t, now: now, currentWithin: 30 * 60, staleAfter: 4 * 3600) }
    public static func sync(_ t: Date?, now: Date, staleAfterMinutes: Int) -> Freshness {
        .of(t, now: now, currentWithin: 10 * 60, staleAfter: TimeInterval(staleAfterMinutes * 60))
    }
}

public enum RelativeTime {
    /// "just now", "12 min ago", "3 h ago", "2 d ago".
    public static func short(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        switch s {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<86400: return "\(Int(s / 3600)) h ago"
        default: return "\(Int(s / 86400)) d ago"
        }
    }
}
