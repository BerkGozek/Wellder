import AlarmKit
import Foundation
import SwiftUI

/// System alarms (AlarmKit, iOS 26+): the same full-screen, Lock Screen and Dynamic Island alarm
/// the Clock app uses. It sounds even with the Ring/Silent switch on silent and through Focus, and
/// keeps sounding until stopped, even if the app is suspended afterwards.
///
/// AlarmKit only schedules alarms; it can't be triggered from a server. So the app must be running
/// when an alert arrives (in the foreground, or kept awake by the Beta's "Overnight alarm") and then
/// schedules an alarm that fires a moment later. Without iOS 26 or the user's permission, callers
/// fall back to `AlarmPlayer`.
@MainActor
enum SystemAlarm {
    struct Metadata: AlarmMetadata {}

    /// Alarm IDs by alert, so acknowledging in the app stops the matching alarm.
    private static var scheduled: [String: UUID] = [:]
    /// Stopped while `schedule` was still in flight; the alarm is stopped as soon as it exists.
    private static var stoppedEarly: Set<String> = []

    static var isAuthorized: Bool {
        guard #available(iOS 26.0, *) else { return false }
        return AlarmManager.shared.authorizationState == .authorized
    }

    /// Asks once (the system remembers the answer). Call before an alert can arrive, not during one.
    static func requestAuthorization() async {
        guard #available(iOS 26.0, *), AlarmManager.shared.authorizationState == .notDetermined else { return }
        _ = try? await AlarmManager.shared.requestAuthorization()
    }

    /// Rings now. Returns false if AlarmKit isn't available or allowed, so the caller can fall back.
    @discardableResult
    static func ring(alertId: String, title: String) async -> Bool {
        guard #available(iOS 26.0, *), isAuthorized else { return false }
        if scheduled[alertId] != nil { return true }
        let alert: AlarmPresentation.Alert
        if #available(iOS 26.1, *) {
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title))
        } else {
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: title),
                                            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"))
        }
        let attributes = AlarmAttributes<Metadata>(presentation: AlarmPresentation(alert: alert), tintColor: .red)
        let id = UUID()
        do {
            _ = try await AlarmManager.shared.schedule(
                id: id,
                configuration: .alarm(schedule: .fixed(Date().addingTimeInterval(1)), attributes: attributes, sound: .named(AlarmPlayer.soundName)))
            scheduled[alertId] = id
            if stoppedEarly.remove(alertId) != nil { stop(alertId: alertId) }
            return true
        } catch {
            return false
        }
    }

    static func stop(alertId: String) {
        guard #available(iOS 26.0, *) else { return }
        guard let id = scheduled.removeValue(forKey: alertId) else {
            stoppedEarly.insert(alertId)
            return
        }
        try? AlarmManager.shared.stop(id: id)
    }
}
