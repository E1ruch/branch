import Core
@testable import DesignSystem
import Foundation
import Networking
import Testing
import UIKit
@testable import FeedFeature

func makePost(_ id: Int64, title: String = "Заголовок", body: String = "", truncated: Bool = false,
              score: Int = 0, myVote: Int = 0, age: TimeInterval = 3600) throws -> Post {
    let json = """
    {"id": \(id), "title": "\(title)", "body": "\(body)", "body_truncated": \(truncated), "is_nsfw": false,
     "score": \(score), "comment_count": 3, "my_vote": \(myVote),
     "created_at": "\(Date().addingTimeInterval(-age).formatted(.iso8601))", "edited_at": null,
     "community": {"id": 1, "slug": "kotiki", "title": "Котики"},
     "author": {"id": 2, "username": "ivan", "display_name": null}}
    """
    return try JSON.decoder().decode(Post.self, from: Data(json.utf8))
}

@Suite struct PostLayoutTests {
    let fonts = FeedFonts(category: .large)

    @Test func bodyIsCappedAndTruncationShowsEllipsis() throws {
        let short = PostLayout.make(for: try makePost(1, body: "Коротко"), width: 390, fonts: fonts)
        let long = PostLayout.make(for: try makePost(2, body: String(repeating: "очень длинный текст ", count: 40), truncated: true),
                                   width: 390, fonts: fonts)
        #expect(short.bodyLines == 0) // fits: no cap
        #expect(long.bodyLines == PostLayout.maxBodyLines)
        #expect(long.bodyText.hasSuffix("…"))
        #expect(long.bodyFrame.height <= ceil(fonts.body.lineHeight * CGFloat(PostLayout.maxBodyLines)))
        #expect(long.height > short.height)
    }

    @Test func noBodyNoBodyFrame() throws {
        let layout = PostLayout.make(for: try makePost(1), width: 390, fonts: fonts)
        #expect(layout.bodyFrame == .zero)
        #expect(layout.footerFrame.minY > layout.titleFrame.maxY)
        #expect(layout.height >= layout.footerFrame.maxY)
    }

    @Test func narrowerScreensWrapMore() throws {
        let post = try makePost(1, title: String(repeating: "Длинный заголовок ", count: 6))
        #expect(PostLayout.make(for: post, width: 320, fonts: fonts).height > PostLayout.make(for: post, width: 430, fonts: fonts).height)
    }

    @Test func headerAndAge() throws {
        let now = Date()
        #expect(PostLayout.relativeAge(from: now.addingTimeInterval(-30), now: now) == "только что")
        #expect(PostLayout.relativeAge(from: now.addingTimeInterval(-300), now: now) == "5 мин назад")
        #expect(PostLayout.relativeAge(from: now.addingTimeInterval(-7200), now: now) == "2 ч назад")
        #expect(PostLayout.relativeAge(from: now.addingTimeInterval(-86400 * 3), now: now) == "3 д назад")
        let layout = PostLayout.make(for: try makePost(1, age: 7200), width: 390, fonts: fonts, now: now)
        #expect(layout.author == "ivan" && layout.meta == "2 ч назад · Котики")
    }

    @Test func headerSitsBesideTheAvatarAndTheGapFollowsThePost() throws {
        let layout = PostLayout.make(for: try makePost(1, body: "текст"), width: 390, fonts: fonts)
        #expect(layout.authorFrame.minX > layout.avatarFrame.maxX)
        #expect(layout.authorFrame.maxX <= layout.moreFrame.minX)
        #expect(layout.titleFrame.minY >= layout.avatarFrame.maxY)
        #expect(layout.height == layout.contentHeight + PostLayout.gap)
    }
}

@Suite struct SwipeVoteTests {
    @Test func shortDragsDoNothing() {
        #expect(SwipeVote.direction(for: 40) == nil)
        #expect(SwipeVote.direction(for: -71) == nil)
    }

    @Test func rightIsForLeftIsAgainst() {
        #expect(SwipeVote.direction(for: 90) == 1)
        #expect(SwipeVote.direction(for: -90) == -1)
    }

    @Test func dragResistsPastTheThreshold() {
        #expect(SwipeVote.offset(for: 50) == 50)
        #expect(SwipeVote.offset(for: SwipeVote.threshold + 30) == SwipeVote.threshold + 10)
        #expect(SwipeVote.offset(for: -(SwipeVote.threshold + 30)) == -(SwipeVote.threshold + 10))
    }
}

@Suite struct DesignSystemTests {
    @Test(arguments: [(950, "950"), (1000, "1k"), (12_400, "12,4k"), (156_700, "156k"), (9_950, "9,9k"), (3_450_000, "3,4M"), (-1200, "−1,2k")])
    func compactCounters(value: Int, text: String) {
        // Decimal separator follows the locale; the tests run with Russian ones in mind.
        #expect(value.compactFormatted.replacingOccurrences(of: ".", with: ",") == text)
    }

    @Test func avatarColorIsStableAcrossLaunches() {
        // The published FNV-1a 64 value for "a": the same on every launch,
        // unlike String.hashValue, which is seeded per process.
        #expect(Palette.stableHash("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(Palette.avatarColor(for: "ivan") == Palette.avatarColor(for: "ivan"))
    }
}

actor FakeFeedService: FeedService {
    var pages: [String?: Page<Post>] = [:]
    var votes: [(Int64, Int)] = []
    var voteError: APIError?
    var serverScore = 42

    func setPage(_ cursor: String?, _ page: Page<Post>) { pages[cursor] = page }
    func failVotes(with error: APIError?) { voteError = error }

    func page(_ kind: FeedKind, cursor: String?) async throws(APIError) -> Page<Post> {
        guard let page = pages[cursor] else { throw .transport(.notConnectedToInternet) }
        return page
    }

    func vote(post id: Int64, value: Int) async throws(APIError) -> VoteResult {
        votes.append((id, value))
        if let voteError { throw voteError }
        let json = #"{"my_vote": \#(value), "score": \#(serverScore)}"#
        return try! JSON.decoder().decode(VoteResult.self, from: Data(json.utf8))
    }
}

@MainActor
@Suite(.serialized) struct FeedModelTests {
    func model(_ service: FakeFeedService, kind: FeedKind = .hot, signedIn: Bool = true,
               onSignIn: @escaping () -> Void = {}) async -> FeedModel {
        let m = FeedModel(kind: kind, service: service, isSignedIn: signedIn, requestSignIn: onSignIn,
                          voteDebounce: .milliseconds(50))
        await m.setWidth(390, category: .large)
        return m
    }

    @Test func pagesAppendWithoutDuplicates() async throws {
        let service = FakeFeedService()
        await service.setPage(nil, Page(items: [try makePost(1), try makePost(2)], nextCursor: "c2"))
        // Ranks moved: post 2 shows up again on the next page.
        await service.setPage("c2", Page(items: [try makePost(2), try makePost(3)], nextCursor: nil))
        let m = await model(service)

        await m.load()
        #expect(m.ids == [1, 2] && m.phase == .loaded && m.layouts.count == 2)
        await m.loadMoreIfNeeded(displaying: 1)
        #expect(m.ids == [1, 2, 3])
        #expect(m.layouts[3] != nil)
    }

    @Test func rapidTapsSendOnlyTheFinalState() async throws {
        let service = FakeFeedService()
        await service.setPage(nil, Page(items: [try makePost(1, score: 10)], nextCursor: nil))
        let m = await model(service)
        await m.load()

        m.tapVote(1, direction: 1)
        #expect(m.posts[1]?.myVote == 1 && m.posts[1]?.score == 11) // instant
        m.tapVote(1, direction: -1)
        #expect(m.posts[1]?.myVote == -1 && m.posts[1]?.score == 9)
        m.tapVote(1, direction: -1) // tapping the active arrow clears
        #expect(m.posts[1]?.myVote == 0 && m.posts[1]?.score == 10)
        m.tapVote(1, direction: 1)

        try await Task.sleep(for: .milliseconds(300))
        let sent = await service.votes
        #expect(sent.count == 1 && sent[0] == (1, 1))
        // Reconciled with the server's count, which includes other voters.
        #expect(m.posts[1]?.myVote == 1 && m.posts[1]?.score == 42)
    }

    @Test func failedVoteRollsBack() async throws {
        let service = FakeFeedService()
        await service.setPage(nil, Page(items: [try makePost(1, score: 10, myVote: -1)], nextCursor: nil))
        await service.failVotes(with: .transport(.timedOut))
        let m = await model(service)
        await m.load()

        m.tapVote(1, direction: 1)
        #expect(m.posts[1]?.myVote == 1 && m.posts[1]?.score == 12)
        try await Task.sleep(for: .milliseconds(300))
        #expect(m.posts[1]?.myVote == -1 && m.posts[1]?.score == 10)
    }

    @Test func signedOutVoteAsksToSignIn() async throws {
        let service = FakeFeedService()
        await service.setPage(nil, Page(items: [try makePost(1, score: 5)], nextCursor: nil))
        var asked = 0
        let m = await model(service, signedIn: false) { asked += 1 }
        await m.load()

        m.tapVote(1, direction: 1)
        #expect(asked == 1)
        #expect(m.posts[1]?.score == 5 && m.posts[1]?.myVote == 0)
        #expect(await service.votes.isEmpty)
    }

    @Test func subscriptionsNeedAnAccount() async {
        let m = await model(FakeFeedService(), kind: .subscriptions, signedIn: false)
        await m.load()
        #expect(m.phase == .signInRequired && m.ids.isEmpty)
    }

    @Test func refreshKeepsAVoteStillInFlight() async throws {
        let service = FakeFeedService()
        await service.setPage(nil, Page(items: [try makePost(1, score: 10)], nextCursor: nil))
        let m = await model(service)
        await m.load()

        m.tapVote(1, direction: 1)
        await m.load() // the server does not know the vote yet
        #expect(m.posts[1]?.myVote == 1 && m.posts[1]?.score == 11)
    }

    @Test func failedFirstLoadShowsError() async {
        let m = await model(FakeFeedService())
        await m.load()
        #expect(m.phase == .failed(.transport(.notConnectedToInternet)))
    }
}
