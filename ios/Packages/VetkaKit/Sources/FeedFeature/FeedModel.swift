import Core
import DesignSystem
import Foundation
import Networking
import UIKit

public enum FeedKind: String, CaseIterable, Hashable, Sendable {
    case hot, new, subscriptions

    public var title: String {
        switch self {
        case .hot: "Горячее"
        case .new: "Новое"
        case .subscriptions: "Подписки"
        }
    }

    var requiresSignIn: Bool { self == .subscriptions }
}

/// What the feed needs from the server. A protocol so the paging and
/// optimistic-vote logic is tested without a network.
public protocol FeedService: Sendable {
    func page(_ kind: FeedKind, cursor: String?) async throws(APIError) -> Page<Post>
    func vote(post id: Int64, value: Int) async throws(APIError) -> VoteResult
}

public struct LiveFeedService: FeedService {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public func page(_ kind: FeedKind, cursor: String?) async throws(APIError) -> Page<Post> {
        switch kind {
        case .hot: try await client.send(API.feedAll(sort: .hot, cursor: cursor))
        case .new: try await client.send(API.feedAll(sort: .new, cursor: cursor))
        case .subscriptions: try await client.send(API.feedSubscriptions(sort: .hot, cursor: cursor))
        }
    }

    public func vote(post id: Int64, value: Int) async throws(APIError) -> VoteResult {
        try await client.send(API.votePost(id, value: value))
    }
}

/// One feed's state. Main-actor bound like the view controller that shows
/// it; the heavy parts (network, decoding, text measuring) run elsewhere.
@MainActor
final class FeedModel {
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

    let kind: FeedKind
    private(set) var ids: [Int64] = []
    private(set) var posts: [Int64: Post] = [:]
    private(set) var layouts: [Int64: PostLayout] = [:]
    private(set) var phase: Phase = .loading
    private(set) var fonts: FeedFonts
    var onChange: ((Change) -> Void)?

    var isSignedIn: Bool
    private let requestSignIn: () -> Void
    private let service: any FeedService
    private let voteDebounce: Duration

    private var width: CGFloat = 0
    private var nextCursor: String?
    private var isLoadingMore = false
    private var loadGeneration = 0

    /// Optimistic votes: the server state to roll back to, and a counter per
    /// post so only the latest tap's response is applied.
    private var confirmed: [Int64: (myVote: Int, score: Int)] = [:]
    private var voteGeneration: [Int64: Int] = [:]

    /// Load the next page this many posts before the end, so scrolling
    /// reaches posts that are already there.
    static let prefetchDistance = 10

    init(kind: FeedKind, service: any FeedService, isSignedIn: Bool,
         requestSignIn: @escaping () -> Void, voteDebounce: Duration = .milliseconds(300),
         category: UIContentSizeCategory = .large) {
        self.kind = kind
        self.service = service
        self.isSignedIn = isSignedIn
        self.requestSignIn = requestSignIn
        self.voteDebounce = voteDebounce
        self.fonts = FeedFonts(category: category)
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
        guard !kind.requiresSignIn || isSignedIn else {
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
            let page = try await service.page(kind, cursor: nil)
            let measured = await Self.measure(page.items, width: width, fonts: fonts)
            guard generation == loadGeneration else { return }

            ids = []
            var seen = Set<Int64>()
            var fresh: [Int64: Post] = [:]
            for post in page.items where seen.insert(post.id).inserted {
                ids.append(post.id)
                // A vote still on its way keeps its optimistic state.
                fresh[post.id] = voteGeneration[post.id] != nil ? (posts[post.id] ?? post) : post
            }
            posts = fresh
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
        guard let page = try? await service.page(kind, cursor: cursor) else { return }
        let measured = await Self.measure(page.items, width: width, fonts: fonts)
        guard generation == loadGeneration else { return } // refreshed meanwhile

        // Ranks move while people scroll: a post can come back on a later page.
        for post in page.items where posts[post.id] == nil {
            ids.append(post.id)
            posts[post.id] = post
            layouts[post.id] = measured[post.id]
        }
        nextCursor = page.nextCursor
        onChange?(.list)
    }

    /// Signing in or out changes my_vote everywhere and opens Подписки.
    func sessionChanged(signedIn: Bool) async {
        guard signedIn != isSignedIn else { return }
        isSignedIn = signedIn
        confirmed = [:]
        voteGeneration = [:]
        reset(phase: .loading)
        await load()
    }

    private func reset(phase: Phase) {
        loadGeneration += 1
        ids = []
        posts = [:]
        layouts = [:]
        nextCursor = nil
        self.phase = phase
        onChange?(.list)
    }

    // MARK: Votes

    /// A tap on ▲ (direction 1) or ▼ (-1). Tapping the active arrow again
    /// clears the vote. The screen updates now; the request goes out once the
    /// taps settle, carrying only the final state.
    func tapVote(_ id: Int64, direction: Int) {
        guard isSignedIn else {
            requestSignIn()
            return
        }
        guard let post = posts[id] else { return }
        let value = post.myVote == direction ? 0 : direction

        if voteGeneration[id] == nil {
            confirmed[id] = (post.myVote, post.score)
        }
        let generation = (voteGeneration[id] ?? 0) + 1
        voteGeneration[id] = generation
        posts[id] = post.with(myVote: value, score: post.score - post.myVote + value)
        Haptics.tap()
        onChange?(.posts([id]))

        Task { [weak self, voteDebounce] in
            try? await Task.sleep(for: voteDebounce)
            await self?.send(id, value: value, generation: generation)
        }
    }

    private func send(_ id: Int64, value: Int, generation: Int) async {
        guard voteGeneration[id] == generation else { return } // a newer tap took over
        do {
            let result = try await service.vote(post: id, value: value)
            guard voteGeneration[id] == generation, let post = posts[id] else { return }
            // The server's score includes everyone's votes, ours too.
            posts[id] = post.with(myVote: result.myVote, score: result.score)
            voteGeneration[id] = nil
            confirmed[id] = nil
            onChange?(.posts([id]))
        } catch {
            guard voteGeneration[id] == generation else { return }
            if let (myVote, score) = confirmed[id], let post = posts[id] {
                posts[id] = post.with(myVote: myVote, score: score)
            }
            voteGeneration[id] = nil
            confirmed[id] = nil
            Haptics.error()
            onChange?(.posts([id]))
            if error == .unauthorized {
                requestSignIn()
            }
        }
    }
}
