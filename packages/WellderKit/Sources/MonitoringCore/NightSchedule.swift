import Foundation
import SharedModels

/// Night-monitoring schedule evaluation. Mirrors backend/src/domain/schedule.ts — keep the two
/// in sync. Comparisons use local wall-clock minutes in the schedule's time zone, so bedtime
/// stays put across daylight-saving changes, and windows may span midnight.
public struct NightSchedule: Sendable {
    public let schedule: SleepSchedule

    public init(_ schedule: SleepSchedule) { self.schedule = schedule }

    public static func minutes(_ hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    public static func inWindow(_ minute: Int, start: Int, end: Int) -> Bool {
        if start == end { return false }
        return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end)
    }

    var calendar: Calendar? {
        guard let tz = TimeZone(identifier: schedule.timeZone) else { return nil }
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    public func isNight(at date: Date) -> Bool {
        if let o = schedule.override, o.until > date { return o.mode == .forceNight }
        guard schedule.enabled, let start = Self.minutes(schedule.bedtime), let end = Self.minutes(schedule.wakeTime), let cal = calendar else { return false }
        let comps = cal.dateComponents([.hour, .minute], from: date)
        return Self.inWindow((comps.hour ?? 0) * 60 + (comps.minute ?? 0), start: start, end: end)
    }

    /// The next moment night mode switches on or off after `date` (used to schedule the
    /// on-device transition). Respects an active override. Returns nil when the schedule is off.
    public func nextTransition(after date: Date) -> Date? {
        if let o = schedule.override, o.until > date { return o.until }
        guard schedule.enabled, let start = Self.minutes(schedule.bedtime), let end = Self.minutes(schedule.wakeTime), start != end,
              let cal = calendar else { return nil }
        let target = isNight(at: date) ? end : start
        // .nextTime: if the wall-clock time doesn't exist (spring-forward gap), use the next valid instant.
        return cal.nextDate(after: date, matching: DateComponents(hour: target / 60, minute: target % 60), matchingPolicy: .nextTime)
    }
}
