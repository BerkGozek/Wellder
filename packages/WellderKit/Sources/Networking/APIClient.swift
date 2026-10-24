import Foundation
import SharedModels

public protocol AccessTokenProvider: Sendable {
    /// A currently valid ID token, refreshing it if needed. Throws `APIError.unauthorized` when signed out.
    func validIDToken() async throws -> String
}

public enum APIError: Error, Equatable, LocalizedError, Sendable {
    case unauthorized
    case forbidden(String)
    case notFound(String)
    case conflict(String)
    case badRequest(String)
    case rateLimited(String)
    case server(Int)
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Please sign in again."
        case .forbidden(let m), .notFound(let m), .conflict(let m), .badRequest(let m), .rateLimited(let m): m
        case .server(let code): "The server had a problem (\(code)). Please try again."
        case .transport: "Couldn't reach the server. Check your internet connection."
        case .decoding: "The app received an unexpected response. Please update the app."
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .transport, .server, .rateLimited: true
        default: false
        }
    }
}

/// Thin, typed HTTP client for the Alpha–Beta API. Stateless apart from its configuration.
public struct APIClient: Sendable {
    public let baseURL: URL
    let tokens: AccessTokenProvider
    let session: URLSession

    public init(baseURL: URL, tokens: AccessTokenProvider, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.session = session
    }

    public func send<T: Decodable & Sendable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: (any Encodable & Sendable)? = nil,
                                              as: T.Type = T.self) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw APIError.badRequest("Invalid URL") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.setValue("Bearer \(try await tokens.validIDToken())", forHTTPHeaderField: "authorization")
        if let body {
            req.httpBody = try WireJSON.encoder().encode(body)
            req.setValue("application/json", forHTTPHeaderField: "content-type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.transport((error as? URLError)?.code.rawValue.description ?? "network")
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.transport("no response") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? WireJSON.decoder().decode(APIErrorBody.self, from: data))?.error.message ?? "Request failed"
            switch http.statusCode {
            case 401: throw APIError.unauthorized
            case 403: throw APIError.forbidden(message)
            case 404: throw APIError.notFound(message)
            case 409: throw APIError.conflict(message)
            case 429: throw APIError.rateLimited(message)
            case 400..<500: throw APIError.badRequest(message)
            default: throw APIError.server(http.statusCode)
            }
        }
        do {
            return try WireJSON.decoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}

/// Empty JSON object body / response.
public struct Empty: Codable, Sendable { public init() {} }
