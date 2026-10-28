import Core
import DesignSystem
import Foundation
import Networking
import Stores
import UIKit

/// Where a feed's pages come from.
public enum FeedSource: Hashable, Sendable {
    /// Everything: the feed tab's Горячее and Новое.
    case all(API.FeedSort)
    case subscriptions
    case community(slug: String, sort: API.FeedSort)
    /// A user's posts, newest first.
    case user(username: String)

    var requiresSignIn: Bool { self == .subscriptions }

    /// For UI tests: feed.hot, feed.community.new…
    var accessibilityName: String {
        switch self {
        case let .all(sort): sort.rawValue
        case .subscriptions: "subscriptions"
        case let .community(_, sort): "community.\(sort.rawValue)"
        case .user: "user"
        }
    }
}

/// What the feed needs from the server. A protocol so the paging logic is
/// tested without a network. Votes go through the shared PostStore.
public protocol FeedService: Sendable {
    func page(_ source: FeedSource, cursor: String?) async throws(APIError) -> Page<Post>
}

public struct LiveFeedService: FeedService {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public func page(_ source: FeedSource, cursor: String?) async throws(APIError) -> Page<Post> {
        switch source {
        case let .all(sort): try await client.send(API.feedAll(sort: sort, cursor: cursor))
        case .subscriptions: try await client.send(API.feedSubscriptions(sort: .hot, cursor: cursor))
        case let .community(slug, sort): try await client.send(API.communityFeed(slug, sort: sort, cursor: cursor))
        case let .user(username): try await client.send(API.userPosts(username, cursor: cursor))
        }
    }
}

/// One feed's state. Main-actor bound like the view controller that shows
/// it; the heavy parts (network, decoding, text measuring) run elsewhere.
@MainActor
public final class FeedModel {
    enum Phase: Equatable {
        case loading, loaded, failed(APIError), signInRequired
    }

    enum Change {
        /// The list itself changed (first page, refresh, next page).
        case list
        /// These posts changed in place (a vote).
        case posts([Int64])
        /// Only the phase changed (loading, error).
        case phase
    }

    let source: FeedSource
    private(set) var ids: [Int64] = []
    /// The posts themselves live in the store, shared with the post screen.
    var posts: [Int64: Post] { store.posts }
    private(set) var layouts: [Int64: PostLayout] = [:]
    private(set) var phase: Phase = .loading
    private(set) var fonts: FeedFonts
    var onChange: ((Change) -> Void)?

    public private(set) var isSignedIn: Bool
    private let requestSignIn: () -> Void
    private let service: any FeedService
    private let store: PostStore
    private var idSet: Set<Int64> = []

    private var width: CGFloat = 0
    private var nextCursor: String?
    private var isLoadingMore = false
    private var loadGeneration = 0

    /// Load the next page this many posts before the end, so scrolling
    /// reaches posts that are already there.
    static let prefetchDistance = 10

    public init(source: FeedSource, service: any FeedService, store: PostStore, isSignedIn: Bool,
                requestSignIn: @escaping () -> Void, category: UIContentSizeCategory = .large) {
        self.source = source
        self.service = service
        self.store = store
        self.isSignedIn = isSignedIn
        self.requestSignIn = requestSignIn
        self.fonts = FeedFonts(category: category)
        store.observe(self) { [weak self] changed in
            guard let self else { return }
            let mine = changed.filter(idSet.contains)
            if !mine.isEmpty {
                onChange?(.posts(mine))
            }
        }
    }

    // MARK: Layout

    var hasWidth: Bool { width > 0 }

    /// Called by the view on layout. A new width or text size re-measures
    /// every post off the main actor, then reloads.
    func setWidth(_ newWidth: CGFloat, category: UIContentSizeCategory) async {
        let newFonts = FeedFonts(category: category)
        guard newWidth > 0, newWidth != width || newFonts.body.pointSize != fonts.body.pointSize else { return }
        width = newWidth
        fonts = newFonts
        guard !ids.isEmpty else { return }
        let all = ids.compactMap { posts[$0] }
        layouts = await Self.measure(all, width: newWidth, fonts: newFonts)
        onChange?(.list)
    }

    /// Text measuring for a page: nonisolated, so it runs on the cooperative
    /// pool and the main thread keeps rendering the scroll.
    nonisolated static func measure(_ posts: [Post], width: CGFloat, fonts: FeedFonts) async -> [Int64: PostLayout] {
        let now = Date()
        var result: [Int64: PostLayout] = [:]
        result.reserveCapacity(posts.count)
        for post in posts {
            result[post.id] = PostLayout.make(for: post, width: width, fonts: fonts, now: now)
        }
        return result
    }

    // MARK: Paging

    /// The first page or a pull-to-refresh. Old posts stay on screen until
    /// the new page arrives.
    func load() async {
        guard !source.requiresSignIn || isSignedIn else {
            reset(phase: .signInRequired)
            return
        }
        if ids.isEmpty {
            phase = .loading
            onChange?(.phase)
        }
        loadGeneration += 1
        let generation = loadGeneration
        do {
            let page = try await service.page(source, cursor: nil)
            let measured = await Self.measure(page.items, width: width, fonts: fonts)
            guard generation == loadGeneration else { return }

            ids = []
            idSet = []
            for post in page.items where idSet.insert(post.id).inserted {
                ids.append(post.id)
            }
            store.merge(page.items)
            layouts = measured
            nextCursor = page.nextCursor
            phase = .loaded
            onChange?(.list)
        } catch .cancelled {
        } catch {
            if ids.isEmpty {
                phase = .failed(error)
                onChange?(.phase)
            }
        }
    }

    func loadMoreIfNeeded(displaying index: Int) async {
        guard let cursor = nextCursor, !isLoadingMore,
              index >= ids.count - Self.prefetchDistance else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = loadGeneration
        guard let page = try? await service.page(source, cursor: cursor) else { return }
        let measured = await Self.measure(page.items, width: width, fonts: fonts)
        guard generation == loadGeneration else { return } // refreshed meanwhile

        // Ranks move while people scroll: a post can come back on a later page.
        store.merge(page.items)
        for post in page.items where idSet.insert(post.id).inserted {
            ids.append(post.id)
            layouts[post.id] = measured[post.id]
        }
        nextCursor = page.nextCursor
        onChange?(.list)
    }

    /// Signing in or out changes my_vote everywhere and opens Подписки.
    public func sessionChanged(signedIn: Bool) async {
        guard signedIn != isSignedIn else { return }
        isSignedIn = signedIn
        reset(phase: .loading)
        await load()
    }

    private func reset(phase: Phase) {
        loadGeneration += 1
        ids = []
        idSet = []
        layouts = [:]
        nextCursor = nil
        self.phase = phase
        onChange?(.list)
    }

    // MARK: Votes

    /// A tap on ▲ (direction 1) or ▼ (-1): optimistic, through the store.
    func tapVote(_ id: Int64, direction: Int) {
        guard isSignedIn else {
            requestSignIn()
            return
        }
        store.vote(id, direction: direction)
    }
}
