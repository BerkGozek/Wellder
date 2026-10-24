import Foundation
import SharedModels
import Testing
@testable import MonitoringCore

struct NightScheduleTests {
    func schedule(_ tz: String = "America/New_York", enabled: Bool = true, override: SleepSchedule.Override? = nil) -> NightSchedule {
        NightSchedule(SleepSchedule(enabled: enabled, bedtime: "22:00", wakeTime: "07:00", timeZone: tz, keepFallDetectionAtNight: true, override: override))
    }
    func date(_ s: String) -> Date { WireJSON.parseISO8601(s)! }

    @Test func overnightWindow() {
        #expect(schedule().isNight(at: date("2026-07-01T03:30:00Z"))) // 23:30 EDT
        #expect(schedule().isNight(at: date("2026-07-01T10:59:00Z"))) // 06:59 EDT
        #expect(!schedule().isNight(at: date("2026-07-01T11:00:00Z"))) // 07:00 EDT
        #expect(!schedule().isNight(at: date("2026-07-01T16:00:00Z")))
    }

    @Test func dstTransitionsKeepWallClockTimes() {
        // Same cases as backend/tests/domain.test.ts
        #expect(schedule().isNight(at: date("2026-03-07T03:30:00Z")))
        #expect(schedule().isNight(at: date("2026-03-09T02:30:00Z")))
        #expect(!schedule().isNight(at: date("2026-03-09T01:30:00Z")))
        #expect(schedule().isNight(at: date("2026-11-01T11:30:00Z")))
        #expect(!schedule().isNight(at: date("2026-11-01T12:30:00Z")))
    }

    @Test func nextTransitionAcrossDST() throws {
        // Evening before US spring-forward (2026-03-08): bedtime 22:00 EST = 03:00Z on the 8th.
        let s = schedule()
        let t1 = try #require(s.nextTransition(after: date("2026-03-07T20:00:00Z")))
        #expect(t1 == date("2026-03-08T03:00:00Z"))
        // Wake 07:00 EDT on the 8th = 11:00Z (clock moved forward overnight).
        let t2 = try #require(s.nextTransition(after: t1.addingTimeInterval(60)))
        #expect(t2 == date("2026-03-08T11:00:00Z"))
    }

    @Test func overridesAndDisabled() {
        let until = date("2026-07-01T17:00:00Z")
        let forced = schedule(override: .init(mode: .forceNight, until: until))
        #expect(forced.isNight(at: date("2026-07-01T16:00:00Z")))
        #expect(forced.nextTransition(after: date("2026-07-01T16:00:00Z")) == until)
        #expect(!schedule(enabled: false).isNight(at: date("2026-07-01T03:30:00Z")))
        #expect(schedule(enabled: false).nextTransition(after: .now) == nil)
        #expect(!schedule("Invalid/Zone").isNight(at: date("2026-07-01T03:30:00Z")))
    }
}

struct FreshnessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func classification() {
        #expect(MetricFreshness.heartRate(nil, now: now) == .unavailable)
        #expect(MetricFreshness.heartRate(now.addingTimeInterval(-60), now: now) == .current)
        #expect(MetricFreshness.heartRate(now.addingTimeInterval(-3600), now: now) == .recent)
        #expect(MetricFreshness.heartRate(now.addingTimeInterval(-3 * 3600), now: now) == .stale)
        #expect(!Freshness.stale.isUsable)
    }

    @Test func relativeTime() {
        #expect(RelativeTime.short(now.addingTimeInterval(-30), now: now) == "just now")
        #expect(RelativeTime.short(now.addingTimeInterval(-720), now: now) == "12 min ago")
        #expect(RelativeTime.short(now.addingTimeInterval(-3 * 3600), now: now) == "3 h ago")
    }
}

struct MonitoringStateTests {
    let now = Date()

    @Test func precedence() {
        var i = MonitoringInputs(locationAuthorized: true, locationAlways: true, healthAuthorized: true, motionAuthorized: true, lastSuccessfulUpload: now)
        #expect(MonitoringStateModel.state(i, now: now) == .active)
        i.isNight = true
        #expect(MonitoringStateModel.state(i, now: now) == .night)
        i.lastSuccessfulUpload = now.addingTimeInterval(-3 * 3600)
        #expect(MonitoringStateModel.state(i, now: now) == .dataStale)
        i.networkReachable = false
        #expect(MonitoringStateModel.state(i, now: now) == .temporarilyDisconnected)
        i.monitoringEnabled = false
        #expect(MonitoringStateModel.state(i, now: now) == .disabled)
    }

    @Test func partialPermissionsAreReduced() {
        let i = MonitoringInputs(locationAuthorized: true, locationAlways: false, healthAuthorized: true, motionAuthorized: true, lastSuccessfulUpload: now)
        #expect(MonitoringStateModel.state(i, now: now) == .reduced)
        #expect(MonitoringStateModel.state(MonitoringInputs(), now: now) == .permissionsUnavailable)
    }
}

struct HeartRateEvaluatorTests {
    let t = MonitoringSettings.defaults(alphaId: "a").heartRate
    func hr(_ minutesAgo: Double, _ bpm: Double) -> TelemetrySample.HeartRate {
        .init(timestamp: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60), bpm: bpm, sourceDevice: "w")
    }

    @Test func matchesBackendBehaviour() {
        #expect(HeartRateEvaluator.evaluate([hr(10, 80), hr(0, 150)], thresholds: t) == nil)
        let f = HeartRateEvaluator.evaluate([hr(20, 80), hr(6, 130), hr(3, 140), hr(0, 135)], thresholds: t)
        #expect(f?.direction == .high)
        #expect(f?.readings == 3)
        #expect(f?.extremeBpm == 140)
        #expect(HeartRateEvaluator.evaluate([hr(10, 140), hr(5, 140), hr(0, 90)], thresholds: t) == nil)
        var zero = t
        zero.persistenceSeconds = 0
        #expect(HeartRateEvaluator.evaluate([hr(0, 38)], thresholds: zero)?.direction == .low)
    }
}

struct LocationTrailTests {
    func loc(_ minute: Double) -> TelemetrySample.Location {
        .init(timestamp: Date(timeIntervalSince1970: minute * 60), latitude: 1, longitude: 1, horizontalAccuracy: 10, source: .standard)
    }

    @Test func splitsOnGapsAndNeverBridgesThem() {
        let trail = LocationTrail(samples: [loc(0), loc(5), loc(10), loc(40), loc(45)])
        #expect(trail.segments.count == 2)
        #expect(trail.segments[0].points.count == 3)
        #expect(trail.gaps == [LocationTrail.Gap(from: Date(timeIntervalSince1970: 600), to: Date(timeIntervalSince1970: 2400))])
    }

    @Test func reportsEdgeGapsAndEmptyRanges() {
        let trail = LocationTrail(samples: [loc(30), loc(35)])
        let gaps = trail.gaps(within: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 60 * 60))
        #expect(gaps.count == 2)
        #expect(LocationTrail(samples: []).gaps(within: .distantPast, to: .now).count == 1)
    }
}
