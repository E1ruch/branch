import Core
import Foundation
import Networking
import Stores
import Testing
@testable import PostFeature

func post(_ id: Int64, comments: Int = 0, authorID: Int64 = 2, part: Int? = nil, parts: Int = 3) -> Post {
    let story = part.map { #"{"id": 5, "part": \#($0), "parts": \#(parts)}"# } ?? "null"
    let json = """
    {"id": \(id), "title": "Пост", "body": "Текст", "body_truncated": false, "is_nsfw": false,
     "score": 1, "comment_count": \(comments), "my_vote": 0,
     "created_at": "2026-10-01T12:00:00Z", "edited_at": null,
     "community": {"id": 1, "slug": "kotiki", "title": "Котики"},
     "author": {"id": \(authorID), "username": "op", "display_name": null}, "story": \(story)}
    """
    return try! JSON.decoder().decode(Post.self, from: Data(json.utf8))
}

func storyParts(_ ids: [Int64]) -> [StoryPart] {
    let items = ids.enumerated().map { i, id in
        #"{"post_id": \#(id), "title": "Часть \#(i + 1)", "part": \#(i + 1), "created_at": "2026-10-01T12:00:00Z"}"#
    }
    return try! JSON.decoder().decode([StoryPart].self, from: Data("[\(items.joined(separator: ","))]".utf8))
}

/// A comment as the server writes it, for building thread pages.
func comment(_ id: Int64, parent: Int64? = nil, depth: Int = 0, replies: Int = 0, score: Int = 0,
             authorID: Int64 = 3) -> String {
    """
    {"kind": "comment", "comment": {"id": \(id), "post_id": 1, "parent_id": \(parent.map(String.init) ?? "null"),
     "depth": \(depth), "body": "комментарий \(id)", "is_deleted": false,
     "author": {"id": \(authorID), "username": "user\(authorID)", "display_name": null},
     "score": \(score), "my_vote": 0, "reply_count": \(replies),
     "created_at": "2026-10-01T12:00:00Z", "edited_at": null}}
    """
}

func more(_ parent: Int64, depth: Int, count: Int, cursor: String?) -> String {
    #"{"kind": "more", "parent_id": \#(parent), "depth": \#(depth), "count": \#(count)\#(cursor.map { #", "cursor": "\#($0)""# } ?? "")}"#
}

func page(_ items: [String], next: String? = nil) -> Page<ThreadItem> {
    let json = #"{"items": [\#(items.joined(separator: ","))], "next_cursor": \#(next.map { "\"\($0)\"" } ?? "null")}"#
    return try! JSON.decoder().decode(Page<ThreadItem>.self, from: Data(json.utf8))
}

actor FakePostService: PostService {
    var posts: [Int64: Post] = [:]
    var rootComments: [Int64: Core.Comment] = [:]
    var threads: [String?: Page<ThreadItem>] = [:]
    var replyPages: [String: Page<ThreadItem>] = [:]
    var created: [(Int64?, String)] = []
    var createError: APIError?
    var votes: [(Int64, Int)] = []
    var voteError: APIError?
    var nextID: Int64 = 100
    var parts: [StoryPart] = []
    func set(parts: [StoryPart]) { self.parts = parts }
    func storyParts(postID: Int64) async throws(APIError) -> [StoryPart] { parts }

    func set(post: Post) { posts[post.id] = post }
    func set(thread: Page<ThreadItem>, cursor: String? = nil) { threads[cursor] = thread }
    func set(replies: Page<ThreadItem>, to parent: Int64, cursor: String?) { replyPages["\(parent)/\(cursor ?? "")"] = replies }
    func failCreate(with error: APIError?) { createError = error }
    func failVotes(with error: APIError?) { voteError = error }

    func post(_ id: Int64) async throws(APIError) -> Post {
        guard let post = posts[id] else { throw .server(status: 404, code: "not_found", message: "", field: nil) }
        return post
    }

    func comment(_ id: Int64) async throws(APIError) -> Core.Comment {
        guard let comment = rootComments[id] else { throw .server(status: 404, code: "not_found", message: "", field: nil) }
        return comment
    }

    func thread(postID: Int64, sort: API.CommentSort, cursor: String?) async throws(APIError) -> Page<ThreadItem> {
        guard let page = threads[cursor] else { throw .transport(.notConnectedToInternet) }
        return page
    }

    func replies(commentID: Int64, sort: API.CommentSort, cursor: String?) async throws(APIError) -> Page<ThreadItem> {
        guard let page = replyPages["\(commentID)/\(cursor ?? "")"] else { throw .transport(.notConnectedToInternet) }
        return page
    }

    var edits: [(Int64, String)] = []
    var editError: APIError?
    func failEdits(with error: APIError?) { editError = error }

    var deleted: [Int64] = []
    var deleteError: APIError?
    func failDeletes(with error: APIError?) { deleteError = error }

    func deleteComment(_ id: Int64) async throws(APIError) {
        deleted.append(id)
        if let deleteError { throw deleteError }
    }

    func editComment(_ id: Int64, body: String) async throws(APIError) -> Core.Comment {
        edits.append((id, body))
        if let editError { throw editError }
        return Core.Comment(id: id, postId: 1, parentId: nil, depth: 0, body: body, isDeleted: false,
                            author: AuthorRef(id: 9, username: "me", displayName: nil), score: 0, myVote: 0,
                            replyCount: 0, createdAt: Date(), editedAt: Date())
    }

    func createComment(postID: Int64, parentID: Int64?, body: String) async throws(APIError) -> Core.Comment {
        created.append((parentID, body))
        if let createError { throw createError }
        nextID += 1
        return Core.Comment(id: nextID, postId: postID, parentId: parentID, depth: parentID == nil ? 0 : 1, body: body,
                       isDeleted: false, author: AuthorRef(id: 9, username: "me", displayName: nil),
                       score: 1, myVote: 1, replyCount: 0, createdAt: Date(), editedAt: nil)
    }

    func voteComment(_ id: Int64, value: Int) async throws(APIError) -> VoteResult {
        votes.append((id, value))
        if let voteError { throw voteError }
        return try! JSON.decoder().decode(VoteResult.self, from: Data(#"{"my_vote": \#(value), "score": 7}"#.utf8))
    }
}

@MainActor
@Suite(.serialized) struct ThreadModelTests {
    let me = AuthorRef(id: 9, username: "me", displayName: nil)

    func model(_ service: FakePostService, mode: ThreadMode = .post(id: 1), store: PostStore? = nil,
               signedIn: Bool = true, onSignIn: @escaping () -> Void = {}) async -> (ThreadModel, PostStore) {
        let store = store ?? PostStore { _, _ throws(APIError) in throw .unauthorized }
        let m = ThreadModel(mode: mode, service: service, store: store, isSignedIn: signedIn,
                            viewer: signedIn ? me : nil, requestSignIn: onSignIn, voteDebounce: .milliseconds(30))
        await m.setWidth(390, category: .large)
        return (m, store)
    }

    /// Core.Comment 1 with replies 2 and 3 shown and 2 more behind a stub; comment 4.
    func standardThread(_ service: FakePostService) async {
        await service.set(post: post(1, comments: 6))
        await service.set(thread: page([
            comment(1, replies: 4), comment(2, parent: 1, depth: 1, replies: 1), comment(5, parent: 2, depth: 2),
            comment(3, parent: 1, depth: 1), more(1, depth: 1, count: 2, cursor: "after3"),
            comment(4, authorID: 2),
        ]))
    }

    @Test func editIsInstantAndOnlyForYourOwnComments() async throws {
        let service = FakePostService()
        await service.set(post: post(1, comments: 2))
        await service.set(thread: page([comment(1, authorID: 9), comment(2)]))
        let (m, _) = await model(service)
        await m.load()
        let mine = try #require(m.comments[1]), theirs = try #require(m.comments[2])
        #expect(m.canEdit(mine) && !m.canEdit(theirs))

        let before = try #require(m.layouts[1]).height
        m.edit(1, text: "  новый текст, " + String(repeating: "длиннее прежнего ", count: 10))
        #expect(m.comments[1]?.body?.hasPrefix("новый текст") == true && m.comments[1]?.editedAt != nil)
        #expect(try #require(m.layouts[1]).height > before) // measured again
        m.edit(2, text: "чужой") // not mine: nothing
        #expect(m.comments[2]?.body == "комментарий 2")

        try await Task.sleep(for: .milliseconds(50))
        let edits = await service.edits
        #expect(edits.count == 1 && edits[0].0 == 1 && edits[0].1.hasPrefix("новый текст")) // trimmed
    }

    @Test func failedEditRollsBackAndReturnsTheText() async throws {
        let service = FakePostService()
        await service.set(post: post(1, comments: 1))
        await service.set(thread: page([comment(1, authorID: 9)]))
        await service.failEdits(with: .transport(.notConnectedToInternet))
        let (m, _) = await model(service)
        await m.load()
        var returned: (Int64, String)?
        m.onEditFailed = { id, text, _ in returned = (id, text) }

        m.edit(1, text: "правка")
        #expect(m.comments[1]?.body == "правка")
        try await Task.sleep(for: .milliseconds(50))
        #expect(m.comments[1]?.body == "комментарий 1" && m.comments[1]?.editedAt == nil)
        #expect(returned?.0 == 1 && returned?.1 == "правка")
    }

    @Test func deleteLeavesATombstoneAndRollsBackOnError() async throws {
        let service = FakePostService()
        await service.set(post: post(1, comments: 3))
        await service.set(thread: page([comment(1, replies: 1, authorID: 9), comment(2, parent: 1, depth: 1), comment(3)]))
        let (m, _) = await model(service)
        await m.load()
        var failed = false
        m.onDeleteFailed = { _ in failed = true }

        m.delete(3) // someone else's: nothing
        #expect(m.comments[3]?.body == "комментарий 3")
        m.delete(1)
        #expect(m.comments[1]?.isDeleted == true && m.comments[1]?.body == nil && m.comments[1]?.author == nil)
        #expect(m.rows.contains(.comment(2))) // the reply stays
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.deleted == [1] && !failed)

        let other = FakePostService()
        await other.set(post: post(1, comments: 1))
        await other.set(thread: page([comment(1, authorID: 9)]))
        await other.failDeletes(with: .transport(.notConnectedToInternet))
        let (m2, _) = await model(other)
        await m2.load()
        m2.onDeleteFailed = { _ in failed = true }
        m2.delete(1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(failed && m2.comments[1]?.body == "комментарий 1" && m2.comments[1]?.author?.id == 9)
    }

    @Test func loadsThePostAndTheFlatThread() async {
        let service = FakePostService()
        await standardThread(service)
        let (m, store) = await model(service)
        await m.load()

        #expect(store[1]?.title == "Пост" && m.postLayout != nil)
        #expect(m.rows == [.post, .commentsHeader, .comment(1), .comment(2), .comment(5), .comment(3),
                           .more(parentID: 1), .comment(4)])
        #expect(m.layouts[5]?.level == 2)
        #expect(m.layouts[5]!.bodyFrame.minX > m.layouts[2]!.bodyFrame.minX)
        #expect(m.isOP(m.comments[4]!) && !m.isOP(m.comments[1]!))
    }

    @Test func aStubLoadsInPlaceAndLeavesOneForTheRest() async {
        let service = FakePostService()
        await standardThread(service)
        // One of the two arrives, the server has more after it.
        await service.set(replies: page([comment(6, parent: 1, depth: 1)], next: "after6"), to: 1, cursor: "after3")
        let (m, _) = await model(service)
        await m.load()

        await m.expandStub(parentID: 1)
        #expect(m.rows == [.post, .commentsHeader, .comment(1), .comment(2), .comment(5), .comment(3),
                           .comment(6), .more(parentID: 1), .comment(4)])
        #expect(m.stub(for: 1) == .more(parentID: 1, depth: 1, count: 1, cursor: "after6"))
    }

    @Test func foldingHidesTheBranchAndItsStubs() async {
        let service = FakePostService()
        await standardThread(service)
        let (m, _) = await model(service)
        await m.load()

        m.toggleCollapse(1)
        #expect(m.rows == [.post, .commentsHeader, .comment(1), .comment(4)])
        m.toggleCollapse(2) // a fold inside a fold is remembered
        m.toggleCollapse(1)
        #expect(m.rows == [.post, .commentsHeader, .comment(1), .comment(2), .comment(3), .more(parentID: 1), .comment(4)])

        m.reveal(5) // "к родительскому" opens the folds above
        #expect(m.rows.contains(.comment(5)))
    }

    @Test func aReplyShowsAtOnceUnderItsParentThenGetsItsID() async throws {
        let service = FakePostService()
        await standardThread(service)
        let (m, store) = await model(service)
        await m.load()

        let row = m.send("  привет  ", replyTo: 3)
        guard case let .comment(temp) = row else { Issue.record("no row"); return }
        #expect(temp < 0 && m.pending.contains(temp))
        #expect(m.rows[6] == .comment(temp)) // right under comment 3
        #expect(m.comments[temp]?.depth == 2 && m.comments[temp]?.body == "привет")

        try await Task.sleep(for: .milliseconds(100))
        #expect(m.pending.isEmpty && m.rows[6] == .comment(101))
        #expect(m.comments[3]?.replyCount == 1)
        #expect(store[1]?.commentCount == 7)
        let created = await service.created
        #expect(created.count == 1 && created[0].0 == 3 && created[0].1 == "привет")
    }

    @Test func aFailedCommentGoesBackToTheComposer() async throws {
        let service = FakePostService()
        await standardThread(service)
        await service.failCreate(with: .server(status: 429, code: "rate_limited", message: "", field: nil))
        let (m, _) = await model(service)
        await m.load()
        var returned: (String, Int64?)?
        m.onSendFailed = { text, parent, _ in returned = (text, parent) }

        m.send("текст", replyTo: nil)
        #expect(m.rows[2].isPendingComment(in: m))
        try await Task.sleep(for: .milliseconds(100))
        #expect(returned?.0 == "текст" && returned?.1 == nil)
        #expect(m.rows[2] == .comment(1) && m.pending.isEmpty)
    }

    @Test func signedOutCommentsAndVotesAskToSignIn() async {
        let service = FakePostService()
        await standardThread(service)
        var asked = 0
        let (m, _) = await model(service, signedIn: false) { asked += 1 }
        await m.load()

        #expect(m.send("текст", replyTo: nil) == nil)
        m.tapCommentVote(1, direction: 1)
        m.tapPostVote(direction: 1)
        #expect(asked == 3)
        let created = await service.created
        let votes = await service.votes
        #expect(created.isEmpty && votes.isEmpty)
    }

    @Test func commentVotesAreOptimisticAndRollBack() async throws {
        let service = FakePostService()
        await standardThread(service)
        await service.failVotes(with: .transport(.timedOut))
        let (m, _) = await model(service)
        await m.load()

        m.tapCommentVote(1, direction: 1)
        #expect(m.comments[1]?.myVote == 1 && m.comments[1]?.score == 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(m.comments[1]?.myVote == 0 && m.comments[1]?.score == 0)
    }

    @Test func aBranchStartsAtItsRoot() async throws {
        let service = FakePostService()
        await service.set(post: post(1))
        let root = try JSON.decoder().decode(ThreadItem.self, from: Data(comment(50, parent: 40, depth: 5, replies: 1).utf8))
        guard case let .comment(rootComment) = root else { return }
        await service.setRoot(rootComment)
        await service.set(replies: page([comment(51, parent: 50, depth: 6)]), to: 50, cursor: nil)
        let (m, _) = await model(service, mode: .branch(commentID: 50))
        await m.load()

        #expect(m.rows == [.branchHeader, .comment(50), .comment(51)])
        #expect(m.layouts[50]?.level == 0 && m.layouts[51]?.level == 1)
        #expect(m.post?.id == 1) // fetched for the header

        // In a branch, a comment without a chosen parent answers the root.
        m.send("ответ", replyTo: nil)
        try await Task.sleep(for: .milliseconds(100))
        let created = await service.created
        #expect(created.first?.0 == 50)
    }

    @Test func aPartOfAStoryShowsItsNeighbours() async {
        let service = FakePostService()
        await service.set(post: post(1, authorID: 9, part: 2))
        await service.set(thread: page([]))
        await service.set(parts: storyParts([40, 1, 60]))
        let (m, _) = await model(service)
        await m.load()

        #expect(m.rows.prefix(3) == [.post, .story, .commentsHeader])
        #expect(m.neighbourParts.previous?.postId == 40 && m.neighbourParts.next?.postId == 60)
        #expect(m.canContinueStory) // the viewer (id 9) wrote it
    }

    @Test func onlyTheAuthorContinuesAndLonePostsHaveNoStoryRow() async {
        let service = FakePostService()
        await service.set(post: post(1, authorID: 2))
        await service.set(thread: page([]))
        let (m, _) = await model(service)
        await m.load()
        #expect(!m.rows.contains(.story) && !m.canContinueStory)
    }

    @Test func notFoundPostFailsTheScreen() async {
        let (m, _) = await model(FakePostService())
        await m.load()
        #expect(m.postPhase == .failed(.server(status: 404, code: "not_found", message: "", field: nil)))
    }
}

extension FakePostService {
    func setRoot(_ comment: Core.Comment) { rootComments[comment.id] = comment }
}

extension Row {
    @MainActor func isPendingComment(in model: ThreadModel) -> Bool {
        if case let .comment(id) = self { model.pending.contains(id) } else { false }
    }
}
