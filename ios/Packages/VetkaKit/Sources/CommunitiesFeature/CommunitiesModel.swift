import Core
import Foundation
import Networking
import Observation

/// Popular communities with infinite scroll.
@MainActor
@Observable
public final class CommunitiesModel {
    public enum Phase: Equatable {
        case loading
        case loaded
        case failed(APIError)
    }

    public private(set) var items: [Community] = []
    public private(set) var phase: Phase = .loading
    public var query = ""
    /// Search results for `query`; nil while the field is empty.
    public private(set) var results: [Community]?

    private var nextCursor: String?
    private var isLoadingMore = false
    private let client: APIClient

    /// Start loading the next page this many rows before the end, so the
    /// user scrolls into rows that are already there.
    static let prefetchDistance = 8

    public init(client: APIClient) {
        self.client = client
    }

    /// First page, or a pull-to-refresh: old rows stay on screen until the
    /// new ones arrive, no blanking.
    public func load() async {
        if items.isEmpty {
            phase = .loading
        }
        do {
            let page = try await client.send(API.popularCommunities())
            items = page.items
            nextCursor = page.nextCursor
            phase = .loaded
        } catch .cancelled {
            // The view went away; nothing to show.
        } catch {
            if items.isEmpty {
                phase = .failed(error)
            }
        }
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
            results = page.items
        }
    }

    public func loadMoreIfNeeded(after item: Community) async {
        guard let cursor = nextCursor, !isLoadingMore,
              let index = items.lastIndex(of: item),
              index >= items.count - Self.prefetchDistance else { return }

        isLoadingMore = true
        defer { isLoadingMore = false }
        guard let page = try? await client.send(API.popularCommunities(cursor: cursor)) else { return }
        // Counts move while scrolling, so a community can show up twice
        // across pages; keep the first.
        let known = Set(items.map(\.id))
        items.append(contentsOf: page.items.filter { !known.contains($0.id) })
        nextCursor = page.nextCursor
    }
}
