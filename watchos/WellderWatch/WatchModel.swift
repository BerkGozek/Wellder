import CoreMotion
import Foundation
import MonitoringCore
import Networking
import Observation
import SharedModels
import WatchConnectivity
import WatchKit

/// Watch-side state. The watch is primarily an Alpha remote: status, help button, check-in and
/// fall prompts. Heart rate normally reaches the backend via HealthKit sync to the iPhone; during
/// "Live heart rate" (a workout session, see LiveHeartRate) the watch also uploads readings itself.
///
/// Event delivery: sendMessage when the phone is reachable → otherwise a direct HTTPS upload
/// (Wi-Fi/cellular watch, using the short-lived token the phone shared) → and always
/// transferUserInfo, which WatchConnectivity queues until the phone is reachable. The phone's
/// outbox and the server de-duplicate by eventId, so sending through several paths is safe.
@MainActor
@Observable
final class WatchModel: NSObject {
    var alphaName = ""
    var stateTitle = "Open Wellder on iPhone"
    var countdownSeconds = 30
    var emergencyNumber = "911"
    var simulation = false
    var lastSent: String?
    var fall = FallResponseCoordinator()
    var showFallPrompt = false
    var now = Date()
    let heart = LiveHeartRate()
    private let fallMonitor = WatchFallMonitor()
    /// Mirrors the Alpha's "experimental fall detection" setting (sent by the iPhone).
    private(set) var experimentalFallDetection = false
    private var isForeground = false
    var fallDetectionRunning: Bool { fallMonitor.isRunning }
    struct WatchAlarm: Equatable {
        var alertId: String
        var text: String
        /// When caregivers will be told unless cancelled; nil once they have been.
        var deadline: Date?
    }
    /// Full-screen alarm while ringing (heart-rate alert raised from this person's readings).
    var alarm: WatchAlarm?
    private var alarmLoop: Task<Void, Never>?

    private var token: String?
    private var tokenExpiresAt = Date.distantPast
    private var apiBaseURL: URL?
    private var deviceId: String?
    private var alphaIdFromContext: String?
    private var systemFallDetectionEnabled = true
    /// Created only when the build carries Apple's Fall Detection entitlement: without it,
    /// CMFallDetectionManager raises an Objective-C exception at launch (seen on a real watch),
    /// not an authorization failure. The flag is set in Config/*.xcconfig (AB_FALL_DETECTION_ENTITLED).
    private let fallManager: CMFallDetectionManager? = {
        guard Bundle.main.object(forInfoDictionaryKey: "ABFallDetectionEntitled") as? String == "YES",
              CMFallDetectionManager.isAvailable else { return nil }
        return CMFallDetectionManager()
    }()
    private var timer: Task<Void, Never>?
    private var pendingSamples: [TelemetrySample] = []
    private var flushLoop: Task<Void, Never>?
    /// Live readings are batched: one request every 15 s instead of one per reading saves battery,
    /// and the caregiver dashboard refreshes every 30 s anyway.
    private let flushInterval: Duration = .seconds(15)

    func start() {
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        startSystemFallDetection()
        heart.onReading = { [weak self] sample in self?.pendingSamples.append(sample) }
        fallMonitor.onCandidate = { [weak self] c in self?.beginFallPrompt(confidence: c.confidence, detector: "experimental-watch") }
        Task {
            if await heart.requestAuthorization() { heart.startObserving() }
        }
    }

    // MARK: - Experimental wrist fall detection

    func setForeground(_ active: Bool) {
        isForeground = active
        updateFallMonitor()
    }

    /// Runs while the setting is on and the app can actually receive motion: in the foreground,
    /// or in the background while Live heart rate's workout session keeps the app running.
    private func updateFallMonitor() {
        if experimentalFallDetection && (isForeground || heart.isLive) { fallMonitor.start() } else { fallMonitor.stop() }
    }

    // MARK: - Live heart rate

    func toggleLiveHeartRate() async {
        if heart.isLive {
            heart.stop()
            updateFallMonitor()
            flushLoop?.cancel()
            flushLoop = nil
            await flushSamples()
        } else {
            await heart.start()
            guard heart.isLive else { return }
            updateFallMonitor()
            flushLoop?.cancel()
            flushLoop = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: self?.flushInterval ?? .seconds(15))
                    await self?.flushSamples()
                }
            }
        }
    }

    /// Direct HTTPS upload when the watch has a valid token, otherwise hand the readings to the
    /// iPhone (queued by WatchConnectivity until it's reachable). Same sample IDs either way, so a
    /// reading that arrives by both routes is stored once.
    private func flushSamples() async {
        guard !pendingSamples.isEmpty else { return }
        let batch = pendingSamples
        pendingSamples.removeAll()
        if let token, tokenExpiresAt > Date(), let apiBaseURL, let deviceId {
            let api = APIClient(baseURL: apiBaseURL, tokens: StaticTokenProvider(token: token))
            if let result = try? await api.uploadTelemetry(TelemetryBatch(deviceId: deviceId, samples: batch, events: [])) {
                if let a = result.alerts.first(where: { $0.created && $0.type.hasPrefix("heartRate") }) {
                    let deadline = a.status == "awaitingAlphaResponse" ? Date().addingTimeInterval(TimeInterval(countdownSeconds)) : nil
                    let text = a.type == "heartRateHigh" ? "Your heart rate is high." : "Your heart rate is low."
                    ring(alertId: a.alertId, text: text, deadline: deadline)
                    // Ring the iPhone too, with the same countdown.
                    var msg: [String: Any] = ["alertId": a.alertId, "text": text]
                    if let deadline { msg["deadline"] = deadline.timeIntervalSince1970 }
                    if WCSession.default.activationState == .activated, WCSession.default.isReachable { WCSession.default.sendMessage(["alarm": msg], replyHandler: nil) }
                }
                return
            }
        }
        guard WCSession.default.activationState == .activated, let data = try? WireJSON.encoder().encode(batch) else {
            pendingSamples.insert(contentsOf: batch, at: 0)
            return
        }
        WCSession.default.transferUserInfo(["samples": data])
    }

    // MARK: - Apple Watch Fall Detection (requires Apple-granted entitlement)

    /// CMFallDetectionManager delivers falls detected by the system's own Fall Detection, along
    /// with how the wearer responded to watchOS's prompt. Without the entitlement it isn't created,
    /// and `systemFallDetection` is reported as unavailable — the rest of the app still works.
    private func startSystemFallDetection() {
        guard let fallManager else { return report(systemFallDetection: false) }
        fallManager.delegate = self
        if fallManager.authorizationStatus == .notDetermined {
            fallManager.requestAuthorization { status in
                Task { @MainActor in self.report(systemFallDetection: status == .authorized) }
            }
        } else {
            report(systemFallDetection: fallManager.authorizationStatus == .authorized)
        }
    }

    private func report(systemFallDetection: Bool) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(["capabilities": ["systemFallDetection": systemFallDetection]])
    }

    // MARK: - Alarm (false-alarm window)

    /// Strong haptics with sound (unless the watch is in Silent mode) every 1.5 s, for up to two
    /// minutes or until answered/stopped. The watch speaker can't play a long alarm, so haptics
    /// carry it. While `deadline` is set, the Alpha can cancel it as a false alarm.
    func ring(alertId: String, text: String, deadline: Date?) {
        guard alarm?.alertId != alertId else { return }
        alarm = WatchAlarm(alertId: alertId, text: text, deadline: deadline)
        now = Date()
        alarmLoop?.cancel()
        alarmLoop = Task { [weak self] in
            for _ in 0..<80 {
                guard !Task.isCancelled, let self else { return }
                WKInterfaceDevice.current().play(.notification)
                self.now = Date()
                if let d = self.alarm?.deadline, Date() >= d { await self.answerAlarm(.noResponse) }
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    /// "False alarm" (`.ok`), "Get help" (`.help`) or the countdown ran out (`.noResponse`). Sent
    /// to the server directly when possible and to the iPhone either way; the server ignores
    /// whichever arrives second.
    func answerAlarm(_ response: AlarmResponse) async {
        guard let current = alarm else { return }
        if response == .ok { stopAlarm() } else { alarm?.deadline = nil }
        let payload: [String: Any] = ["alarmResponse": ["alertId": current.alertId, "response": response.rawValue]]
        if WCSession.default.activationState == .activated {
            if WCSession.default.isReachable { WCSession.default.sendMessage(payload, replyHandler: nil) } else { WCSession.default.transferUserInfo(payload) }
        }
        if let token, tokenExpiresAt > Date(), let apiBaseURL {
            let api = APIClient(baseURL: apiBaseURL, tokens: StaticTokenProvider(token: token))
            _ = try? await api.respond(alphaId: alphaIdFromContext ?? "", alertId: current.alertId, response)
        }
    }

    func stopAlarm() {
        alarmLoop?.cancel()
        alarmLoop = nil
        alarm = nil
    }

    // MARK: - Actions

    func requestHelp() {
        send(DeviceEvent(type: .manualHelpRequest, detectedAt: Date(), details: ["source": .string("appleWatch")], simulated: simulation ? true : nil))
        WKInterfaceDevice.current().play(.notification)
    }

    /// "I'm okay" check-in; the phone records it as a watch interaction sample.
    func checkIn() {
        guard WCSession.default.activationState == .activated else { return }
        WCSession.default.transferUserInfo(["checkIn": WireJSON.formatISO8601(Date())])
        lastSent = "Check-in sent \(Date().formatted(date: .omitted, time: .shortened))"
    }

    func beginFallPrompt(confidence: Double, detector: String) {
        guard let e = fall.begin(confidence: confidence, detector: detector, countdownSeconds: countdownSeconds, now: Date()) else { return }
        send(e)
        showFallPrompt = true
        WKInterfaceDevice.current().play(.failure)
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.now = Date()
                if let e = self.fall.tick(now: Date()) { self.send(e); self.fall.reset(); return }
                // Strong taps every 2 s: with the wrist down the screen may be off.
                if Int(self.now.timeIntervalSince1970) % 2 == 0 { WKInterfaceDevice.current().play(.notification) }
            }
        }
    }

    func respond(_ outcome: FallResponseCoordinator.Outcome) {
        if let e = fall.respond(outcome, now: Date()) { send(e) }
        timer?.cancel()
        fall.reset()
        showFallPrompt = outcome == .needHelp
    }

    func callEmergency() {
        if let url = URL(string: "tel:\(emergencyNumber)") { WKApplication.shared().openSystemURL(url) }
    }

    // MARK: - Delivery

    private func send(_ event: DeviceEvent) {
        guard let data = try? WireJSON.encoder().encode(event) else { return }
        let payload: [String: Any] = ["event": data]
        let session = WCSession.default
        if session.activationState == .activated {
            session.transferUserInfo(payload) // queued, survives the phone being away
            if session.isReachable { session.sendMessage(payload, replyHandler: nil) }
        }
        lastSent = "Sent \(Date().formatted(date: .omitted, time: .shortened))"
        if !(session.activationState == .activated && session.isReachable) {
            Task { await uploadDirectly(event) }
        }
    }

    private func uploadDirectly(_ event: DeviceEvent) async {
        guard let token, tokenExpiresAt > Date(), let apiBaseURL, let deviceId else { return }
        let api = APIClient(baseURL: apiBaseURL, tokens: StaticTokenProvider(token: token))
        do {
            _ = try await api.uploadTelemetry(TelemetryBatch(deviceId: deviceId, samples: [], events: [event]))
            lastSent = "Sent directly \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            lastSent = "Queued — will send when iPhone is nearby"
        }
    }

    fileprivate func apply(context c: [String: Any]) {
        alphaName = c["alphaName"] as? String ?? alphaName
        if let s = (c["state"] as? String).flatMap(MonitoringState.init) { stateTitle = s.watchTitle }
        countdownSeconds = c["countdown"] as? Int ?? countdownSeconds
        emergencyNumber = c["emergencyNumber"] as? String ?? emergencyNumber
        let wasSimulation = simulation
        simulation = c["simulation"] as? Bool ?? simulation
        // Only rebuild when the mode changes: settings updates arrive often and must not cancel a
        // fall prompt that's counting down.
        if simulation != wasSimulation && !showFallPrompt { fall = FallResponseCoordinator(simulated: simulation) }
        systemFallDetectionEnabled = c["systemFallDetectionEnabled"] as? Bool ?? systemFallDetectionEnabled
        token = c["token"] as? String
        tokenExpiresAt = (c["tokenExpiresAt"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? .distantPast
        apiBaseURL = (c["apiBaseURL"] as? String).flatMap(URL.init(string:))
        deviceId = c["deviceId"] as? String
        alphaIdFromContext = c["alphaId"] as? String ?? alphaIdFromContext
        experimentalFallDetection = c["experimentalFallDetection"] as? Bool ?? experimentalFallDetection
        updateFallMonitor()
    }

    fileprivate func systemFall(resolution: String, at date: Date) {
        guard systemFallDetectionEnabled else { return }
        send(DeviceEvent(type: .systemFallDetected, detectedAt: date, details: ["resolution": .string(resolution)]))
    }
}

struct StaticTokenProvider: AccessTokenProvider {
    let token: String
    func validIDToken() async throws -> String { token }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let ctx = Payload(session.receivedApplicationContext)
        Task { @MainActor in self.apply(context: ctx.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let m = Payload(message)
        Task { @MainActor in
            if let a = m.value["alarm"] as? [String: Any], let id = a["alertId"] as? String, let text = a["text"] as? String {
                self.ring(alertId: id, text: text, deadline: (a["deadline"] as? Double).map(Date.init(timeIntervalSince1970:)))
            }
            if let id = m.value["alarmStop"] as? String, self.alarm?.alertId == id { self.stopAlarm() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let ctx = Payload(applicationContext)
        Task { @MainActor in self.apply(context: ctx.value) }
    }
}

extension WatchModel: CMFallDetectionDelegate {
    nonisolated func fallDetectionManager(_ fallDetectionManager: CMFallDetectionManager, didDetect event: CMFallDetectionEvent, completionHandler handler: @escaping () -> Void) {
        let resolution: String = switch event.resolution {
        case .confirmed: "confirmed"
        case .dismissed: "dismissed"
        case .rejected: "rejected"
        case .unresponsive: "unresponsive"
        @unknown default: "unknown"
        }
        let date = event.date
        // The system keeps the app awake until the handler runs, so call it only after the event
        // is handed to the model. The box carries the non-Sendable handler to the main actor.
        let done = FallHandlerBox(handler)
        Task { @MainActor in
            self.systemFall(resolution: resolution, at: date)
            done.call()
        }
    }

    nonisolated func fallDetectionManagerDidChangeAuthorization(_ fallDetectionManager: CMFallDetectionManager) {}
}

/// CoreMotion calls the completion handler from any thread; it's only invoked once, here.
private struct FallHandlerBox: @unchecked Sendable {
    let call: () -> Void
    init(_ call: @escaping () -> Void) { self.call = call }
}

struct Payload: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

extension MonitoringState {
    var watchTitle: String {
        switch self {
        case .active: "Sharing on"
        case .reduced: "Sharing limited"
        case .night: "Night mode"
        case .temporarilyDisconnected: "iPhone offline"
        case .permissionsUnavailable: "Check iPhone permissions"
        case .dataStale: "Not recently updated"
        case .disabled: "Sharing off"
        }
    }
}
