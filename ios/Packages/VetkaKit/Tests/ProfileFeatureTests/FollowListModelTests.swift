import Core
import Foundation
import Networking
import Stores
import Testing
@testable import ProfileFeature

private func person(_ username: String, following: Bool = false) -> Profile {
    Profile(id: Int64(abs(username.hashValue % 10_000)), username: username, displayName: nil, bio: nil,
            postKarma: 0, commentKarma: 0, createdAt: Date(timeIntervalSince1970: 0), postsCount: 0,
            followersCount: 0, followingCount: 0, isFollowing: following)
}

actor PageServer {
    var pages: [String?: Page<Profile>] = [:]
    var requests: [(FollowList, String?)] = []
    var error: APIError?

    func set(_ cursor: String?, _ page: Page<Profile>) { pages[cursor] = page }
    func fail(with error: APIError?) { self.error = error }

    func fetch(_ list: FollowList, _ cursor: String?) throws(APIError) -> Page<Profile> {
        requests.append((list, cursor))
        if let error { throw error }
        return pages[cursor] ?? Page(items: [], nextCursor: nil)
    }
}

@MainActor
@Suite(.serialized) struct FollowListModelTests {
    func make(_ server: PageServer, store: ProfileStore) -> FollowListModel {
        FollowListModel(username: "ivan", list: .followers, profiles: store) { _, list, cursor throws(APIError) in
            try await server.fetch(list, cursor)
        }
    }

    func store() -> ProfileStore {
        ProfileStore { username throws(APIError) in person(username) } send: { username, following throws(APIError) in
            person(username, following: following)
        }
    }

    @Test func pagesGoToTheStoreAndAppendWithoutDuplicates() async {
        let server = PageServer()
        let names = (0..<10).map { "user\($0)" }
        await server.set(nil, Page(items: names.map { person($0, following: $0 == "user0") }, nextCursor: "c1"))
        await server.set("c1", Page(items: [person("user9"), person("user10")], nextCursor: nil))
        let profiles = store()
        let model = make(server, store: profiles)

        await model.load()
        #expect(model.phase == .loaded && model.usernames == names)
        #expect(profiles["user0"]?.isFollowing == true) // the buttons read the store

        await model.loadMoreIfNeeded(showing: "user0") // far from the end: nothing
        #expect(await server.requests.count == 1)
        await model.loadMoreIfNeeded(showing: "user5")
        #expect(model.usernames == names + ["user10"])
        await model.loadMoreIfNeeded(showing: "user10") // no cursor left
        #expect(await server.requests.count == 2)
    }

    @Test func failureShowsErrorOnlyWithoutRows() async {
        let server = PageServer()
        await server.fail(with: .transport(.notConnectedToInternet))
        let model = make(server, store: store())
        await model.load()
        #expect(model.phase == .failed)

        await server.fail(with: nil)
        await server.set(nil, Page(items: [person("a")], nextCursor: nil))
        await model.load()
        #expect(model.phase == .loaded && model.usernames == ["a"])

        await server.fail(with: .transport(.timedOut))
        await model.load() // a failed refresh keeps what is shown
        #expect(model.phase == .loaded && model.usernames == ["a"])
    }
}
