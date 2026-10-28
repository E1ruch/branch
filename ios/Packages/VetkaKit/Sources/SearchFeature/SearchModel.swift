import Core
import Foundation
import Networking
import Observation
import Stores

/// What the search screen asks the server. A protocol so the model is
/// tested without a network.
public protocol SearchService: Sendable {
    func communities(_ query: String) async throws(APIError) -> [Community]
    func users(_ query: String) async throws(APIError) -> [User]
    func posts(_ query: String) async throws(APIError) -> [Post]
    func popular() async throws(APIError) -> [String]
    /// Counts a search the user meant, for the popular queries.
    func record(_ query: String) async
}

public struct LiveSearchService: SearchService {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public func communities(_ query: String) async throws(APIError) -> [Community] {
        try await client.send(API.searchCommunities(query)).items
    }

    public func users(_ query: String) async throws(APIError) -> [User] {
        try await client.send(API.searchUsers(query)).items
    }

    public func posts(_ query: String) async throws(APIError) -> [Post] {
        try await client.send(API.searchPosts(query)).items
    }

    public func popular() async throws(APIError) -> [String] {
        try await client.send(API.popularQueries()).items
    }

    public func record(_ query: String) async {
        _ = try? await client.send(API.recordSearch(query))
    }
}

/// Something opened from search, kept for "Недавние".
public enum RecentItem: Codable, Hashable, Sendable, Identifiable {
    case community(slug: String, title: String)
    case user(username: String, name: String?)
    case post(id: Int64, title: String, community: String)

    public var id: String {
        switch self {
        case let .community(slug, _): "c/\(slug.lowercased())"
        case let .user(username, _): "u/\(username.lowercased())"
        case let .post(id, _, _): "p/\(id)"
        }
    }

    var route: Route {
        switch self {
        case let .community(slug, _): .community(slug: slug)
        case let .user(username, _): .user(username: username)
        case let .post(id, _, _): .post(id: id)
        }
    }
}

/// Where "Недавние" lives: on the device, per account, like drafts.
public protocol RecentStorage {
    func load() -> [RecentItem]
    func save(_ items: [RecentItem])
}

public struct UserDefaultsRecentStorage: RecentStorage {
    private let key: String
    private let defaults: UserDefaults

    /// `userID` nil: signed out, a list of its own.
    public init(userID: Int64?, defaults: UserDefaults = .standard) {
        key = "search.recent.\(userID.map(String.init) ?? "anonymous")"
        self.defaults = defaults
    }

    public func load() -> [RecentItem] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([RecentItem].self, from: $0) } ?? []
    }

    public func save(_ items: [RecentItem]) {
        defaults.set(try? JSONEncoder().encode(items), forKey: key)
    }
}

/// The search screen: popular queries and recent results while the field
/// is empty; communities, people and posts for what is typed.
///
/// Results for one query come together (three small requests at once), so
/// switching between Всё / Сообщества / Пользователи / Посты is instant.
/// Communities and posts go through the shared stores: subscribing or
/// voting elsewhere shows here, and an opened post appears at once.
@MainActor
@Observable
public final class SearchModel {
    public enum Filter: CaseIterable, Hashable, Sendable {
        case all, communities, users, posts

        public var title: String {
            switch self {
            case .all: "Всё"
            case .communities: "Сообщества"
            case .users: "Пользователи"
            case .posts: "Посты"
            }
        }
    }

    public struct Results: Equatable {
        public var communities: [String] = []
        public var users: [User] = []
        public var posts: [Int64] = []

        var isEmpty: Bool { communities.isEmpty && users.isEmpty && posts.isEmpty }
    }

    public enum Phase: Equatable {
        /// The field is empty (or too short): popular and recent show.
        case idle
        case loading
        case loaded(Results)
        /// `rateLimited`: the server asked to slow down (429), not a network
        /// problem.
        case failed(rateLimited: Bool)
    }

    public var query = ""
    public var filter: Filter = .all
    public private(set) var phase: Phase = .idle
    public private(set) var popular: [String] = []
    public private(set) var recent: [RecentItem]
    @ObservationIgnored public var isSignedIn: Bool

    let communities: CommunityStore
    let posts: PostStore
    @ObservationIgnored private let service: any SearchService
    @ObservationIgnored private let storage: any RecentStorage
    /// The query whose results are on screen.
    @ObservationIgnored private var shownQuery = ""

    /// Communities are few, so two letters are enough for them; people and
    /// posts need three (the server ignores shorter queries for them).
    static let minQueryLength = 2
    static let minPeopleAndPostsLength = 3
    static let maxRecent = 10
    /// Rows per section under Всё; "Все" opens the rest.
    static let previewCount = 3

    public init(service: any SearchService, communities: CommunityStore, posts: PostStore,
                storage: any RecentStorage, isSignedIn: Bool) {
        self.service = service
        self.communities = communities
        self.posts = posts
        self.storage = storage
        self.isSignedIn = isSignedIn
        recent = storage.load()
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func loadPopular() async {
        if let items = try? await service.popular() {
            popular = items
        }
    }

    /// Runs from `.task(id: query)`: typing cancels the previous run, so a
    /// word typed in one go costs one round of requests.
    public func search() async {
        let text = trimmedQuery
        guard text.count >= Self.minQueryLength else {
            phase = .idle
            shownQuery = ""
            return
        }
        if case .failed = phase {} else if text == shownQuery { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        if case .loaded = phase {} else { phase = .loading } // old results stay while the next arrive

        let everything = text.count >= Self.minPeopleAndPostsLength
        async let communities = result { () async throws(APIError) in try await self.service.communities(text) }
        async let users = result { () async throws(APIError) in everything ? try await self.service.users(text) : [] }
        async let posts = result { () async throws(APIError) in everything ? try await self.service.posts(text) : [] }
        let (c, u, p) = await (communities, users, posts)
        guard !Task.isCancelled, text == trimmedQuery else { return }

        switch (c, u, p) {
        case let (.success(c), .success(u), .success(p)):
            self.communities.merge(c)
            self.posts.merge(p)
            phase = .loaded(Results(communities: c.map(\.slug), users: u, posts: p.map(\.id)))
            shownQuery = text
        default:
            let limited = [c.error, u.error, p.error].contains { $0?.code == "rate_limited" }
            phase = .failed(rateLimited: limited)
        }
    }

    /// Return in the field: the user meant this search.
    public func submit() {
        record()
    }

    /// A result or a recent item was tapped: it goes to the top of
    /// "Недавние", and the query that found it counts as meant.
    public func opened(_ item: RecentItem) -> Route {
        if case .loaded = phase {
            record()
        }
        recent.removeAll { $0.id == item.id }
        recent.insert(item, at: 0)
        if recent.count > Self.maxRecent {
            recent.removeLast(recent.count - Self.maxRecent)
        }
        storage.save(recent)
        return item.route
    }

    public func clearRecent() {
        recent = []
        storage.save([])
    }

    /// A popular query chip: search for it right away.
    public func pick(_ text: String) {
        query = text
        record(text)
    }

    private func record(_ text: String? = nil) {
        let text = text ?? trimmedQuery
        guard isSignedIn, text.count >= Self.minQueryLength else { return }
        Task { [service] in await service.record(text) }
    }

    /// `async let` loses a typed error; a Result keeps it.
    private nonisolated func result<T: Sendable>(_ body: @Sendable () async throws(APIError) -> T) async -> Result<T, APIError> {
        do throws(APIError) {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
    }
}

private extension Result {
    var error: Failure? {
        if case let .failure(error) = self { return error }
        return nil
    }
}
