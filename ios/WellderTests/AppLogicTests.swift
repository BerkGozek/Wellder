import SharedModels
import Testing
@testable import Wellder

/// App-target logic. Core monitoring logic is tested in packages/WellderKit (swift test).
struct AppLogicTests {
    @Test func invitationCodeChunking() {
        #expect("ABCDEFGH".chunked == "ABCD EFGH")
        #expect("ABC".chunked == "ABC")
    }

    @Test func settingsChangeSummary() {
        var changes = SettingsChanges()
        #expect(changes.sectionNames.isEmpty)
        changes.heartRate = MonitoringSettings.defaults(alphaId: "a").heartRate
        changes.emergency = MonitoringSettings.defaults(alphaId: "a").emergency
        #expect(changes.sectionNames == "heart-rate alerts, emergency contacts")
    }

    @Test func auditActionsHaveReadableDescriptions() {
        #expect("relationship.revoked".auditDescription == "A connection was ended")
        #expect("unknown.action".auditDescription == "unknown.action")
    }

    @Test func nextWakeIsInTheFuture() throws {
        let s = SleepSchedule(enabled: true, bedtime: "22:00", wakeTime: "07:00", timeZone: "UTC", keepFallDetectionAtNight: true)
        let wake = try #require(NightScheduleHelper.nextWake(s))
        #expect(wake > .now)
        #expect(wake.timeIntervalSinceNow <= 24 * 3600)
    }
}
