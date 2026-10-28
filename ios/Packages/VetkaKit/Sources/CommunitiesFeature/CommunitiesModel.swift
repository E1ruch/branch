import Core
import Foundation
import Networking
import Observation
import Stores

/// The search tab: popular communities with infinite scroll, my
/// subscriptions, and search. Lists keep slugs in order; the communities themselves
/// come from the shared CommunityStore, so a subscription changed anywhere
/// shows here at once.
@MainActor
@Observable
public final class CommunitiesModel {
    public enum Phase: Equatable {
        case loading
        case loaded
        case failed(APIError)
    }

    public enum Tab: Hashable, Sendable {
        case popular, subscriptions
    }

    public var tab: Tab = .popular
    public private(set) var popular: [String] = []
    /// My subscriptions as the server last listed them; nil until loaded
    /// (or while signed out).
    public private(set) var mySlugs: [String]?
    public private(set) var phase: Phase = .loading
    public var query = ""
    /// Search results for `query`; nil while the field is empty.
    public private(set) var results: [String]?

    let store: CommunityStore
    private var nextCursor: String?
    private var isLoadingMore = false
    private let client: APIClient

    /// Start loading the next page this many rows before the end, so the
    /// user scrolls into rows that are already there.
    static let prefetchDistance = 8

    public init(client: APIClient, store: CommunityStore) {
        self.client = client
        self.store = store
    }

    /// The Подписки tab: the loaded list plus anything subscribed since. A
    /// community unsubscribed here stays (with «Подписаться») until the next
    /// load, so a slip of the finger is one tap to undo.
    var subscriptionRows: [String] {
        guard let mySlugs else { return [] }
        let listed = Set(mySlugs.map { $0.lowercased() })
        let added = store.communities.values.filter { $0.isSubscribed && !listed.contains($0.slug.lowercased()) }
        return (mySlugs.compactMap { store[$0] } + added)
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
            .map(\.slug)
    }

    /// The counter on the Подписки tab: subscribed right now.
    var subscriptionCount: Int? {
        mySlugs == nil ? nil : subscriptionRows.count { store[$0]?.isSubscribed == true }
    }

    /// The counter on the Популярное tab. There is no total on the server:
    /// "25+" while more pages are left.
    var popularCount: String? {
        guard phase == .loaded else { return nil }
        return nextCursor == nil ? "\(popular.count)" : "\(popular.count)+"
    }

    subscript(slug: String) -> Community? { store[slug] }

    /// A row's subscribe button. The community joins the Подписки list
    /// either way, so unsubscribing does not make its row vanish.
    func toggleSubscription(_ slug: String) {
        if let mySlugs, !mySlugs.contains(where: { $0.caseInsensitiveCompare(slug) == .orderedSame }) {
            self.mySlugs = mySlugs + [slug]
        }
        store.toggleSubscription(slug)
    }

    /// First page, or a pull-to-refresh: old rows stay on screen until the
    /// new ones arrive, no blanking.
    public func load(signedIn: Bool) async {
        if popular.isEmpty {
            phase = .loading
        }
        async let mine: Void = loadSubscriptions(signedIn: signedIn)
        do throws(APIError) {
            let page = try await client.send(API.popularCommunities())
            store.merge(page.items)
            popular = page.items.map(\.slug)
            nextCursor = page.nextCursor
            phase = .loaded
        } catch .cancelled {
            // The view went away; nothing to show.
        } catch {
            if popular.isEmpty {
                phase = .failed(error)
            }
        }
        await mine
    }

    private func loadSubscriptions(signedIn: Bool) async {
        guard signedIn else {
            mySlugs = nil
            return
        }
        guard let page = try? await client.send(API.mySubscriptions()) else { return }
        store.merge(page.items)
        mySlugs = page.items.map(\.slug)
    }

    /// Runs from `.task(id: query)`: typing cancels the previous run, so a
    /// word typed in one go costs one request.
    public func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        if let page = try? await client.send(API.searchCommunities(text)), text == query.trimmingCharacters(in: .whitespaces) {
            store.merge(page.items)
            results = page.items.map(\.slug)
        }
    }

    public func loadMoreIfNeeded(after slug: String) async {
        guard let cursor = nextCursor, !isLoadingMore,
              let index = popular.lastIndex(of: slug),
              index >= popular.count - Self.prefetchDistance else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await client.send(API.popularCommunities(cursor: cursor)) else { return }
        store.merge(page.items)
        // Counts move while scrolling, so a community can show up twice
        // across pages; keep the first.
        let known = Set(popular)
        popular.append(contentsOf: page.items.map(\.slug).filter { !known.contains($0) })
        nextCursor = page.nextCursor
    }
}
