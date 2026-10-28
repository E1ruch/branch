import Core
import DesignSystem
import Networking
import Observation

/// The one copy of every community the app has seen, by slug: the search
/// tab, community pages and the composer's picker read it, so subscribing on
/// a community page already shows in the list when the user goes back.
///
/// Subscribing is optimistic like voting: the button and the subscriber
/// count change at once (with a haptic), taps settle for a moment and only
/// the final state goes to the server, whose answer reconciles the count;
/// an error rolls back to what the server last confirmed.
@MainActor
@Observable
public final class CommunityStore {
    public typealias Send = @Sendable (_ slug: String, _ subscribed: Bool) async throws(APIError) -> Community
    public typealias Fetch = @Sendable (_ slug: String) async throws(APIError) -> Community

    /// By lowercased slug: slugs are case-insensitive on the server.
    public private(set) var communities: [String: Community] = [:]
    /// Raised when subscribing needs an account.
    @ObservationIgnored public var requestSignIn: () -> Void = {}
    @ObservationIgnored public var isSignedIn: () -> Bool = { false }

    @ObservationIgnored private let send: Send
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let debounce: Duration
    /// What to roll back to, per slug with a change on its way.
    @ObservationIgnored private var confirmed: [String: Community] = [:]
    /// The latest tap per slug; only its response is applied.
    @ObservationIgnored private var latest: [String: Int] = [:]
    @ObservationIgnored private var counter = 0

    public init(debounce: Duration = .milliseconds(300), fetch: @escaping Fetch, send: @escaping Send) {
        self.debounce = debounce
        self.fetch = fetch
        self.send = send
    }

    public convenience init(client: APIClient) {
        self.init { slug throws(APIError) in
            try await client.send(API.community(slug))
        } send: { slug, subscribed throws(APIError) in
            try await client.send(API.setSubscription(slug, subscribed: subscribed))
        }
    }

    public subscript(slug: String) -> Community? {
        communities[slug.lowercased()]
    }

    /// Takes communities from the server. A subscription still on its way
    /// keeps its optimistic state; a list entry keeps rules already loaded.
    public func merge(_ incoming: [Community]) {
        for community in incoming {
            let key = community.slug.lowercased()
            var new = communities[key].map { $0.merged(with: community) } ?? community
            if latest[key] != nil, let old = communities[key] {
                new = new.with(isSubscribed: old.isSubscribed, subscribersCount: old.subscribersCount)
            }
            if communities[key] != new {
                communities[key] = new
            }
        }
    }

    /// The full community, rules included, for its page.
    @discardableResult
    public func load(_ slug: String) async throws(APIError) -> Community {
        let community = try await fetch(slug)
        merge([community])
        return self[slug] ?? community
    }

    /// The subscribe button. Asks to sign in without an account.
    public func toggleSubscription(_ slug: String) {
        guard isSignedIn() else {
            requestSignIn()
            return
        }
        let key = slug.lowercased()
        guard let community = communities[key] else { return }
        if latest[key] == nil {
            confirmed[key] = community
        }
        let subscribed = !community.isSubscribed
        communities[key] = community.with(isSubscribed: subscribed,
                                          subscribersCount: max(0, community.subscribersCount + (subscribed ? 1 : -1)))
        counter += 1
        let generation = counter
        latest[key] = generation
        Haptics.tap()

        Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            await self?.flush(key, subscribed: subscribed, generation: generation)
        }
    }

    /// Signing in or out changes is_subscribed everywhere: what is cached
    /// belongs to the old account and reloads as screens appear.
    public func sessionChanged() {
        confirmed = [:]
        latest = [:]
        communities = [:]
    }

    private func flush(_ key: String, subscribed: Bool, generation: Int) async {
        guard latest[key] == generation else { return } // a newer tap took over
        // Tapped back to where the server already is: nothing to send.
        if confirmed[key]?.isSubscribed == subscribed {
            if let old = confirmed[key] {
                communities[key] = old
            }
            settle(key)
            return
        }
        do {
            let result = try await send(key, subscribed)
            guard latest[key] == generation else { return }
            settle(key)
            merge([result])
        } catch {
            guard latest[key] == generation else { return }
            let old = confirmed[key]
            settle(key)
            Haptics.error()
            if let old {
                communities[key] = communities[key].map {
                    $0.with(isSubscribed: old.isSubscribed, subscribersCount: old.subscribersCount)
                } ?? old
            }
            if error == .unauthorized {
                requestSignIn()
            }
        }
    }

    private func settle(_ key: String) {
        latest[key] = nil
        confirmed[key] = nil
    }
}
