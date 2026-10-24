import CryptoKit
import Foundation
import Security
import SharedModels

public struct AuthTokens: Codable, Sendable, Equatable {
    public var idToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var userId: String

    public init(idToken: String, refreshToken: String?, expiresAt: Date, userId: String) {
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userId = userId
    }

    /// `sub` claim of the ID token (not verified here; the server verifies every request).
    public static func subject(of jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["sub"] as? String
    }
}

public protocol TokenStore: Sendable {
    func load() -> AuthTokens?
    func save(_ tokens: AuthTokens?)
}

/// Stores tokens in the Keychain, readable after first unlock so background wakes (HealthKit,
/// location, BGAppRefresh) can upload while the phone is locked. Never synced to iCloud.
public struct KeychainTokenStore: TokenStore {
    let service: String
    let account = "session"

    public init(service: String = "com.berkgozek.AlphaBeta.auth") { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> AuthTokens? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? WireJSON.decoder().decode(AuthTokens.self, from: data)
    }

    public func save(_ tokens: AuthTokens?) {
        SecItemDelete(query as CFDictionary)
        guard let tokens, let data = try? WireJSON.encoder().encode(tokens) else { return }
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: AuthTokens?
    public init(_ tokens: AuthTokens? = nil) { self.tokens = tokens }
    public func load() -> AuthTokens? { lock.withLock { tokens } }
    public func save(_ tokens: AuthTokens?) { lock.withLock { self.tokens = tokens } }
}

/// Whatever issues tokens: Cognito in AWS, the local dev server otherwise.
public protocol AuthBackend: Sendable {
    func refresh(_ tokens: AuthTokens) async throws -> AuthTokens
}

/// Current session; hands out valid tokens to the API client and refreshes when needed.
public actor AuthSession: AccessTokenProvider {
    private let store: TokenStore
    private let backend: AuthBackend
    private var refreshing: Task<AuthTokens, Error>?

    public init(store: TokenStore, backend: AuthBackend) {
        self.store = store
        self.backend = backend
    }

    public var currentUserId: String? { store.load()?.userId }
    public var isSignedIn: Bool { store.load() != nil }

    public func signedIn(_ tokens: AuthTokens) { store.save(tokens) }

    public func signOut() { store.save(nil) }

    public func validIDToken() async throws -> String {
        guard let tokens = store.load() else { throw APIError.unauthorized }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.idToken }
        guard tokens.refreshToken != nil else {
            store.save(nil)
            throw APIError.unauthorized
        }
        if let refreshing { return try await refreshing.value.idToken }
        let task = Task { try await backend.refresh(tokens) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            store.save(fresh)
            return fresh.idToken
        } catch let e as APIError where e == .unauthorized {
            store.save(nil)
            throw e
        }
    }
}

// MARK: - Local development auth (backend/src/auth/auth.ts DevAuth)

public struct LocalDevAuthBackend: AuthBackend {
    public let baseURL: URL
    let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private struct Credentials: Codable { var email: String; var password: String }
    private struct Issued: Codable { var userId: String; var idToken: String; var expiresAt: Date }

    public func register(email: String, password: String) async throws -> AuthTokens { try await post("dev/auth/register", email, password) }
    public func signIn(email: String, password: String) async throws -> AuthTokens { try await post("dev/auth/login", email, password) }

    /// Dev tokens last 7 days and have no refresh token; sign in again after expiry.
    public func refresh(_ tokens: AuthTokens) async throws -> AuthTokens { throw APIError.unauthorized }

    private func post(_ path: String, _ email: String, _ password: String) async throws -> AuthTokens {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONEncoder().encode(Credentials(email: email, password: password))
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: req) } catch { throw APIError.transport("network") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? WireJSON.decoder().decode(APIErrorBody.self, from: data))?.error.message ?? "Sign-in failed"
            throw status == 409 ? APIError.conflict(message) : APIError.badRequest(message)
        }
        let issued = try WireJSON.decoder().decode(Issued.self, from: data)
        return AuthTokens(idToken: issued.idToken, refreshToken: nil, expiresAt: issued.expiresAt, userId: issued.userId)
    }
}

// MARK: - Amazon Cognito (Managed Login / Hosted UI, OAuth 2.0 authorization code + PKCE)

public struct CognitoConfiguration: Sendable, Equatable {
    public var domain: URL // e.g. https://wellder-dev.auth.us-east-1.amazoncognito.com
    public var clientId: String
    public var redirectURI: String // wellder://auth/callback
    public init(domain: URL, clientId: String, redirectURI: String = "wellder://auth/callback") {
        self.domain = domain
        self.clientId = clientId
        self.redirectURI = redirectURI
    }
}

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String
    public let state: String

    public init() {
        self.init(verifier: Self.randomURLSafe(48), state: Self.randomURLSafe(16))
    }

    public init(verifier: String, state: String) {
        self.verifier = verifier
        self.state = state
        self.challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return data.base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

public struct CognitoAuthBackend: AuthBackend {
    public let config: CognitoConfiguration
    let session: URLSession

    public init(config: CognitoConfiguration, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// URL to open in ASWebAuthenticationSession. `signUp` opens the registration page.
    public func authorizationURL(_ pkce: PKCE, signUp: Bool = false) -> URL? {
        var c = URLComponents(url: config.domain.appendingPathComponent(signUp ? "signup" : "oauth2/authorize"), resolvingAgainstBaseURL: false)
        c?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: "openid email profile"),
            URLQueryItem(name: "state", value: pkce.state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
        ]
        return c?.url
    }

    /// Validates the callback (`state` must match) and exchanges the code for tokens.
    public func handleCallback(_ url: URL, pkce: PKCE) async throws -> AuthTokens {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == pkce.state else { throw APIError.badRequest("Sign-in was interrupted. Please try again.") }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw APIError.badRequest("Sign-in was cancelled.") }
        return try await token(form: [
            "grant_type": "authorization_code", "client_id": config.clientId, "code": code,
            "redirect_uri": config.redirectURI, "code_verifier": pkce.verifier,
        ], existingRefresh: nil)
    }

    public func refresh(_ tokens: AuthTokens) async throws -> AuthTokens {
        guard let refresh = tokens.refreshToken else { throw APIError.unauthorized }
        return try await token(form: ["grant_type": "refresh_token", "client_id": config.clientId, "refresh_token": refresh], existingRefresh: refresh)
    }

    private struct TokenResponse: Decodable { var id_token: String; var refresh_token: String?; var expires_in: Double }

    private func token(form: [String: String], existingRefresh: String?) async throws -> AuthTokens {
        var req = URLRequest(url: config.domain.appendingPathComponent("oauth2/token"))
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
        var c = URLComponents()
        c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        req.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: req) } catch { throw APIError.transport("network") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(status) else { throw APIError.server(status) }
        let t = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let sub = AuthTokens.subject(of: t.id_token) else { throw APIError.decoding("id token") }
        return AuthTokens(idToken: t.id_token, refreshToken: t.refresh_token ?? existingRefresh, expiresAt: Date().addingTimeInterval(t.expires_in), userId: sub)
    }
}
