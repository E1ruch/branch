import Core
import Foundation
import Testing
@testable import Networking

/// Serves canned responses to an APIClient. Each test gets its own handler
/// keyed by a per-session header, so suites can run in parallel.
///
/// Handlers run on URLSession's thread, outside the test's task: they must
/// not call #expect (Swift Testing cannot attribute the issue and aborts).
/// They only record; tests assert afterwards.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, String)
    nonisolated(unsafe) static var handlers: [String: Handler] = [:]
    static let lock = NSLock()

    static func session(_ handler: @escaping Handler) -> URLSession {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Stub": id]
        return URLSession(configuration: config)
    }

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Stub") ?? ""
        guard let handler = Self.lock.withLock({ Self.handlers[id] }) else { return }
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            request.httpBody = Self.read(stream) // URLSession hands bodies over as streams
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Collects the requests a stub saw, for assertions in the test body.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.withLock { all.append(request) }
    }

    var requests: [URLRequest] {
        lock.withLock { all }
    }
}

/// A token provider that counts refreshes and hands out "fresh".
actor FakeTokens: AuthTokenProvider {
    var token: String?
    var refreshes = 0
    var rejected = false

    init(_ token: String?) { self.token = token }

    func validAccessToken() async -> String? { token }

    func refreshAfterRejection(of token: String) async throws(APIError) -> String {
        refreshes += 1
        self.token = "fresh"
        return "fresh"
    }

    func sessionRejected() async { rejected = true }
}

let base = URL(string: "https://api.test")!

@Suite struct APIClientTests {
    @Test func buildsRequestAndDecodes() async throws {
        let seen = Recorder()
        let session = StubURLProtocol.session { req in
            seen.record(req)
            return (200, #"{"items": [], "next_cursor": "next"}"#)
        }
        let client = APIClient(baseURL: base, session: session, tokens: FakeTokens("t1"))
        let page = try await client.send(API.feedAll(sort: .new, cursor: "abc"))
        #expect(page.items.isEmpty && page.nextCursor == "next")

        let req = try #require(seen.requests.first)
        #expect(req.httpMethod == "GET")
        #expect(req.url?.absoluteString == "https://api.test/v1/feed/all?sort=new&cursor=abc")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t1")
    }

    @Test func encodesBodySnakeCase() async throws {
        let seen = Recorder()
        let session = StubURLProtocol.session { req in
            seen.record(req)
            return (200, #"{"my_vote": 1, "score": 5}"#)
        }
        let client = APIClient(baseURL: base, session: session, tokens: FakeTokens("t"))
        let result = try await client.send(API.votePost(9, value: 1))
        #expect(result.myVote == 1 && result.score == 5)

        let req = try #require(seen.requests.first)
        #expect(req.httpMethod == "PUT")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(String(decoding: req.httpBody ?? Data(), as: UTF8.self) == #"{"value":1}"#)
    }

    @Test func mapsServerErrorEnvelope() async {
        let session = StubURLProtocol.session { _ in
            (422, #"{"error": {"code": "validation_failed", "message": "too long", "field": "body"}}"#)
        }
        let client = APIClient(baseURL: base, session: session)
        await #expect(throws: APIError.server(status: 422, code: "validation_failed", message: "too long", field: "body")) {
            _ = try await client.send(API.post(1))
        }
    }

    @Test func requiredAuthFailsWithoutTouchingNetwork() async {
        let seen = Recorder()
        let session = StubURLProtocol.session { req in
            seen.record(req)
            return (200, "{}")
        }
        let client = APIClient(baseURL: base, session: session, tokens: FakeTokens(nil))
        await #expect(throws: APIError.unauthorized) {
            _ = try await client.send(API.me())
        }
        #expect(seen.requests.isEmpty)
    }

    @Test func expiredTokenRefreshesAndRetriesOnce() async throws {
        let session = StubURLProtocol.session { req in
            if req.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" {
                return (200, #"{"my_vote": 1, "score": 1}"#)
            }
            return (401, #"{"error": {"code": "token_expired", "message": "expired"}}"#)
        }
        let tokens = FakeTokens("stale")
        let client = APIClient(baseURL: base, session: session, tokens: tokens)
        let result = try await client.send(API.votePost(1, value: 1))
        #expect(result.score == 1)
        #expect(await tokens.refreshes == 1)
    }

    @Test func invalidTokenEndsSession() async {
        let session = StubURLProtocol.session { _ in
            (401, #"{"error": {"code": "unauthorized", "message": "bad token"}}"#)
        }
        let tokens = FakeTokens("forged")
        let client = APIClient(baseURL: base, session: session, tokens: tokens)
        await #expect(throws: APIError.unauthorized) {
            _ = try await client.send(API.me())
        }
        #expect(await tokens.rejected)
        #expect(await tokens.refreshes == 0)
    }

    @Test func noContent() async throws {
        let session = StubURLProtocol.session { _ in (204, "") }
        let client = APIClient(baseURL: base, session: session)
        _ = try await client.send(API.logout("r"))
    }

    @Test func transportErrorsAreRetryableNotSignOut() async {
        let session = StubURLProtocol.session { _ in (503, "upstream down") }
        let client = APIClient(baseURL: base, session: session)
        do {
            _ = try await client.send(API.post(1))
            Issue.record("expected an error")
        } catch {
            #expect(error == .unexpectedStatus(503))
        }
        #expect(APIError.transport(.notConnectedToInternet).isRetryable)
        #expect(!APIError.unauthorized.isRetryable)
    }
}
