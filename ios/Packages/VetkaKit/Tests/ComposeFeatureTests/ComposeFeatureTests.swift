import Core
import Foundation
import Networking
import Testing
@testable import ComposeFeature

final class MemoryDraftStorage: DraftStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Draft?

    init(_ draft: Draft? = nil) { stored = draft }

    var draft: Draft? { lock.withLock { stored } }
    func load() -> Draft? { lock.withLock { stored } }
    func save(_ draft: Draft) { lock.withLock { stored = draft } }
    func clear() { lock.withLock { stored = nil } }
}

func community(_ slug: String, id: Int64 = 1, nsfw: Bool = false) -> Community {
    let json = """
    {"id": \(id), "slug": "\(slug)", "title": "\(slug.capitalized)", "description": "", "is_nsfw": \(nsfw),
     "subscribers_count": 10, "created_at": "2026-10-01T12:00:00Z", "is_subscribed": true, "viewer_role": null}
    """
    return try! JSON.decoder().decode(Community.self, from: Data(json.utf8))
}

actor FakeComposeService: ComposeService {
    var published: [(slug: String, title: String, body: String, nsfw: Bool, continues: Int64?)] = []
    var publishError: APIError?
    var mine: [Community] = []
    var top: [Community] = []

    func fail(with error: APIError?) { publishError = error }
    func set(mine: [Community], top: [Community]) { self.mine = mine; self.top = top }

    func subscriptions() async throws(APIError) -> [Community] { mine }
    func popular() async throws(APIError) -> [Community] { top }
    func search(_ query: String) async throws(APIError) -> [Community] { top.filter { $0.slug.contains(query) } }

    func myPosts() async throws(APIError) -> [Post] { [] }

    func publish(community slug: String, title: String, body: String, isNSFW: Bool,
                 continues: Int64?) async throws(APIError) -> Post {
        published.append((slug, title, body, isNSFW, continues))
        if let publishError { throw publishError }
        let json = """
        {"id": 77, "title": "\(title)", "body": "\(body)", "body_truncated": false, "is_nsfw": \(isNSFW),
         "score": 0, "comment_count": 0, "my_vote": 0, "created_at": "2026-10-01T12:00:00Z", "edited_at": null,
         "community": {"id": 1, "slug": "\(slug)", "title": "T"},
         "author": {"id": 2, "username": "me", "display_name": null}, "story": null}
        """
        return try! JSON.decoder().decode(Post.self, from: Data(json.utf8))
    }
}

func myPost(_ id: Int64, parts: Int?) -> Post {
    let story = parts.map { #"{"id": 5, "part": \#($0), "parts": \#($0)}"# } ?? "null"
    let json = """
    {"id": \(id), "title": "Ремонт Нивы", "body": "", "body_truncated": false, "is_nsfw": false,
     "score": 0, "comment_count": 0, "my_vote": 0, "created_at": "2026-10-01T12:00:00Z", "edited_at": null,
     "community": {"id": 3, "slug": "avto", "title": "Авто"},
     "author": {"id": 2, "username": "me", "display_name": null}, "story": \(story)}
    """
    return try! JSON.decoder().decode(Post.self, from: Data(json.utf8))
}

@MainActor
@Suite(.serialized) struct ComposeModelTests {
    let kotiki = PickedCommunity(slug: "kotiki", title: "Котики", isNSFW: false)

    func model(_ service: FakeComposeService = FakeComposeService(), storage: MemoryDraftStorage = MemoryDraftStorage(),
               community: PickedCommunity? = nil, continues: ContinuedPost? = nil) -> ComposeModel {
        ComposeModel(service: service, storage: storage, community: community, continues: continues,
                     saveDelay: .milliseconds(10))
    }

    @Test func publishingNeedsACommunityAndATitle() {
        let m = model()
        #expect(!m.canPublish && m.missing == "Выберите сообщество")
        m.draft.community = kotiki
        m.draft.title = "   "
        #expect(!m.canPublish && m.missing == "Напишите заголовок")
        m.draft.title = "Привет"
        #expect(m.canPublish && m.missing == nil)
        m.draft.title = String(repeating: "я", count: ComposeModel.maxTitle + 1)
        #expect(!m.canPublish && m.titleRemaining == -1)
    }

    @Test func publishSendsTrimmedTextAndClearsTheDraft() async {
        let service = FakeComposeService()
        let storage = MemoryDraftStorage()
        let m = model(service, storage: storage, community: kotiki)
        m.draft.title = "  Мой первый пост "
        m.draft.body = "\nТекст\n"
        m.saveNow()
        #expect(storage.draft?.title == "  Мой первый пост ")

        let post = await m.publish()
        #expect(post?.id == 77)
        let sent = await service.published
        #expect(sent.count == 1 && sent[0].slug == "kotiki" && sent[0].title == "Мой первый пост" && sent[0].body == "Текст")
        #expect(storage.draft == nil)
        m.saveNow() // the sheet closing after a publish
        #expect(storage.draft == nil)
    }

    @Test func aFailedPublishKeepsTheTextAndSaysWhy() async {
        let service = FakeComposeService()
        await service.fail(with: .server(status: 429, code: "rate_limited", message: "", field: nil))
        let storage = MemoryDraftStorage()
        let m = model(service, storage: storage, community: kotiki)
        m.draft.title = "Пост"

        #expect(await m.publish() == nil)
        #expect(m.error?.contains("10 постов в час") == true)
        #expect(m.draft.title == "Пост" && !m.isPublishing)
        m.draft.title = "Пост!" // editing clears the message
        #expect(m.error == nil)
    }

    @Test func aRejectedFieldGetsTheFocus() async {
        let service = FakeComposeService()
        await service.fail(with: .server(status: 422, code: "validation_failed", message: "", field: "body"))
        let m = model(service, community: kotiki)
        m.draft.title = "Пост"
        _ = await m.publish()
        #expect(m.errorField == .body)
    }

    @Test func theDraftComesBackAndSavesItself() async throws {
        var saved = Draft()
        saved.title = "Недописанное"
        saved.community = kotiki
        let storage = MemoryDraftStorage(saved)
        let m = model(storage: storage)
        #expect(m.draft.title == "Недописанное" && m.draft.community == kotiki)

        m.draft.body = "ещё текст"
        try await Task.sleep(for: .milliseconds(100))
        #expect(storage.draft?.body == "ещё текст")

        m.discard()
        try await Task.sleep(for: .milliseconds(50))
        #expect(storage.draft == nil && !m.hasContent)
    }

    @Test func aCommunityPassedInWinsOverTheDraftsOne() {
        var saved = Draft()
        saved.community = PickedCommunity(slug: "auto", title: "Авто", isNSFW: false)
        let m = model(storage: MemoryDraftStorage(saved), community: kotiki)
        #expect(m.draft.community == kotiki)
    }

    @Test func anNSFWCommunityMakesThePostNSFW() async {
        let service = FakeComposeService()
        let m = model(service, community: PickedCommunity(slug: "adult", title: "18+", isNSFW: true))
        m.draft.title = "Пост"
        #expect(m.nsfwIsForced && m.isNSFW && !m.draft.isNSFW)
        _ = await m.publish()
        #expect(await service.published.first?.nsfw == true)
    }

    @Test func continuingAStorySendsItsPostAndPicksItsCommunity() async {
        let service = FakeComposeService()
        let m = model(service)
        m.continueStory(of: myPost(10, parts: 3))
        #expect(m.draft.continues == ContinuedPost(postID: 10, title: "Ремонт Нивы", nextPart: 4))
        #expect(m.draft.community?.slug == "avto")

        m.continueStory(of: myPost(11, parts: nil)) // a lone post starts a story
        #expect(m.draft.continues?.nextPart == 2)
        m.draft.title = "Часть два"
        _ = await m.publish()
        #expect(await service.published.first?.continues == 11)
    }

    @Test func aStoryPassedInWinsOverTheDraftsOne() {
        var saved = Draft()
        saved.continues = ContinuedPost(postID: 1, title: "старое", nextPart: 2)
        let m = model(storage: MemoryDraftStorage(saved), continues: ContinuedPost(myPost(10, parts: 2)))
        #expect(m.draft.continues?.postID == 10 && m.draft.continues?.nextPart == 3)
    }

    @Test func pickerListsSubscriptionsThenOtherPopularOnes() async {
        let service = FakeComposeService()
        await service.set(mine: [community("kotiki", id: 1)],
                          top: [community("kotiki", id: 1), community("auto", id: 2)])
        let picker = CommunityPickerModel(service: service)
        await picker.load()
        #expect(picker.subscriptions.map(\.slug) == ["kotiki"])
        #expect(picker.others.map(\.slug) == ["auto"])
        #expect(!picker.isLoading && !picker.failed)
    }
}
