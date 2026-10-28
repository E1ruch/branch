import Core
import Foundation
import Networking
import Testing
@testable import Stores

func makePost(_ id: Int64, body: String = "", truncated: Bool = false, score: Int = 0, myVote: Int = 0,
              comments: Int = 0, edited: String? = nil) throws -> Post {
    let json = """
    {"id": \(id), "title": "Заголовок", "body": "\(body)", "body_truncated": \(truncated), "is_nsfw": false,
     "score": \(score), "comment_count": \(comments), "my_vote": \(myVote),
     "created_at": "2026-10-01T12:00:00Z", "edited_at": \(edited.map { "\"\($0)\"" } ?? "null"),
     "community": {"id": 1, "slug": "kotiki", "title": "Котики"},
     "author": {"id": 2, "username": "ivan", "display_name": null}}
    """
    return try JSON.decoder().decode(Post.self, from: Data(json.utf8))
}

actor VoteRecorder {
    var sent: [(Int64, Int)] = []
    var error: APIError?
    var serverScore = 42

    func fail(with error: APIError?) { self.error = error }

    func vote(_ id: Int64, _ value: Int) throws(APIError) -> VoteResult {
        sent.append((id, value))
        if let error { throw error }
        let json = #"{"my_vote": \#(value), "score": \#(serverScore)}"#
        return try! JSON.decoder().decode(VoteResult.self, from: Data(json.utf8))
    }
}

@MainActor
@Suite(.serialized) struct PostStoreTests {
    func store(_ recorder: VoteRecorder) -> PostStore {
        PostStore(voteDebounce: .milliseconds(50)) { id, value throws(APIError) in
            try await recorder.vote(id, value)
        }
    }

    @Test func aFeedPreviewDoesNotReplaceTheFullBody() throws {
        let s = store(VoteRecorder())
        s.merge([try makePost(1, body: "целиком", truncated: false)])
        s.merge([try makePost(1, body: "цел", truncated: true, score: 5)])
        #expect(s[1]?.body == "целиком" && s[1]?.bodyTruncated == false)
        #expect(s[1]?.score == 5) // counters still come from the newer copy

        // An edit is new text: take it, even as a preview.
        s.merge([try makePost(1, body: "нов", truncated: true, edited: "2026-10-02T12:00:00Z")])
        #expect(s[1]?.body == "нов")
    }

    @Test func observersHearOnlyAboutChangedPosts() throws {
        let s = store(VoteRecorder())
        var heard: [[Int64]] = []
        let owner = NSObject()
        s.observe(owner) { heard.append($0) }
        s.merge([try makePost(1), try makePost(2)]) // new posts: nobody shows them yet
        s.merge([try makePost(1), try makePost(2, score: 3)])
        s.commentAdded(to: 1)
        #expect(heard == [[2], [1]])
        #expect(s[1]?.commentCount == 1)
    }

    @Test func rapidTapsSendOnlyTheFinalState() async throws {
        let recorder = VoteRecorder()
        let s = store(recorder)
        s.merge([try makePost(1, score: 10)])

        s.vote(1, direction: 1)
        #expect(s[1]?.myVote == 1 && s[1]?.score == 11)
        s.vote(1, direction: -1)
        s.vote(1, direction: -1) // tapping the active arrow clears
        #expect(s[1]?.myVote == 0 && s[1]?.score == 10)
        s.vote(1, direction: 1)

        try await Task.sleep(for: .milliseconds(300))
        let sent = await recorder.sent
        #expect(sent.count == 1 && sent[0] == (1, 1))
        #expect(s[1]?.myVote == 1 && s[1]?.score == 42)
    }

    @Test func failedVoteRollsBackAndAsksToSignInWhenNeeded() async throws {
        let recorder = VoteRecorder()
        await recorder.fail(with: .unauthorized)
        let s = store(recorder)
        var asked = 0
        s.requestSignIn = { asked += 1 }
        s.merge([try makePost(1, score: 10, myVote: -1)])

        s.vote(1, direction: 1)
        #expect(s[1]?.myVote == 1 && s[1]?.score == 12)
        try await Task.sleep(for: .milliseconds(300))
        #expect(s[1]?.myVote == -1 && s[1]?.score == 10)
        #expect(asked == 1)
    }

    @Test func aReloadKeepsAVoteStillInFlight() throws {
        let s = store(VoteRecorder())
        s.merge([try makePost(1, score: 10)])
        s.vote(1, direction: 1)
        s.merge([try makePost(1, score: 10, comments: 4)]) // the server does not know the vote yet
        #expect(s[1]?.myVote == 1 && s[1]?.score == 11 && s[1]?.commentCount == 4)
    }
}
