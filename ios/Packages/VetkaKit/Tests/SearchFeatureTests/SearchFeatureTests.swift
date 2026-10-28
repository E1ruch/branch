import Core
import Foundation
import Networking
import Stores
import Testing
@testable import SearchFeature

private func decode<T: Decodable>(_ json: String) -> T {
    try! JSON.decoder().decode(T.self, from: Data(json.utf8))
}

private func community(_ slug: String) -> Community {
    decode("""
    {"id": 1, "slug": "\(slug)", "title": "Игры", "description": "", "is_nsfw": false, "subscribers_count": 3,
     "created_at": "2026-10-01T12:00:00Z", "is_subscribed": false, "viewer_role": null}
    """)
}

private func post(_ id: Int64) -> Post {
    decode("""
    {"id": \(id), "title": "Лучшие игры", "body": "", "body_truncated": false, "is_nsfw": false, "score": 5,
     "comment_count": 1, "my_vote": 0, "created_at": "2026-10-01T12:00:00Z", "edited_at": null,
     "community": {"id": 1, "slug": "igry", "title": "Игры"}, "author": null, "story": null}
    """)
}

actor FakeSearch: SearchService {
    var asked: [String] = []
    var recorded: [String] = []
    var fails = false

    func setFails(_ value: Bool) { fails = value }

    func communities(_ query: String) async throws(APIError) -> [Community] {
        asked.append(query)
        if fails { throw .transport(.notConnectedToInternet) }
        return [community("igry")]
    }

    func users(_ query: String) async throws(APIError) -> [User] { [] }

    func posts(_ query: String) async throws(APIError) -> [Post] {
        if fails { throw .transport(.notConnectedToInternet) }
        return [post(7)]
    }

    func popular() async throws(APIError) -> [String] { ["юмор", "игры"] }
    func record(_ query: String) async { recorded.append(query) }
}

final class MemoryRecent: RecentStorage {
    var items: [RecentItem] = []
    func load() -> [RecentItem] { items }
    func save(_ items: [RecentItem]) { self.items = items }
}

@MainActor
@Suite(.serialized) struct SearchModelTests {
    func model(_ service: FakeSearch, storage: MemoryRecent = MemoryRecent(), signedIn: Bool = true) -> SearchModel {
        let communities = CommunityStore { _ throws(APIError) in throw .cancelled } send: { _, _ throws(APIError) in throw .cancelled }
        let posts = PostStore { _, _ throws(APIError) in throw .cancelled }
        return SearchModel(service: service, communities: communities, posts: posts, storage: storage, isSignedIn: signedIn)
    }

    @Test func shortQueriesStayIdleAndResultsFillTheStores() async {
        let service = FakeSearch()
        let m = model(service)
        m.query = "и"
        await m.search()
        #expect(m.phase == .idle)
        #expect(await service.asked.isEmpty)

        m.query = "  игры "
        await m.search()
        #expect(m.phase == .loaded(SearchModel.Results(communities: ["igry"], users: [], posts: [7])))
        #expect(await service.asked == ["игры"])
        #expect(m.communities["igry"] != nil && m.posts[7] != nil)
    }

    @Test func aFailureShowsAndRetries() async {
        let service = FakeSearch()
        await service.setFails(true)
        let m = model(service)
        m.query = "игры"
        await m.search()
        #expect(m.phase == .failed(rateLimited: false))
        await service.setFails(false)
        await m.search() // the same query again after a failure
        if case .loaded = m.phase {} else { Issue.record("not retried: \(m.phase)") }
    }

    @Test func twoLettersSearchOnlyCommunities() async {
        let service = FakeSearch()
        let m = model(service)
        m.query = "иг"
        await m.search()
        #expect(m.phase == .loaded(SearchModel.Results(communities: ["igry"], users: [], posts: [])))
    }

    @Test func recentKeepsTenNewestFirstWithoutDuplicates() {
        let storage = MemoryRecent()
        let m = model(FakeSearch(), storage: storage)
        for i in 0..<12 {
            _ = m.opened(.post(id: Int64(i), title: "п", community: "к"))
        }
        let route = m.opened(.post(id: 5, title: "п", community: "к"))
        #expect(route == .post(id: 5))
        #expect(m.recent.count == SearchModel.maxRecent)
        #expect(m.recent.first?.id == "p/5" && m.recent.filter { $0.id == "p/5" }.count == 1)
        #expect(storage.items == m.recent)

        m.clearRecent()
        #expect(m.recent.isEmpty && storage.items.isEmpty)
    }

    @Test func onlyMeantSearchesAreRecordedAndOnlySignedIn() async throws {
        let service = FakeSearch()
        let m = model(service)
        m.query = "игры"
        await m.search()
        #expect(await service.recorded.isEmpty) // typing alone does not count
        _ = m.opened(.community(slug: "igry", title: "Игры"))
        m.pick("юмор")
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.recorded == ["игры", "юмор"])

        let anonymous = FakeSearch()
        let a = model(anonymous, signedIn: false)
        a.query = "игры"
        a.submit()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await anonymous.recorded.isEmpty)
    }
}
