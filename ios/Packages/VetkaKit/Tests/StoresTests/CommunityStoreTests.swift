import Core
import Foundation
import Networking
import Testing
@testable import Stores

func makeCommunity(_ slug: String = "kotiki", subscribers: Int = 10, subscribed: Bool = false,
                   rules: String? = nil) throws -> Community {
    let json = """
    {"id": 1, "slug": "\(slug)", "title": "Котики", "description": "", "is_nsfw": false,
     "subscribers_count": \(subscribers), "created_at": "2026-10-01T12:00:00Z",
     "is_subscribed": \(subscribed), "viewer_role": null\(rules.map { #", "rules": \#($0)"# } ?? "")}
    """
    return try JSON.decoder().decode(Community.self, from: Data(json.utf8))
}

actor SubscriptionRecorder {
    var sent: [(String, Bool)] = []
    var error: APIError?
    var serverCount = 100

    func fail(with error: APIError?) { self.error = error }

    func send(_ slug: String, _ subscribed: Bool) throws(APIError) -> Community {
        sent.append((slug, subscribed))
        if let error { throw error }
        return try! makeCommunity(slug, subscribers: serverCount, subscribed: subscribed)
    }
}

@MainActor
@Suite(.serialized) struct CommunityStoreTests {
    func store(_ recorder: SubscriptionRecorder, signedIn: Bool = true) -> CommunityStore {
        let s = CommunityStore(debounce: .milliseconds(50)) { slug throws(APIError) in
            try! makeCommunity(slug)
        } send: { slug, subscribed throws(APIError) in
            try await recorder.send(slug, subscribed)
        }
        s.isSignedIn = { signedIn }
        return s
    }

    @Test func rulesDecodeOnlyWhenSent() throws {
        #expect(try makeCommunity().rules == nil)
        let rules = try makeCommunity(rules: #"[{"title": "Без спама", "body": ""}]"#).rules
        #expect(rules == [CommunityRule(title: "Без спама", body: "")])
    }

    @Test func subscribingIsInstantAndReconciles() async throws {
        let recorder = SubscriptionRecorder()
        let s = store(recorder)
        s.merge([try makeCommunity(subscribers: 10)])

        s.toggleSubscription("Kotiki") // slugs are case-insensitive
        #expect(s["kotiki"]?.isSubscribed == true && s["kotiki"]?.subscribersCount == 11)

        try await Task.sleep(for: .milliseconds(200))
        let sent = await recorder.sent
        #expect(sent.count == 1 && sent[0] == ("kotiki", true))
        #expect(s["kotiki"]?.subscribersCount == 100) // the server's count
    }

    @Test func aDoubleTapSendsNothing() async throws {
        let recorder = SubscriptionRecorder()
        let s = store(recorder)
        s.merge([try makeCommunity(subscribers: 10)])

        s.toggleSubscription("kotiki")
        s.toggleSubscription("kotiki")
        #expect(s["kotiki"]?.isSubscribed == false && s["kotiki"]?.subscribersCount == 10)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await recorder.sent.isEmpty)
    }

    @Test func failureRollsBack() async throws {
        let recorder = SubscriptionRecorder()
        await recorder.fail(with: .transport(.timedOut))
        let s = store(recorder)
        s.merge([try makeCommunity(subscribers: 10, subscribed: true)])

        s.toggleSubscription("kotiki")
        #expect(s["kotiki"]?.isSubscribed == false && s["kotiki"]?.subscribersCount == 9)
        try await Task.sleep(for: .milliseconds(200))
        #expect(s["kotiki"]?.isSubscribed == true && s["kotiki"]?.subscribersCount == 10)
    }

    @Test func signedOutAsksToSignIn() throws {
        let s = store(SubscriptionRecorder(), signedIn: false)
        var asked = 0
        s.requestSignIn = { asked += 1 }
        s.merge([try makeCommunity()])
        s.toggleSubscription("kotiki")
        #expect(asked == 1 && s["kotiki"]?.isSubscribed == false)
    }

    @Test func aListEntryKeepsLoadedRulesAndAPendingTap() async throws {
        let s = store(SubscriptionRecorder())
        s.merge([try makeCommunity(rules: #"[{"title": "Без спама", "body": ""}]"#)])
        s.toggleSubscription("kotiki")
        s.merge([try makeCommunity(subscribers: 50)]) // a list page arrives meanwhile
        #expect(s["kotiki"]?.rules?.count == 1)
        #expect(s["kotiki"]?.isSubscribed == true && s["kotiki"]?.subscribersCount == 11)
    }
}
