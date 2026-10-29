import Core
import DesignSystem
import Networking
import Observation

/// The one copy of every profile the app has opened, by username, so a
/// follow on one screen already shows when the user goes back to another.
///
/// Following works like subscribing to a community: the button and the
/// follower count change at once (with a haptic), taps settle for a moment
/// and only the final state goes to the server, whose answer reconciles the
/// count; an error rolls back to what the server last confirmed. Your own
/// "подписки" count, if your profile is loaded, moves along with it.
@MainActor
@Observable
public final class ProfileStore {
    public typealias Send = @Sendable (_ username: String, _ following: Bool) async throws(APIError) -> Profile
    public typealias Fetch = @Sendable (_ username: String) async throws(APIError) -> Profile

    /// By lowercased username: usernames are case-insensitive on the server.
    public private(set) var profiles: [String: Profile] = [:]
    /// Raised when following needs an account.
    @ObservationIgnored public var requestSignIn: () -> Void = {}
    @ObservationIgnored public var isSignedIn: () -> Bool = { false }
    /// The signed-in user's username, for their own "подписки" count.
    @ObservationIgnored public var myUsername: () -> String? = { nil }

    @ObservationIgnored private let send: Send
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private let debounce: Duration
    /// What to roll back to, per username with a change on its way.
    @ObservationIgnored private var confirmed: [String: Profile] = [:]
    /// The latest tap per username; only its response is applied.
    @ObservationIgnored private var latest: [String: Int] = [:]
    @ObservationIgnored private var counter = 0

    public init(debounce: Duration = .milliseconds(300), fetch: @escaping Fetch, send: @escaping Send) {
        self.debounce = debounce
        self.fetch = fetch
        self.send = send
    }

    public convenience init(client: APIClient) {
        self.init { username throws(APIError) in
            try await client.send(API.user(username))
        } send: { username, following throws(APIError) in
            try await client.send(API.setFollow(username, following: following))
        }
    }

    public subscript(username: String) -> Profile? {
        profiles[username.lowercased()]
    }

    /// Takes profiles from the server. A follow still on its way keeps its
    /// optimistic state.
    public func merge(_ incoming: [Profile]) {
        for profile in incoming {
            let key = profile.username.lowercased()
            var new = profile
            if latest[key] != nil, let old = profiles[key] {
                new = new.with(isFollowing: old.isFollowing, followersCount: old.followersCount)
            }
            if profiles[key] != new {
                profiles[key] = new
            }
        }
    }

    @discardableResult
    public func load(_ username: String) async throws(APIError) -> Profile {
        let profile = try await fetch(username)
        merge([profile])
        return self[username] ?? profile
    }

    /// The follow button. Asks to sign in without an account.
    public func toggleFollow(_ username: String) {
        guard isSignedIn() else {
            requestSignIn()
            return
        }
        let key = username.lowercased()
        guard let profile = profiles[key], key != myUsername()?.lowercased() else { return }
        if latest[key] == nil {
            confirmed[key] = profile
        }
        let following = !profile.isFollowing
        let step = following ? 1 : -1
        profiles[key] = profile.with(isFollowing: following, followersCount: max(0, profile.followersCount + step))
        adjustMyFollowing(by: step)
        counter += 1
        let generation = counter
        latest[key] = generation
        Haptics.tap()

        Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            await self?.flush(key, following: following, generation: generation)
        }
    }

    /// Signing in or out changes is_following everywhere: what is cached
    /// belongs to the old account and reloads as screens appear.
    public func sessionChanged() {
        confirmed = [:]
        latest = [:]
        profiles = [:]
    }

    private func flush(_ key: String, following: Bool, generation: Int) async {
        guard latest[key] == generation else { return } // a newer tap took over
        // Tapped back to where the server already is: nothing to send. The
        // taps in between moved your own count by as much back and forth.
        if confirmed[key]?.isFollowing == following {
            if let old = confirmed[key] {
                profiles[key] = old
            }
            settle(key)
            return
        }
        do {
            let result = try await send(key, following)
            guard latest[key] == generation else { return }
            settle(key)
            merge([result])
        } catch {
            guard latest[key] == generation else { return }
            let old = confirmed[key]
            settle(key)
            Haptics.error()
            if let old {
                adjustMyFollowing(by: old.isFollowing ? 1 : -1)
                profiles[key] = profiles[key].map {
                    $0.with(isFollowing: old.isFollowing, followersCount: old.followersCount)
                } ?? old
            }
            if error == .unauthorized {
                requestSignIn()
            }
        }
    }

    private func adjustMyFollowing(by step: Int) {
        guard let me = myUsername()?.lowercased(), let mine = profiles[me] else { return }
        profiles[me] = mine.with(followingCount: max(0, mine.followingCount + step))
    }

    private func settle(_ key: String) {
        latest[key] = nil
        confirmed[key] = nil
    }
}
