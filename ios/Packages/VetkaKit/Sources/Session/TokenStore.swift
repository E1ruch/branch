import Core
import Foundation
import Networking

public enum SessionEvent: Sendable, Equatable {
    /// The server ended the session (refresh token revoked or reused).
    case ended
}

/// Owns the tokens and the only code path that refreshes them.
///
/// An actor, so concurrent requests that hit an expired token queue up on
/// one refresh instead of each spending (and, with rotation, invalidating)
/// the refresh token.
public actor TokenStore: AuthTokenProvider {
    public typealias Refresher = @Sendable (_ refreshToken: String) async throws(APIError) -> Tokens

    private var tokens: Tokens?
    private var refreshTask: Task<RefreshOutcome, Never>?
    private let persistence: any TokenPersistence
    private let refresher: Refresher
    private let now: @Sendable () -> Date
    private let eventsContinuation: AsyncStream<SessionEvent>.Continuation

    /// Session-level events for the UI (SessionStore listens).
    public nonisolated let events: AsyncStream<SessionEvent>

    /// Refresh this long before expiry, so requests rarely meet a 401.
    static let refreshLeeway: TimeInterval = 60

    public init(persistence: any TokenPersistence, refresher: @escaping Refresher,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.persistence = persistence
        self.refresher = refresher
        self.now = now
        self.tokens = persistence.load()
        (events, eventsContinuation) = AsyncStream.makeStream()
    }

    public var isSignedIn: Bool {
        tokens != nil
    }

    public var refreshToken: String? {
        tokens?.refreshToken
    }

    public func store(_ tokens: Tokens) {
        self.tokens = tokens
        persistence.save(tokens)
    }

    /// Signs out locally. Any refresh in flight finishes into the void.
    public func clear() {
        tokens = nil
        refreshTask = nil
        persistence.save(nil)
    }

    // MARK: AuthTokenProvider

    public func validAccessToken() async -> String? {
        guard let current = tokens else { return nil }
        if current.accessExpiresAt.timeIntervalSince(now()) > Self.refreshLeeway {
            return current.accessToken
        }
        switch await refresh() {
        case let .refreshed(fresh): return fresh.accessToken
        case .ended: return nil
        // Offline: send the stale token; the request fails as offline, which
        // is the truth, instead of looking signed out.
        case .failed: return current.accessToken
        }
    }

    public func refreshAfterRejection(of token: String) async throws(APIError) -> String {
        // Another request already refreshed while this one was in flight.
        if let current = tokens, current.accessToken != token {
            return current.accessToken
        }
        switch await refresh() {
        case let .refreshed(fresh): return fresh.accessToken
        case .ended: throw .unauthorized
        case let .failed(error): throw error
        }
    }

    public func sessionRejected() async {
        end()
    }

    // MARK: Refresh

    enum RefreshOutcome: Sendable {
        case refreshed(Tokens)
        case ended
        case failed(APIError)
    }

    private func refresh() async -> RefreshOutcome {
        if let inFlight = refreshTask {
            return await inFlight.value
        }
        guard let refreshToken = tokens?.refreshToken else { return .ended }

        // The task inherits the actor: its body runs here, but the actor is
        // free while it awaits the network, so other callers can join it.
        let task = Task { () -> RefreshOutcome in
            let outcome: RefreshOutcome
            do throws(APIError) {
                outcome = .refreshed(try await refresher(refreshToken))
            } catch {
                switch error {
                case .server(401, _, _, _), .unauthorized:
                    outcome = .ended // refresh_invalid: revoked, expired or reused
                default:
                    outcome = .failed(error)
                }
            }
            apply(outcome, usedRefreshToken: refreshToken)
            return outcome
        }
        refreshTask = task
        return await task.value
    }

    private func apply(_ outcome: RefreshOutcome, usedRefreshToken: String) {
        refreshTask = nil
        // Signed out (or in again) while the refresh was in flight: ignore it.
        guard tokens?.refreshToken == usedRefreshToken else { return }
        switch outcome {
        case let .refreshed(fresh): store(fresh)
        case .ended: end()
        case .failed: break
        }
    }

    private func end() {
        guard tokens != nil else { return }
        clear()
        eventsContinuation.yield(.ended)
    }
}
