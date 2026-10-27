import Core
import Foundation
import os

/// Supplies access tokens and refreshes them. Implemented by Session.TokenStore.
public protocol AuthTokenProvider: Sendable {
    /// A token to send, refreshed ahead of expiry; nil when signed out.
    func validAccessToken() async -> String?
    /// The server answered token_expired for `token`. Returns a fresh one;
    /// concurrent callers share a single refresh. Throws .unauthorized when
    /// the session is over, or the transport error when offline.
    func refreshAfterRejection(of token: String) async throws(APIError) -> String
    /// The server rejected a token outright: end the session.
    func sessionRejected() async
}

/// Sends endpoints and decodes their responses.
///
/// Nothing here touches the main actor: `send` is nonisolated, so URLSession
/// I/O and JSON decoding run on the cooperative pool and only the decoded
/// value reaches the UI.
public final class APIClient: Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let tokens: (any AuthTokenProvider)?
    private static let log = Logger(subsystem: "vetka", category: "network")

    public init(baseURL: URL, session: URLSession, tokens: (any AuthTokenProvider)? = nil) {
        self.baseURL = baseURL
        self.session = session
        self.tokens = tokens
    }

    /// A URLSession tuned for the API: no URL cache (the app caches decoded
    /// models itself), short timeouts so a dead network fails fast.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }

    public func send<R>(_ endpoint: Endpoint<R>) async throws(APIError) -> R {
        var token: String?
        if endpoint.auth != .none, let tokens {
            token = await tokens.validAccessToken()
        }
        if endpoint.auth == .required && token == nil {
            throw .unauthorized
        }

        var (data, status) = try await perform(endpoint, token: token)

        // An expired token is routine: refresh once and repeat the request.
        if status == 401, let token, let tokens {
            if (try? JSON.decoder().decode(ErrorEnvelope.self, from: data))?.error.code == "token_expired" {
                let fresh = try await tokens.refreshAfterRejection(of: token)
                (data, status) = try await perform(endpoint, token: fresh)
            }
            if status == 401 {
                await tokens.sessionRejected()
                throw .unauthorized
            }
        }
        return try decode(R.self, data: data, status: status)
    }

    private func perform<R>(_ endpoint: Endpoint<R>, token: String?) async throws(APIError) -> (Data, Int) {
        let request = try makeRequest(endpoint, token: token)
        let start = ContinuousClock.now
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Self.log.debug("\(endpoint.method.rawValue) \(endpoint.path) → \(status) in \(ContinuousClock.now - start)")
            return (data, status)
        } catch let error as URLError where error.code == .cancelled {
            throw .cancelled
        } catch let error as URLError {
            Self.log.info("\(endpoint.method.rawValue) \(endpoint.path) failed: \(error.code.rawValue)")
            throw .transport(error.code)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .transport(.unknown)
        }
    }

    private func makeRequest<R>(_ endpoint: Endpoint<R>, token: String?) throws(APIError) -> URLRequest {
        var url = baseURL.appending(path: endpoint.path)
        if !endpoint.query.isEmpty {
            url.append(queryItems: endpoint.query)
        }
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body = endpoint.body {
            do {
                request.httpBody = try JSON.encoder().encode(body)
            } catch {
                throw .decoding("encode request: \(error)")
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func decode<R: Decodable>(_: R.Type, data: Data, status: Int) throws(APIError) -> R {
        guard (200..<300).contains(status) else {
            if let envelope = try? JSON.decoder().decode(ErrorEnvelope.self, from: data) {
                throw .server(status: status, code: envelope.error.code,
                              message: envelope.error.message, field: envelope.error.field)
            }
            throw .unexpectedStatus(status)
        }
        if R.self == NoContent.self, let empty = NoContent() as? R {
            return empty
        }
        do {
            return try JSON.decoder().decode(R.self, from: data)
        } catch {
            throw .decoding(String(describing: error))
        }
    }
}
