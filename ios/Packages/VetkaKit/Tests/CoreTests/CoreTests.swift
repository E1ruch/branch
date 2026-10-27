import Foundation
import Testing
@testable import Core

@Suite struct RouteTests {
    @Test(arguments: [
        ("vetka://post/42", Route.post(id: 42)),
        ("vetka://c/cats", .community(slug: "cats")),
        ("vetka://u/ivan", .user(username: "ivan")),
        ("vetka://comment/7", .commentThread(commentID: 7)),
        ("https://vetka.app/post/42", .post(id: 42)),
        ("https://VETKA.app/c/cats", .community(slug: "cats")),
    ])
    func parses(url: String, route: Route) {
        #expect(Route(url: URL(string: url)!) == route)
    }

    @Test(arguments: [
        "vetka://auth/telegram?id=1&hash=x", // auth callback, not a screen
        "vetka://post/abc",
        "vetka://post/-1",
        "vetka://post",
        "vetka://post/1/extra",
        "https://evil.example/post/42",
        "http://vetka.app/post/42",
    ])
    func rejects(url: String) {
        #expect(Route(url: URL(string: url)!) == nil)
    }
}

@Suite struct JSONTests {
    @Test func decodesPostWithGoDates() throws {
        // Exactly what the Go backend writes: snake_case, RFC 3339 with
        // microseconds and an offset, a null author, a date without fraction.
        let json = """
        {"id": 7, "title": "Котики", "body": "текст", "body_truncated": false, "is_nsfw": false,
         "score": 3, "comment_count": 2, "my_vote": 1,
         "created_at": "2026-10-27T16:48:15.137461+03:00", "edited_at": "2026-10-27T13:50:00Z",
         "community": {"id": 1, "slug": "cats", "title": "Кошки"}, "author": null}
        """
        let post = try JSON.decoder().decode(Post.self, from: Data(json.utf8))
        #expect(post.myVote == 1 && post.commentCount == 2 && post.author == nil)
        #expect(post.community.slug == "cats")
        #expect(abs(post.createdAt.timeIntervalSince1970 - 1_793_108_895.137461) < 0.001)
        #expect(post.editedAt == Date(timeIntervalSince1970: 1_793_109_000))
    }

    @Test func decodesThreadItems() throws {
        let json = """
        {"items": [
          {"kind": "comment", "comment": {"id": 1, "post_id": 7, "parent_id": null, "depth": 0, "body": null,
            "is_deleted": true, "author": null, "score": 0, "my_vote": 0, "reply_count": 1,
            "created_at": "2026-10-27T13:00:00Z", "edited_at": null}},
          {"kind": "more", "parent_id": 1, "depth": 1, "count": 4, "cursor": "abc"},
          {"kind": "continue", "parent_id": 1, "depth": 6, "count": 2}
        ], "next_cursor": null}
        """
        let page = try JSON.decoder().decode(Page<ThreadItem>.self, from: Data(json.utf8))
        #expect(page.items.count == 3 && page.nextCursor == nil)
        guard case let .comment(tomb) = page.items[0] else { Issue.record("not a comment"); return }
        #expect(tomb.isDeleted && tomb.body == nil)
        #expect(page.items[1] == .more(parentId: 1, depth: 1, count: 4, cursor: "abc"))
        #expect(page.items[2] == .continue(parentId: 1, depth: 6, count: 2))
    }

    @Test func tokensRoundTripThroughEncoder() throws {
        let tokens = Tokens(accessToken: "a", accessExpiresAt: Date(timeIntervalSince1970: 1_800_000_000), refreshToken: "r")
        let data = try JSON.encoder().encode(tokens)
        #expect(String(decoding: data, as: UTF8.self).contains("\"access_token\""))
        #expect(try JSON.decoder().decode(Tokens.self, from: data) == tokens)
    }
}
