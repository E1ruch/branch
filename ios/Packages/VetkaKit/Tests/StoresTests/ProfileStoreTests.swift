import Core
import Foundation
import Networking
import Testing
@testable import Stores

func makeProfile(_ username: String = "ivan", followers: Int = 10, following: Int = 0,
                 isFollowing: Bool = false) throws -> Profile {
    let json = """
    {"id": 1, "username": "\(username)", "display_name": null, "bio": null, "post_karma": 3,
     "comment_karma": 4, "created_at": "2026-10-01T12:00:00Z", "posts_count": 2,
     "followers_count": \(followers), "following_count": \(following), "is_following": \(isFollowing)}
    """
    return try JSON.decoder().decode(Profile.self, from: Data(json.utf8))
}

actor FollowRecorder {
    var sent: [(String, Bool)] = []
    var error: APIError?
    var serverCount = 100

    func fail(with error: APIError?) { self.error = error }

    func send(_ username: String, _ following: Bool) throws(APIError) -> Profile {
        sent.append((username, following))
        if let error { throw error }
        return try! makeProfile(username, followers: serverCount, isFollowing: following)
    }
}

@MainActor
@Suite(.serialized) struct ProfileStoreTests {
    func store(_ recorder: FollowRecorder, me: String? = "me") -> ProfileStore {
        let s = ProfileStore(debounce: .milliseconds(50)) { username throws(APIError) in
            try! makeProfile(username)
        } send: { username, following throws(APIError) in
            try await recorder.send(username, following)
        }
        s.isSignedIn = { me != nil }
        s.myUsername = { me }
        return s
    }

    @Test func followingIsInstantAndReconciles() async throws {
        let recorder = FollowRecorder()
        let s = store(recorder)
        s.merge([try makeProfile(followers: 10), try makeProfile("me", following: 5)])

        s.toggleFollow("IVAN") // usernames are case-insensitive
        #expect(s["ivan"]?.isFollowing == true && s["ivan"]?.followersCount == 11)
        #expect(s["me"]?.followingCount == 6)

        try await Task.sleep(for: .milliseconds(200))
        let sent = await recorder.sent
        #expect(sent.count == 1 && sent[0] == ("ivan", true))
        #expect(s["ivan"]?.followersCount == 100) // the server's count
        #expect(s["ivan"]?.karma == 7)
    }

    @Test func doubleTapSendsNothing() async throws {
        let recorder = FollowRecorder()
        let s = store(recorder)
        s.merge([try makeProfile(followers: 10), try makeProfile("me", following: 5)])

        s.toggleFollow("ivan")
        s.toggleFollow("ivan")
        try await Task.sleep(for: .milliseconds(200))
        #expect(await recorder.sent.isEmpty)
        #expect(s["ivan"]?.followersCount == 10 && s["ivan"]?.isFollowing == false)
        #expect(s["me"]?.followingCount == 5)
    }

    @Test func errorRollsBack() async throws {
        let recorder = FollowRecorder()
        await recorder.fail(with: .transport(.notConnectedToInternet))
        let s = store(recorder)
        s.merge([try makeProfile(followers: 10), try makeProfile("me", following: 5)])

        s.toggleFollow("ivan")
        try await Task.sleep(for: .milliseconds(200))
        #expect(s["ivan"]?.isFollowing == false && s["ivan"]?.followersCount == 10)
        #expect(s["me"]?.followingCount == 5)
    }

    @Test func cannotFollowYourselfOrSignedOut() async throws {
        let recorder = FollowRecorder()
        var asked = false
        let s = store(recorder, me: nil)
        s.requestSignIn = { asked = true }
        s.merge([try makeProfile()])
        s.toggleFollow("ivan")
        #expect(asked && s["ivan"]?.isFollowing == false)

        let mine = store(recorder)
        mine.merge([try makeProfile("me")])
        mine.toggleFollow("me")
        #expect(mine["me"]?.isFollowing == false)
    }
}
