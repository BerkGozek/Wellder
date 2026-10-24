import AuthenticationServices
import Foundation
import MonitoringCore
import Networking
import Observation
import SharedModels
import SwiftUI
import UIKit
import UserNotifications

/// Root application state. Owns configuration, the auth session, the API client and — when the
/// signed-in user is an Alpha — the AlphaMonitor that collects and uploads telemetry.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case signedOut
        case needsProfile
        case ready
    }

    let config: BackendConfiguration
    private let tokenStore: TokenStore
    let auth: AuthSession
    let api: APIClient

    var phase: Phase = .launching
    var profile: UserProfile?
    var activeRole: Role = .beta
    var lastError: String?
    var pendingInviteCode: String?
    var pushRegistrationFailed = false
    var dashboardRefreshToken = 0 // bumped to make the Beta dashboard refetch

    /// Simulation mode: synthetic sensors instead of HealthKit/Core Location/Core Motion.
    /// Data is flagged `simulated` end to end and never triggers SMS or calls.
    var simulationEnabled: Bool {
        didSet { UserDefaults.standard.set(simulationEnabled, forKey: Self.simulationKey) }
    }
    private(set) var alphaMonitor: AlphaMonitor?
    private(set) var pushToken: String?

    static let simulationKey = "simulation"
    let deviceId: String
    let watchBridge = PhoneWatchBridge()

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        var config = BackendConfiguration.fromInfoDictionary(info)
        // UI tests point the app at a backend they started (launch argument -apiBaseURL).
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), let url = URL(string: override) {
            config = .local(apiBaseURL: url)
        }
        self.config = config
        let store: TokenStore = ProcessInfo.processInfo.arguments.contains("-uiTesting") ? InMemoryTokenStore() : KeychainTokenStore()
        self.tokenStore = store
        let backend: AuthBackend = switch config {
        case .local(let url): LocalDevAuthBackend(baseURL: url)
        case .aws(_, let cognito): CognitoAuthBackend(config: cognito)
        }
        self.auth = AuthSession(store: store, backend: backend)
        self.api = APIClient(baseURL: config.apiBaseURL, tokens: auth)
        self.simulationEnabled = UserDefaults.standard.bool(forKey: Self.simulationKey)
        if let id = UserDefaults.standard.string(forKey: "deviceId") {
            deviceId = id
        } else {
            deviceId = UUID().uuidString
            UserDefaults.standard.set(deviceId, forKey: "deviceId")
        }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        guard phase == .launching else { return }
        guard await auth.isSignedIn else {
            phase = .signedOut
            return
        }
        await loadProfile()
    }

    func becameActive() async {
        guard phase == .ready else { return }
        await alphaMonitor?.appBecameActive()
        dashboardRefreshToken += 1
    }

    func enteredBackground() {
        alphaMonitor?.appEnteredBackground()
    }

    func backgroundRefresh() async {
        if alphaMonitor == nil, await auth.isSignedIn { await loadProfile() }
        await alphaMonitor?.runCycle(reason: "bgRefresh")
    }

    private func loadProfile() async {
        do {
            profile = try await api.me()
            if let profile {
                activeRole = profile.roles.contains(.alpha) && !profile.roles.contains(.beta) ? .alpha : (profile.roles.first ?? .beta)
                if let stored = UserDefaults.standard.string(forKey: "activeRole").flatMap(Role.init), profile.roles.contains(stored) { activeRole = stored }
                phase = .ready
                await startRoleServices()
            } else {
                phase = .needsProfile
            }
        } catch APIError.unauthorized {
            await signOut()
        } catch {
            // Offline at launch: keep the session. Alpha monitoring still queues data locally.
            lastError = error.localizedDescription
            phase = profile == nil ? .needsProfile : .ready
            if profile == nil, let cached = cachedProfile() {
                profile = cached
                phase = .ready
                await startRoleServices()
            }
        }
        if let profile { cacheProfile(profile) }
    }

    private func startRoleServices() async {
        guard let profile else { return }
        if profile.roles.contains(.alpha) {
            if alphaMonitor == nil {
                alphaMonitor = AlphaMonitor(api: api, alphaId: profile.userId, deviceId: deviceId, simulation: simulationEnabled,
                                            pushToken: pushToken, watchBridge: watchBridge)
            }
            watchBridge.alphaName = profile.name
            watchBridge.apiBaseURL = config.apiBaseURL
            watchBridge.deviceId = deviceId
            watchBridge.alphaId = profile.userId
            let auth = self.auth
            watchBridge.tokenProvider = { try? await auth.validIDToken() }
            await alphaMonitor?.start()
        }
        await registerForPush()
    }

    // MARK: - Auth

    func signInLocal(email: String, password: String, register: Bool) async {
        guard case .local(let url) = config else { return }
        let backend = LocalDevAuthBackend(baseURL: url)
        do {
            let tokens = register ? try await backend.register(email: email, password: password) : try await backend.signIn(email: email, password: password)
            await auth.signedIn(tokens)
            lastError = nil
            await loadProfile()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signInWithCognito(signUp: Bool, session: WebAuthenticationSession) async {
        guard case .aws(_, let cognito) = config else { return }
        let backend = CognitoAuthBackend(config: cognito)
        let pkce = PKCE()
        guard let url = backend.authorizationURL(pkce, signUp: signUp) else { return }
        do {
            let callback = try await session.authenticate(using: url, callback: .customScheme("wellder"), preferredBrowserSession: .ephemeral,
                                                          additionalHeaderFields: [:])
            await auth.signedIn(try await backend.handleCallback(callback, pkce: pkce))
            lastError = nil
            await loadProfile()
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { lastError = error.localizedDescription }
        }
    }

    func signOut() async {
        alphaMonitor?.stop()
        alphaMonitor = nil
        await auth.signOut()
        profile = nil
        UserDefaults.standard.removeObject(forKey: "cachedProfile")
        UserDefaults.standard.removeObject(forKey: "activeRole")
        phase = .signedOut
    }

    func deleteAccount() async {
        do {
            _ = try await api.deleteAccount()
            try? await alphaMonitor?.clearLocalData()
            await signOut()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Profile & roles

    func saveProfile(name: String, phone: String?, roles: [Role]) async -> Bool {
        do {
            let p = try await api.saveProfile(ProfileInput(name: name, phoneNumber: phone, roles: roles, timeZone: TimeZone.current.identifier))
            profile = p
            cacheProfile(p)
            activeRole = roles.contains(.alpha) && !roles.contains(.beta) ? .alpha : roles.contains(.beta) ? .beta : .alpha
            phase = .ready
            lastError = nil
            await startRoleServices()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func switchRole(to role: Role) {
        activeRole = role
        UserDefaults.standard.set(role.rawValue, forKey: "activeRole")
    }

    private func cacheProfile(_ p: UserProfile) {
        if let data = try? WireJSON.encoder().encode(p) { UserDefaults.standard.set(data, forKey: "cachedProfile") }
    }

    private func cachedProfile() -> UserProfile? {
        UserDefaults.standard.data(forKey: "cachedProfile").flatMap { try? WireJSON.decoder().decode(UserProfile.self, from: $0) }
    }

    // MARK: - Push

    private func registerForPush() async {
        let center = UNUserNotificationCenter.current()
        // Time-sensitive alerts need the paid-team entitlement; critical alerts need Apple's approval
        // (AB_CRITICAL_ALERTS_ENTITLED). Asking for .criticalAlert without it is simply not granted.
        var options: UNAuthorizationOptions = [.alert, .sound, .badge]
        if AlarmPlayer.criticalAlertsEntitled { options.insert(.criticalAlert) }
        let granted = (try? await center.requestAuthorization(options: options)) ?? false
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        // AlarmKit (iOS 26): asked now so it's ready before any alert arrives. Skipped in UI tests,
        // which exercise the in-app alarm (a system alarm would cover the app under test).
        if !ProcessInfo.processInfo.arguments.contains("-uiTesting") { await SystemAlarm.requestAuthorization() }
        await registerDevice()
    }

    func updatePushToken(_ token: String) async {
        pushToken = token
        alphaMonitor?.pushToken = token
        await registerDevice()
    }

    /// Betas need a device record for push; Alphas register through AlphaMonitor (with capabilities).
    private func registerDevice() async {
        guard let profile else { return }
        if profile.roles.contains(.alpha) {
            await alphaMonitor?.registerDevice()
            return
        }
        let registration = DeviceRegistration(deviceType: .iPhone, model: UIDevice.current.model, osVersion: UIDevice.current.systemVersion,
                                              appVersion: Bundle.main.appVersion, apnsToken: pushToken,
                                              apnsEnvironment: pushToken == nil ? nil : Bundle.main.apnsEnvironment,
                                              capabilities: DeviceCapabilities(pushNotifications: pushToken != nil), monitoringState: .disabled, batteryLevel: nil)
        try? await api.registerDevice(id: deviceId, registration)
    }

    func notificationArrived() { dashboardRefreshToken += 1 }

    func handleNotification(action: String, userInfo: [String: String]) {
        switch action {
        case NotificationCategories.acknowledge:
            guard let alphaId = userInfo["alphaId"], let alertId = userInfo["alertId"] else { return }
            Task { _ = try? await api.acknowledge(alphaId: alphaId, alertId: alertId); dashboardRefreshToken += 1 }
        case NotificationCategories.fallOk:
            alphaMonitor?.respondToFall(.userOk)
        case NotificationCategories.fallHelp:
            alphaMonitor?.respondToFall(.needHelp)
        default:
            dashboardRefreshToken += 1
        }
    }

    // MARK: - Deep links

    /// wellder://invite/<CODE> — e.g. from scanning the Alpha's QR code with the Camera app.
    func handle(url: URL) {
        guard url.scheme == "wellder", url.host() == "invite" else { return }
        pendingInviteCode = url.pathComponents.dropFirst().first
        if profile?.roles.contains(.beta) == true { activeRole = .beta }
    }
}

extension Bundle {
    var appVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var apnsEnvironment: String { (infoDictionary?["ABAPNsEnvironment"] as? String) == "production" ? "production" : "sandbox" }
}
