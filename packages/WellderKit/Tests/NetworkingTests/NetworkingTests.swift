import Foundation
import SharedModels
import Testing
@testable import Networking

/// Intercepts URLSession traffic. One handler per test session id (parallel-safe).
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handlers: [String: (URLRequest) -> (Int, Data)] = [:]
    static let lock = NSLock()

    static func session(_ handler: @escaping (URLRequest) -> (Int, Data)) -> URLSession {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        config.httpAdditionalHeaders = ["x-stub": id]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "x-stub") ?? ""
        let handler = Self.lock.withLock { Self.handlers[id] }
        var req = request
        if req.httpBody == nil, let stream = req.httpBodyStream {
            stream.open()
            var data = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable { let n = stream.read(buf, maxLength: 4096); if n <= 0 { break }; data.append(buf, count: n) }
            buf.deallocate()
            req.httpBody = data
        }
        let (status, body) = handler?(req) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct StaticToken: AccessTokenProvider {
    func validIDToken() async throws -> String { "tok" }
}

struct APIClientTests {
    @Test func sendsBearerTokenAndMapsErrors() async throws {
        let session = StubProtocol.session { req in
            #expect(req.value(forHTTPHeaderField: "authorization") == "Bearer tok")
            if req.url?.path == "/v1/alphas/x/summary" { return (403, Data(#"{"error":{"code":"forbidden","message":"Not permitted"}}"#.utf8)) }
            if req.url?.path == "/v1/me" { return (200, Data(#"{"profile":null}"#.utf8)) }
            return (500, Data())
        }
        let api = APIClient(baseURL: URL(string: "http://test")!, tokens: StaticToken(), session: session)
        #expect(try await api.me() == nil)
        await #expect(throws: APIError.forbidden("Not permitted")) { try await api.summary(alphaId: "x") }
        await #expect(throws: APIError.server(500)) { try await api.dashboard() }
    }

    @Test func historyQueriesUseISOTimestamps() async throws {
        let session = StubProtocol.session { req in
            let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(q.first { $0.name == "from" }?.value == "1970-01-01T00:00:00.000Z")
            return (200, Data(#"{"from":"1970-01-01T00:00:00.000Z","to":"1970-01-01T01:00:00.000Z","samples":[]}"#.utf8))
        }
        let api = APIClient(baseURL: URL(string: "http://test")!, tokens: StaticToken(), session: session)
        let h = try await api.locations(alphaId: "a", from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 3600))
        #expect(h.samples.isEmpty)
    }
}

struct AuthTests {
    @Test func pkceMatchesRFC7636Vector() {
        let p = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s")
        #expect(p.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE().verifier.count >= 43)
    }

    @Test func authorizationURLAndStateCheck() async throws {
        let backend = CognitoAuthBackend(config: CognitoConfiguration(domain: URL(string: "https://example.auth.us-east-1.amazoncognito.com")!, clientId: "abc"))
        let pkce = PKCE()
        let url = try #require(backend.authorizationURL(pkce))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(items.first { $0.name == "redirect_uri" }?.value == "wellder://auth/callback")
        await #expect(throws: APIError.self) { try await backend.handleCallback(URL(string: "wellder://auth/callback?code=x&state=wrong")!, pkce: pkce) }
    }

    struct CountingBackend: AuthBackend {
        let counter: Counter
        final class Counter: @unchecked Sendable { var n = 0 }
        func refresh(_ tokens: AuthTokens) async throws -> AuthTokens {
            counter.n += 1
            return AuthTokens(idToken: "fresh", refreshToken: tokens.refreshToken, expiresAt: Date().addingTimeInterval(3600), userId: tokens.userId)
        }
    }

    @Test func refreshesExpiredTokensAndSignsOutWithoutRefreshToken() async throws {
        let counter = CountingBackend.Counter()
        let store = InMemoryTokenStore(AuthTokens(idToken: "old", refreshToken: "r", expiresAt: Date().addingTimeInterval(-10), userId: "u"))
        let session = AuthSession(store: store, backend: CountingBackend(counter: counter))
        #expect(try await session.validIDToken() == "fresh")
        #expect(try await session.validIDToken() == "fresh")
        #expect(counter.n == 1)

        let devStore = InMemoryTokenStore(AuthTokens(idToken: "dev", refreshToken: nil, expiresAt: Date().addingTimeInterval(-10), userId: "u"))
        let devSession = AuthSession(store: devStore, backend: CountingBackend(counter: counter))
        await #expect(throws: APIError.unauthorized) { try await devSession.validIDToken() }
        #expect(devStore.load() == nil)
    }

    @Test func subjectFromJWT() {
        // header.payload({"sub":"user-1"}).sig
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyLTEifQ.sig"
        #expect(AuthTokens.subject(of: jwt) == "user-1")
    }

    @Test func backendConfigurationFromInfoPlist() {
        #expect(BackendConfiguration.fromInfoDictionary([:]).isLocal)
        let aws = BackendConfiguration.fromInfoDictionary(["ABBackendMode": "aws", "ABAPIBaseURL": "https://api.example.com",
                                                           "ABCognitoDomain": "https://x.auth.amazoncognito.com", "ABCognitoClientId": "cid"])
        #expect(!aws.isLocal)
        // AWS mode without a client ID falls back to local rather than half-configured AWS.
        #expect(BackendConfiguration.fromInfoDictionary(["ABBackendMode": "aws", "ABCognitoClientId": ""]).isLocal)
    }
}
