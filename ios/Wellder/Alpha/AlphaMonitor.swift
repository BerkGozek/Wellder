import Foundation
import MonitoringCore
import Networking
import Observation
import SharedModels
import UIKit
import UserNotifications

/// Alpha-side monitoring: owns sensors, the offline outbox, night-mode transitions, help
/// requests and the possible-fall prompt. Every wake (foreground, BGAppRefresh, HealthKit
/// background delivery, location event) funnels into `runCycle`.
@MainActor
@Observable
final class AlphaMonitor {
    struct Permissions: Equatable {
        var location: String = "Not asked"
        var locationAlways = false
        var locationAuthorized = false
        var healthAsked = false
        var motion = false
        var notifications = false
    }

    let api: APIClient
    let alphaId: String
    let deviceId: String
    let simulation: Bool
    var pushToken: String?

    private(set) var settings: MonitoringSettings
    private(set) var state: MonitoringState = .active
    private(set) var permissions = Permissions()
    private(set) var lastUpload: Date?
    private(set) var lastCycle: MonitoringPipeline.CycleResult?
    private(set) var pendingItems = 0
    private(set) var isNight = false
    var scenario = SimulationScenario() { didSet { saveScenario() } }
    var lastError: String?

    // Fall prompt
    private(set) var fall = FallResponseCoordinator()
    var showFallPrompt = false
    /// Shown full-screen with a sounding alarm when the server raises a heart-rate alert.
    private(set) var falseAlarm: FalseAlarm?
    private(set) var falseAlarmNow = Date()
    private var falseAlarmTimer: Task<Void, Never>?
    private(set) var lastFallOutcome: FallResponseCoordinator.Outcome?
    var fallNow = Date()

    private let outbox: TelemetryOutbox
    private let cursors: CollectionCursorStore
    private let heartRate: HealthKitHeartRateCollector
    private let location = CoreLocationTracker()
    private let fallMonitor = DeviceMotionFallMonitor()
    private let watchBridge: PhoneWatchBridge
    private var nightTask: Task<Void, Never>?
    private var fallTimer: Task<Void, Never>?
    private var lastLocationFlush = Date.distantPast
    private var running = false
    private var cycleInFlight = false

    init(api: APIClient, alphaId: String, deviceId: String, simulation: Bool, pushToken: String?, watchBridge: PhoneWatchBridge) {
        self.api = api
        self.alphaId = alphaId
        self.deviceId = deviceId
        self.simulation = simulation
        self.pushToken = pushToken
        self.watchBridge = watchBridge
        self.settings = Self.cachedSettings(alphaId: alphaId) ?? .defaults(alphaId: alphaId)
        // Queue, cursors and HealthKit anchor are per account: queued data can never be uploaded
        // under a different account after switching users on this device.
        let fileName = "outbox-\(alphaId)\(simulation ? "-simulation" : "").json"
        let storage: OutboxStorage = (try? FileOutboxStorage.default(fileName: fileName)) ?? InMemoryOutboxStorage()
        self.cursors = UserDefaultsCursorStore(scope: "\(alphaId)\(simulation ? ".sim" : "")")
        self.heartRate = HealthKitHeartRateCollector(scope: alphaId)
        self.outbox = TelemetryOutbox(storage: storage)
        self.fall = FallResponseCoordinator(simulated: simulation)
        if let data = UserDefaults.standard.data(forKey: "simulationScenario"), let s = try? JSONDecoder().decode(SimulationScenario.self, from: data) {
            scenario = s
        }
    }

    private var pipeline: MonitoringPipeline {
        let collectors: [TelemetryCollector]
        if simulation {
            let snapshot = scenario
            collectors = [SimulatedCollector(.heartRate) { snapshot }, SimulatedCollector(.location) { snapshot }, SimulatedCollector(.activity) { snapshot }]
        } else {
            var c: [TelemetryCollector] = []
            if settings.heartRate.enabled { c.append(heartRate) }
            if settings.movement.enabled {
                c.append(MotionActivityCollector())
                c.append(PedometerCollector())
            }
            collectors = c
        }
        let uploader = TelemetryUploader(api: api, deviceId: deviceId) { [weak self] alerts in
            Task { @MainActor in self?.alarmForOwnAlerts(alerts) }
        }
        let outage = scenario.connectivityFailure && simulation
        return MonitoringPipeline(collectors: collectors, outbox: outbox, uploader: FlakyUploader(base: uploader) { outage }, cursors: cursors,
                                  initialLookback: simulation ? 6 * 3600 : 2 * 3600)
    }

    // MARK: - Own alarm (false-alarm window)

    struct FalseAlarm: Equatable {
        var alertId: String
        var text: String
        /// When caregivers will be told unless the Alpha cancels; nil once they have been.
        var deadline: Date?
    }

    /// Heart-rate alerts start with a false-alarm window: this phone (and the watch) ring the
    /// alarm and count down; "False alarm" cancels it before any caregiver is told. When the
    /// countdown runs out, the phone tells the server, which alerts caregivers. If the phone
    /// can't (asleep, dead battery), the server's own timer does it shortly after.
    func alarmForOwnAlerts(_ alerts: [IngestResult.AlertRef]) {
        guard let a = alerts.first(where: { $0.created && ($0.type == "heartRateHigh" || $0.type == "heartRateLow") }),
              falseAlarm?.alertId != a.alertId else { return }
        let text = a.type == "heartRateHigh" ? "Your heart rate is high." : "Your heart rate is low."
        let waiting = a.status == "awaitingAlphaResponse"
        startFalseAlarm(alertId: a.alertId, text: text,
                        deadline: waiting ? Date().addingTimeInterval(TimeInterval(settings.fallDetection.confirmationCountdownSeconds)) : nil)
    }

    func startFalseAlarm(alertId: String, text: String, deadline: Date?) {
        guard falseAlarm?.alertId != alertId else { return }
        falseAlarm = FalseAlarm(alertId: alertId, text: text, deadline: deadline)
        falseAlarmNow = Date()
        Task {
            if UIApplication.shared.applicationState == .active {
                AlarmPlayer.shared.start()
            } else if await !SystemAlarm.ring(alertId: alertId, title: text) {
                AlarmPlayer.shared.start()
                AlarmPlayer.notify(id: alertId, title: text, body: "Open Wellder to cancel if this is a false alarm.")
            }
        }
        watchBridge.sendAlarm(alertId: alertId, text: text, deadline: deadline)
        falseAlarmTimer?.cancel()
        guard deadline != nil else { return }
        falseAlarmTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let d = self.falseAlarm?.deadline else { return }
                self.falseAlarmNow = Date()
                if Date() >= d { await self.answerFalseAlarm(.noResponse); return }
            }
        }
    }

    /// "False alarm" (`.ok`), "Get help now" (`.help`) or the countdown ran out (`.noResponse`).
    func answerFalseAlarm(_ response: AlarmResponse, alertId: String? = nil) async {
        guard let current = falseAlarm, alertId == nil || alertId == current.alertId else { return }
        falseAlarmTimer?.cancel()
        if response != .noResponse { watchBridge.sendAlarmStop(alertId: current.alertId) }
        do {
            try await api.respond(alphaId: alphaId, alertId: current.alertId, response)
            lastError = nil
        } catch {
            lastError = error.localizedDescription // the server's timer still opens it if needed
        }
        if response == .ok {
            stopOwnAlarm()
        } else {
            falseAlarm?.deadline = nil // caregivers alerted; keep ringing until stopped
        }
    }

    func stopOwnAlarm() {
        if let id = falseAlarm?.alertId {
            SystemAlarm.stop(alertId: id)
            watchBridge.sendAlarmStop(alertId: id)
        }
        falseAlarmTimer?.cancel()
        falseAlarm = nil
        AlarmPlayer.shared.stop()
    }

    // MARK: - Lifecycle

    func start() async {
        guard !running else { return }
        running = true
        watchBridge.onEvent = { [weak self] event in self?.enqueueEvent(event) }
        watchBridge.onCheckIn = { [weak self] date in
            guard let self else { return }
            Task { try? await self.outbox.enqueue(samples: [.interaction(.init(timestamp: date, source: .watchApp, simulated: self.simulation ? true : nil))]); await self.runCycle(reason: "watchCheckIn") }
        }
        watchBridge.onAlarm = { [weak self] alertId, text, deadline in self?.startFalseAlarm(alertId: alertId, text: text, deadline: deadline) }
        watchBridge.onAlarmResponse = { [weak self] alertId, response in
            Task { await self?.answerFalseAlarm(response, alertId: alertId) }
        }
        watchBridge.onSamples = { [weak self] samples in
            guard let self, !self.simulation else { return }
            Task { try? await self.outbox.enqueue(samples: samples); await self.runCycle(reason: "watchLiveHeartRate") }
        }
        watchBridge.activate()
        location.onSample = { [weak self] sample in self?.locationSample(sample) }
        location.onAuthorizationChange = { [weak self] _ in self?.refreshPermissions() }
        fallMonitor.onCandidate = { [weak self] c in self?.beginFallPrompt(confidence: c.confidence, detector: "experimental-iphone") }
        if !simulation {
            heartRate.enableBackgroundDelivery { [weak self] in await self?.runCycle(reason: "healthKit") }
        }
        await refreshSettings()
        applyNightMode()
        refreshPermissions()
        await registerDevice()
        await runCycle(reason: "start")
        AppDelegate.scheduleRefresh()
    }

    func stop() {
        running = false
        location.apply(mode: .off)
        fallMonitor.stop()
        heartRate.stop()
        nightTask?.cancel()
        fallTimer?.cancel()
    }

    func appBecameActive() async {
        // Opening the app counts as interaction. It is labelled "last opened Wellder" —
        // NOT general phone use, which iOS does not let third-party apps observe.
        try? await outbox.enqueue(samples: [.interaction(.init(timestamp: Date(), source: .app, simulated: simulation ? true : nil))])
        updateForegroundFallDetection(active: true)
        refreshPermissions()
        await runCycle(reason: "foreground")
    }

    func appEnteredBackground() {
        updateForegroundFallDetection(active: false)
    }

    func clearLocalData() async throws {
        try await outbox.removeAll()
        heartRate.resetAnchor()
        UserDefaults.standard.removeObject(forKey: "settings.\(alphaId)")
    }

    // MARK: - Permissions

    func requestPermissions() async {
        guard !simulation else { return }
        location.requestAuthorization()
        _ = await heartRate.requestAuthorization()
        // Touching Core Motion triggers the Motion & Fitness prompt.
        _ = try? await MotionActivityCollector().collect(since: Date().addingTimeInterval(-60), until: Date())
        refreshPermissions()
        applyNightMode()
        await registerDevice()
    }

    func refreshPermissions() {
        if simulation {
            permissions = Permissions(location: "Simulated", locationAlways: true, locationAuthorized: true, healthAsked: true, motion: true, notifications: true)
        } else {
            permissions.locationAuthorized = location.isAuthorized
            permissions.locationAlways = location.isAlways
            permissions.location = location.isAlways ? "Always" : location.isAuthorized ? "While using the app" : location.authorization == .notDetermined ? "Not asked" : "Off"
            permissions.healthAsked = heartRate.hasBeenAsked
            permissions.motion = MotionActivityCollector.authorization == .authorized
            Task {
                let s = await UNUserNotificationCenter.current().notificationSettings()
                permissions.notifications = s.authorizationStatus == .authorized
            }
        }
        recomputeState()
    }

    var needsPermissions: Bool {
        !simulation && (!permissions.locationAuthorized || !permissions.healthAsked || !permissions.motion)
    }

    private func recomputeState() {
        let inputs = MonitoringInputs(
            monitoringEnabled: settings.movement.enabled || settings.heartRate.enabled,
            locationAuthorized: permissions.locationAuthorized || !settings.movement.locationEnabled,
            locationAlways: permissions.locationAlways || !settings.movement.locationEnabled,
            healthAuthorized: permissions.healthAsked,
            motionAuthorized: permissions.motion,
            isNight: isNight,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            lastSuccessfulUpload: lastUpload,
            networkReachable: !(lastCycle?.serverUnreachable ?? false))
        state = MonitoringStateModel.state(inputs, now: Date(), staleAfter: TimeInterval(settings.staleAfterMinutes * 60))
        watchBridge.update(state: state, settings: settings, simulation: simulation)
    }

    // MARK: - Collection & upload

    func runCycle(reason: String) async {
        guard !cycleInFlight else { return }
        cycleInFlight = true
        defer { cycleInFlight = false }
        let result = await pipeline.runCycle(now: Date())
        lastCycle = result
        if result.uploadError == nil, result.uploadedSamples + result.uploadedEvents > 0 || result.collected == 0 { lastUpload = Date() }
        if let v = result.settingsVersion, v != settings.version { await refreshSettings() }
        pendingItems = await outbox.pendingSamples + outbox.pendingEvents
        if result.uploadError == nil { lastError = nil }
        recomputeState()
        if pendingItems > 0 && result.uploadError == nil { await flush() }
    }

    private func flush() async {
        let result = await pipeline.flush()
        if result.uploadError == nil, result.uploadedSamples + result.uploadedEvents > 0 { lastUpload = Date() }
        lastCycle = result
        pendingItems = await outbox.pendingSamples + outbox.pendingEvents
        recomputeState()
    }

    private func locationSample(_ s: TelemetrySample.Location) {
        guard settings.movement.locationEnabled else { return }
        Task {
            try? await outbox.enqueue(samples: [.location(s)])
            // Location wakes are frequent; upload at most every 5 minutes from them.
            if Date().timeIntervalSince(lastLocationFlush) > 300 {
                lastLocationFlush = Date()
                await runCycle(reason: "location")
            }
        }
    }

    func registerDevice() async {
        let caps = DeviceCapabilities(
            healthKit: simulation || HealthKitHeartRateCollector.isAvailable,
            heartRate: simulation || permissions.healthAsked,
            backgroundLocation: simulation || permissions.locationAlways,
            motionActivity: simulation || (MotionActivityCollector.isAvailable && permissions.motion),
            pedometer: simulation || PedometerCollector.isAvailable,
            systemFallDetection: watchBridge.watchReportsSystemFallDetection,
            experimentalFallDetection: settings.fallDetection.experimentalEnabled,
            pushNotifications: pushToken != nil)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery = UIDevice.current.batteryLevel
        let registration = DeviceRegistration(deviceType: .iPhone, model: UIDevice.current.model, osVersion: UIDevice.current.systemVersion,
                                              appVersion: Bundle.main.appVersion, apnsToken: pushToken,
                                              apnsEnvironment: pushToken == nil ? nil : Bundle.main.apnsEnvironment,
                                              capabilities: caps, monitoringState: state, batteryLevel: battery >= 0 ? Double(battery) : nil)
        do {
            try await api.registerDevice(id: deviceId, registration)
        } catch {
            lastError = error.localizedDescription
        }
        if battery >= 0 && battery < 0.15 && UIDevice.current.batteryState == .unplugged {
            enqueueEvent(DeviceEvent(type: .lowBattery, detectedAt: Date(), details: ["deviceType": .string("iPhone")], simulated: simulation ? true : nil))
        }
        if !simulation && settings.movement.locationEnabled && !permissions.locationAuthorized && location.authorization != .notDetermined {
            enqueueEvent(DeviceEvent(type: .locationUnavailable, detectedAt: Date(), details: ["reason": .string("location permission off")]))
        }
    }

    // MARK: - Settings

    func refreshSettings() async {
        do {
            let s = try await api.settings(alphaId: alphaId)
            settings = s
            Self.cache(s)
            applyNightMode()
        } catch {
            // Keep the cached copy while offline.
        }
    }

    func update(_ newSettings: MonitoringSettings) async -> Bool {
        let changes = SettingsChanges.diff(from: settings, to: newSettings)
        guard !changes.isEmpty else { return true }
        do {
            settings = try await api.updateOwnSettings(version: settings.version, changes: changes)
            Self.cache(settings)
            applyNightMode()
            updateForegroundFallDetection(active: UIApplication.shared.applicationState == .active)
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            await refreshSettings()
            return false
        }
    }

    private static func cache(_ s: MonitoringSettings) {
        if let data = try? WireJSON.encoder().encode(s) { UserDefaults.standard.set(data, forKey: "settings.\(s.alphaId)") }
    }

    private static func cachedSettings(alphaId: String) -> MonitoringSettings? {
        UserDefaults.standard.data(forKey: "settings.\(alphaId)").flatMap { try? WireJSON.decoder().decode(MonitoringSettings.self, from: $0) }
    }

    private func saveScenario() {
        if let data = try? JSONEncoder().encode(scenario) { UserDefaults.standard.set(data, forKey: "simulationScenario") }
    }

    // MARK: - Night mode

    /// Night: location drops to significant-change only (or off), routine uploads continue on
    /// system wakes. Help requests and fall prompts are never suppressed.
    func applyNightMode() {
        let schedule = NightSchedule(settings.sleepSchedule)
        isNight = schedule.isNight(at: Date())
        let mode: LocationMode = simulation || !settings.movement.locationEnabled ? .off : (isNight || ProcessInfo.processInfo.isLowPowerModeEnabled) ? .lowPower : .balanced
        location.apply(mode: mode)
        nightTask?.cancel()
        if let next = schedule.nextTransition(after: Date()) {
            nightTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.applyNightMode()
            }
        }
        updateForegroundFallDetection(active: UIApplication.shared.applicationState == .active)
        recomputeState()
    }

    private func updateForegroundFallDetection(active: Bool) {
        let allowedNow = !isNight || settings.sleepSchedule.keepFallDetectionAtNight
        if active && settings.fallDetection.experimentalEnabled && allowedNow && !simulation {
            fallMonitor.start()
        } else {
            fallMonitor.stop()
        }
    }

    var experimentalFallDetectionRunning: Bool { fallMonitor.isRunning }

    // MARK: - Help & check-in

    func requestHelp() async {
        enqueueEvent(DeviceEvent(type: .manualHelpRequest, detectedAt: Date(), simulated: simulation ? true : nil))
        await runCycle(reason: "help")
    }

    func checkIn() async {
        try? await outbox.enqueue(samples: [.interaction(.init(timestamp: Date(), source: .checkIn, simulated: simulation ? true : nil))])
        await runCycle(reason: "checkIn")
    }

    func enqueueEvent(_ e: DeviceEvent) {
        Task {
            try? await outbox.enqueue(events: [e])
            pendingItems = await outbox.pendingSamples + outbox.pendingEvents
            await flush()
        }
    }

    // MARK: - Possible fall

    func beginFallPrompt(confidence: Double, detector: String) {
        guard let event = fall.begin(confidence: confidence, detector: detector, countdownSeconds: settings.fallDetection.confirmationCountdownSeconds, now: Date())
        else { return }
        enqueueEvent(event) // the backend starts its own timer from this event
        showFallPrompt = true
        AlarmPlayer.shared.start() // loud alarm through the whole countdown (plays on silent)
        lastFallOutcome = nil
        scheduleFallNotification()
        fallTimer?.cancel()
        fallTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.fallNow = Date()
                if let e = self.fall.tick(now: Date()) {
                    self.finishFall(e, outcome: .noResponse)
                    return
                }
            }
        }
    }

    func respondToFall(_ outcome: FallResponseCoordinator.Outcome) {
        guard let e = fall.respond(outcome, now: Date()) else { return }
        finishFall(e, outcome: outcome)
    }

    private func finishFall(_ event: DeviceEvent, outcome: FallResponseCoordinator.Outcome) {
        fallTimer?.cancel()
        if outcome == .userOk { AlarmPlayer.shared.stop() }
        enqueueEvent(event)
        lastFallOutcome = outcome
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["fall-prompt"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["fall-prompt"])
        fall.reset()
        if outcome == .userOk { showFallPrompt = false }
    }

    func dismissFallPrompt() {
        AlarmPlayer.shared.stop()
        showFallPrompt = false
        lastFallOutcome = nil
    }

    /// Also prompt via a local notification in case the app is not on screen.
    private func scheduleFallNotification() {
        let content = UNMutableNotificationContent()
        content.title = simulation ? "[SIMULATION] Possible fall detected" : "Possible fall detected"
        content.body = "Are you okay? If you don't answer, your caregivers will be notified."
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = NotificationCategories.fallPrompt
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "fall-prompt", content: content, trigger: nil))
    }

    /// Simulation: run a synthetic accelerometer trace through the real detector.
    func simulateFall(_ s: SyntheticMotion.Scenario) -> FallCandidate? {
        let detector = FallDetector()
        let candidate = SyntheticMotion.trace(s).lazy.compactMap { detector.process($0) }.first
        if let candidate { beginFallPrompt(confidence: candidate.confidence, detector: "simulated-\(s.rawValue)") }
        return candidate
    }

    var pendingSettingsRequests: [SettingsChangeRequest] = []

    func loadSettingsRequests() async {
        pendingSettingsRequests = ((try? await api.settingsRequests(alphaId: alphaId)) ?? []).filter { $0.status == .pending }
    }

    func decide(_ request: SettingsChangeRequest, approve: Bool) async {
        do {
            let r = try await api.decideSettingsRequest(request.requestId, approve: approve)
            settings = r.settings
            Self.cache(settings)
            applyNightMode()
            await loadSettingsRequests()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
