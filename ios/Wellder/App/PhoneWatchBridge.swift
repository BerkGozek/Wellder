import Foundation
import Networking
import SharedModels
import WatchConnectivity

/// iPhone side of WatchConnectivity.
///  Phone → Watch (application context, latest-wins): Alpha name, monitoring state, fall
///  countdown, simulation flag, and a short-lived ID token + API URL so the watch can upload a
///  help request directly when the phone is out of reach.
///  Watch → Phone (transferUserInfo, queued and guaranteed; sendMessage when reachable): events,
///  and live heart-rate readings the watch couldn't upload directly.
@MainActor
final class PhoneWatchBridge: NSObject, @preconcurrency WCSessionDelegate {
    var onEvent: ((DeviceEvent) -> Void)?
    var onCheckIn: ((Date) -> Void)?
    var onSamples: (([TelemetrySample]) -> Void)?
    /// The watch raised an alarm (heart-rate alert from its own upload) or answered one.
    var onAlarm: ((String, String, Date?) -> Void)?
    var onAlarmResponse: ((String, AlarmResponse) -> Void)?
    var tokenProvider: (@Sendable () async -> String?)?
    var apiBaseURL: URL?
    var deviceId: String?
    var alphaId: String?
    var alphaName = ""
    private(set) var watchReportsSystemFallDetection = false
    private var lastContext: [String: Any] = [:]

    func activate() {
        guard WCSession.isSupported(), WCSession.default.activationState != .activated else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func update(state: MonitoringState, settings: MonitoringSettings, simulation: Bool) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        Task {
            var context: [String: Any] = [
                "alphaName": alphaName,
                "state": state.rawValue,
                "countdown": settings.fallDetection.confirmationCountdownSeconds,
                "systemFallDetectionEnabled": settings.fallDetection.systemFallDetectionEnabled,
                "experimentalFallDetection": settings.fallDetection.experimentalEnabled,
                "simulation": simulation,
                "emergencyNumber": settings.emergency.emergencyNumber,
            ]
            if let token = await tokenProvider?(), let apiBaseURL, let deviceId {
                context["token"] = token
                // Cognito ID tokens last 1 h; assume less so the watch never uses an expired one.
                context["tokenExpiresAt"] = Date().addingTimeInterval(45 * 60).timeIntervalSince1970
                context["apiBaseURL"] = apiBaseURL.absoluteString
                context["deviceId"] = deviceId
                context["alphaId"] = alphaId
            }
            lastContext = context
            try? WCSession.default.updateApplicationContext(context)
        }
    }

    /// Rings the watch too, with the same countdown (only while the watch app is reachable, e.g.
    /// during Live heart rate).
    func sendAlarm(alertId: String, text: String, deadline: Date?) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        var alarm: [String: Any] = ["alertId": alertId, "text": text]
        if let deadline { alarm["deadline"] = deadline.timeIntervalSince1970 }
        WCSession.default.sendMessage(["alarm": alarm], replyHandler: nil)
    }

    func sendAlarmStop(alertId: String) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["alarmStop": alertId], replyHandler: nil)
    }

    private func handle(_ payload: [String: Any]) {
        if let caps = payload["capabilities"] as? [String: Any], let fall = caps["systemFallDetection"] as? Bool {
            watchReportsSystemFallDetection = fall
        }
        if let ts = payload["checkIn"] as? String, let date = WireJSON.parseISO8601(ts) { onCheckIn?(date) }
        if let alarm = payload["alarm"] as? [String: Any], let id = alarm["alertId"] as? String, let text = alarm["text"] as? String {
            onAlarm?(id, text, (alarm["deadline"] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
        if let r = payload["alarmResponse"] as? [String: String], let id = r["alertId"], let response = r["response"].flatMap(AlarmResponse.init) {
            onAlarmResponse?(id, response)
        }
        if let data = payload["samples"] as? Data, let samples = try? WireJSON.decoder().decode([TelemetrySample].self, from: data) {
            onSamples?(samples) // live heart rate the watch couldn't upload itself
        }
        if let data = payload["event"] as? Data, let event = try? WireJSON.decoder().decode(DeviceEvent.self, from: data) {
            onEvent?(event) // the outbox de-duplicates by eventId if the watch also uploaded it directly
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let payload = Payload(userInfo)
        Task { @MainActor in self.handle(payload.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let payload = Payload(message)
        Task { @MainActor in self.handle(payload.value) }
        replyHandler(["received": true])
    }
}

/// WatchConnectivity dictionaries are property-list values; wrap to cross actors.
struct Payload: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}
