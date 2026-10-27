import Core
import Foundation
import Networking
import Testing
@testable import Session

/// Counts refresh calls and answers after a short delay, so concurrent
/// callers really overlap.
actor RefreshServer {
    var calls = 0
    var result: Result<Tokens, APIError>

    init(_ result: Result<Tokens, APIError>) { self.result = result }

    func refresh(_ token: String) async throws(APIError) -> Tokens {
        calls += 1
        try? await Task.sleep(for: .milliseconds(50))
        return try result.get()
    }
}

func tokens(_ access: String, expiresIn: TimeInterval, refresh: String = "r1") -> Tokens {
    Tokens(accessToken: access, accessExpiresAt: Date().addingTimeInterval(expiresIn), refreshToken: refresh)
}

func makeStore(_ initial: Tokens?, server: RefreshServer, persistence: InMemoryTokenPersistence? = nil) -> (TokenStore, InMemoryTokenPersistence) {
    let persistence = persistence ?? InMemoryTokenPersistence(initial)
    let store = TokenStore(persistence: persistence) { refresh throws(APIError) in
        try await server.refresh(refresh)
    }
    return (store, persistence)
}

@Suite struct TokenStoreTests {
    @Test func concurrentRejectionsShareOneRefresh() async throws {
        let server = RefreshServer(.success(tokens("fresh", expiresIn: 900, refresh: "r2")))
        let (store, persistence) = makeStore(tokens("stale", expiresIn: 900), server: server)

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 {
                group.addTask { try await store.refreshAfterRejection(of: "stale") }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.allSatisfy { $0 == "fresh" })
        #expect(await server.calls == 1)
        #expect(persistence.load()?.refreshToken == "r2")
    }

    @Test func refreshesAheadOfExpiry() async {
        let server = RefreshServer(.success(tokens("fresh", expiresIn: 900)))
        let (store, _) = makeStore(tokens("almost-expired", expiresIn: 10), server: server)
        #expect(await store.validAccessToken() == "fresh")

        let (valid, _) = makeStore(tokens("valid", expiresIn: 900), server: server)
        #expect(await valid.validAccessToken() == "valid")
        #expect(await server.calls == 1)
    }

    @Test func rejectedRefreshEndsSession() async {
        let server = RefreshServer(.failure(.server(status: 401, code: "refresh_invalid", message: "", field: nil)))
        let (store, persistence) = makeStore(tokens("stale", expiresIn: 900), server: server)
        var events = store.events.makeAsyncIterator()

        await #expect(throws: APIError.unauthorized) {
            _ = try await store.refreshAfterRejection(of: "stale")
        }
        #expect(await !store.isSignedIn)
        #expect(persistence.load() == nil)
        #expect(await events.next() == .ended)
    }

    @Test func offlineRefreshKeepsSession() async {
        let server = RefreshServer(.failure(.transport(.notConnectedToInternet)))
        let (store, _) = makeStore(tokens("stale", expiresIn: 10), server: server)

        // Proactive refresh failed offline: the stale token goes out and the
        // request fails as offline, not as signed out.
        #expect(await store.validAccessToken() == "stale")
        await #expect(throws: APIError.transport(.notConnectedToInternet)) {
            _ = try await store.refreshAfterRejection(of: "stale")
        }
        #expect(await store.isSignedIn)
    }

    @Test func alreadyRefreshedTokenIsReturnedWithoutRefreshing() async throws {
        let server = RefreshServer(.success(tokens("unused", expiresIn: 900)))
        let (store, _) = makeStore(tokens("new", expiresIn: 900), server: server)
        #expect(try await store.refreshAfterRejection(of: "old") == "new")
        #expect(await server.calls == 0)
    }
}
