import Core
import Networking
import Observation
import Stores

/// One list of people around a profile, page by page. The people
/// themselves go to ProfileStore, so a follow button here, on their profile
/// and in the other list is one state.
@MainActor
@Observable
public final class FollowListModel {
    public typealias Fetch = @Sendable (_ username: String, _ list: FollowList, _ cursor: String?)
        async throws(APIError) -> Page<Profile>

    public enum Phase: Equatable {
        case loading
        case loaded
        case failed
    }

    public let list: FollowList
    public private(set) var usernames: [String] = []
    public private(set) var phase: Phase = .loading
    public private(set) var isLoadingMore = false

    @ObservationIgnored private let username: String
    @ObservationIgnored private let profiles: ProfileStore
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var nextCursor: String?
    @ObservationIgnored private var generation = 0

    /// Load the next page this many rows before the end.
    static let prefetchDistance = 8

    public init(username: String, list: FollowList, profiles: ProfileStore, fetch: @escaping Fetch) {
        self.username = username
        self.list = list
        self.profiles = profiles
        self.fetch = fetch
    }

    public convenience init(username: String, list: FollowList, profiles: ProfileStore, client: APIClient) {
        self.init(username: username, list: list, profiles: profiles) { username, list, cursor throws(APIError) in
            switch list {
            case .followers: try await client.send(API.followers(username, cursor: cursor))
            case .following: try await client.send(API.following(username, cursor: cursor))
            }
        }
    }

    /// The first page, again on pull-to-refresh. Rows already shown stay
    /// until the new page replaces them.
    public func load() async {
        generation += 1
        let current = generation
        if usernames.isEmpty {
            phase = .loading
        }
        do throws(APIError) {
            let page = try await fetch(username, list, nil)
            guard current == generation else { return }
            profiles.merge(page.items)
            usernames = page.items.map(\.username)
            nextCursor = page.nextCursor
            phase = .loaded
        } catch .cancelled {
        } catch {
            guard current == generation else { return }
            if usernames.isEmpty {
                phase = .failed
            }
        }
    }

    /// Called as rows appear: fetches the next page near the end.
    public func loadMoreIfNeeded(showing username: String) async {
        guard let cursor = nextCursor, !isLoadingMore, phase == .loaded,
              let index = usernames.lastIndex(of: username),
              index >= usernames.count - Self.prefetchDistance else { return }
        let current = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        do throws(APIError) {
            let page = try await fetch(self.username, list, cursor)
            guard current == generation else { return }
            profiles.merge(page.items)
            let known = Set(usernames)
            usernames += page.items.map(\.username).filter { !known.contains($0) }
            nextCursor = page.nextCursor
        } catch {
            // The next row that appears tries again.
        }
    }
}
