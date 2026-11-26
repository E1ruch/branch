import Core
import Foundation
import Networking
import Testing
@testable import ComposeFeature

final class MemoryDraftStorage: DraftStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored = DraftLibrary()

    init(_ draft: Draft? = nil) {
        if let draft { stored.saved = [SavedDraft(id: UUID(), draft: draft)] }
    }

    var draft: Draft? { lock.withLock { stored.recovery?.draft } }
    func load() -> DraftLibrary { lock.withLock { stored } }
    func save(_ library: DraftLibrary) { lock.withLock { stored = library } }
}

func community(_ slug: String, id: Int64 = 1, nsfw: Bool = false) -> Community {
    let json = """
    {"id": \(id), "slug": "\(slug)", "title": "\(slug.capitalized)", "description": "", "is_nsfw": \(nsfw),
     "subscribers_count": 10, "created_at": "2026-10-01T12:00:00Z", "is_subscribed": true, "viewer_role": null}
    """
    return try! JSON.decoder().decode(Community.self, from: Data(json.utf8))
}

actor FakeComposeService: ComposeService {
    var published: [(slug: String, title: String, body: String, nsfw: Bool, continues: Int64?, mediaIDs: [Int64])] = []
    var uploaded: [Data] = []
    var publishError: APIError?
    var expiredUploads: Set<Int64> = []
    var recentPosts: [Post] = []
    var mine: [Community] = []
    var top: [Community] = []

    func fail(with error: APIError?) { publishError = error }
    func expire(_ id: Int64) { expiredUploads.insert(id) }
    func remember(_ post: Post) { recentPosts.append(post) }
    func set(mine: [Community], top: [Community]) { self.mine = mine; self.top = top }

    func subscriptions() async throws(APIError) -> [Community] { mine }
    func popular() async throws(APIError) -> [Community] { top }
    func search(_ query: String) async throws(APIError) -> [Community] { top.filter { $0.slug.contains(query) } }

    func myPosts() async throws(APIError) -> [Post] { recentPosts }

    func photoIsAvailable(_ id: Int64) async throws(APIError) -> Bool { !expiredUploads.contains(id) }

    func uploadPhoto(_ jpeg: Data) async throws(APIError) -> Int64 {
        uploaded.append(jpeg)
        return 100 + Int64(uploaded.count)
    }

    func publish(community slug: String, title: String, body: String, isNSFW: Bool,
                 continues: Int64?, mediaIDs: [Int64]) async throws(APIError) -> Post {
        published.append((slug, title, body, isNSFW, continues, mediaIDs))
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

func myPost(_ id: Int64, parts: Int?, mediaIDs: [Int64] = []) -> Post {
    let story = parts.map { #"{"id": 5, "part": \#($0), "parts": \#($0)}"# } ?? "null"
    let media = mediaIDs.map { #"{"id": \#($0), "width": 100, "height": 100, "thumbhash": "AA==", "urls": {}}"# }
        .joined(separator: ",")
    let json = """
    {"id": \(id), "title": "Ремонт Нивы", "body": "", "body_truncated": false, "is_nsfw": false,
     "score": 0, "comment_count": 0, "my_vote": 0, "created_at": "2026-10-01T12:00:00Z", "edited_at": null,
     "community": {"id": 3, "slug": "avto", "title": "Авто"},
     "author": {"id": 2, "username": "me", "display_name": null}, "story": \(story), "media": [\(media)]}
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

    @Test func publishingNeedsContentAndACommunity() {
        let m = model()
        #expect(!m.isReadyExceptCommunity && m.missing == "Добавьте текст, заголовок или фото")
        m.draft.body = "Текст"
        #expect(m.isReadyExceptCommunity && !m.canPublish && m.missing == "Выберите сообщество")
        m.draft.community = kotiki
        #expect(m.canPublish && m.missing == nil)
        m.draft.body = "   "
        #expect(!m.canPublish)
        m.draft.title = "Привет"
        #expect(m.canPublish && m.missing == nil)
        m.draft.title = String(repeating: "я", count: ComposeModel.maxTitle + 1)
        #expect(!m.canPublish && m.titleRemaining == -1)
    }

    @Test func publishesTextOrPhotosWithAnEmptyTitle() async throws {
        let service = FakeComposeService()
        let text = model(service, community: kotiki)
        text.draft.title = "   "
        text.draft.body = "Текст без заголовка"
        #expect(await text.publish()?.title == "")

        let photo = try await DraftPhotoFiles.shared.save(Data([1]))
        defer { Task { await DraftPhotoFiles.shared.remove([photo]) } }
        let photos = model(service, community: kotiki)
        photos.draft.photos = [photo]
        #expect(await photos.publish()?.title == "")
        let sent = await service.published
        #expect(sent.map(\.title) == ["", ""])
        #expect(sent.map(\.body) == ["Текст без заголовка", ""])
        #expect(sent.map(\.mediaIDs) == [[], [101]])
    }

    @Test func publishSendsTrimmedTextAndClearsTheDraft() async {
        let service = FakeComposeService()
        var otherDraft = Draft()
        otherDraft.title = "Другой пост"
        let storage = MemoryDraftStorage(otherDraft)
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
        #expect(storage.load().saved.map(\.draft.title) == ["Другой пост"])
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

    @Test func retryingADraftReusesUploadedPhotosAndKeepsTheirOrder() async throws {
        let service = FakeComposeService()
        let storage = MemoryDraftStorage()
        let first = try await DraftPhotoFiles.shared.save(Data([1]))
        let second = try await DraftPhotoFiles.shared.save(Data([2]))
        defer { Task { await DraftPhotoFiles.shared.remove([first, second]) } }
        let m = model(service, storage: storage, community: kotiki)
        m.draft.title = "Фото"
        m.draft.photos = [first, second]
        await service.fail(with: .transport(.timedOut))
        #expect(await m.publish() == nil)
        #expect(storage.draft?.photos.compactMap(\.mediaID) == [101, 102])

        let restored = model(service, storage: storage)
        let saved = try #require(restored.savedDrafts.first)
        restored.openSavedDraft(saved.id)
        await service.fail(with: nil)
        #expect(await restored.publish()?.id == 77)
        #expect(await service.uploaded == [Data([1]), Data([2])])
        #expect(await service.published.map(\.mediaIDs) == [[101, 102], [101, 102]])
        #expect(storage.draft == nil && restored.savedDrafts.isEmpty)
    }

    @Test func anExpiredUploadCanBeRetriedFromTheLocalDraft() async throws {
        let service = FakeComposeService()
        let storage = MemoryDraftStorage()
        var photo = try await DraftPhotoFiles.shared.save(Data([1]))
        photo.mediaID = 30
        defer { Task { [photo] in await DraftPhotoFiles.shared.remove([photo]) } }
        let m = model(service, storage: storage, community: kotiki)
        m.draft.title = "Фото"
        m.draft.photos = [photo]
        await service.expire(30)
        await service.fail(with: .server(status: 422, code: "validation_failed", message: "", field: "media_ids"))

        #expect(await m.publish() == nil)
        #expect(storage.draft?.photos.first?.mediaID == nil)
        #expect(storage.draft?.photos.first?.id == photo.id)
        await service.fail(with: nil)
        #expect(await m.publish()?.id == 77)
        #expect(await service.uploaded == [Data([1])])
    }

    @Test func retryingAfterALostResponseOpensTheOriginalPost() async throws {
        let service = FakeComposeService()
        let storage = MemoryDraftStorage()
        let own = PickedCommunity(slug: "avto", title: "Авто", isNSFW: false)
        let m = model(service, storage: storage, community: own)
        m.draft.title = "Фото"
        m.draft.photos = [DraftPhoto(mediaID: 30)]
        await service.remember(myPost(44, parts: nil, mediaIDs: [30]))
        await service.fail(with: .server(status: 422, code: "validation_failed", message: "", field: "media_ids"))

        #expect(await m.publish()?.id == 44)
        #expect(await service.uploaded.isEmpty)
        #expect(storage.draft == nil)
    }

    @Test func closingWithSaveLeavesTheNextEditorEmpty() throws {
        let storage = MemoryDraftStorage()
        let editor = model(storage: storage, community: kotiki)
        editor.draft.title = "Первый"
        editor.draft.body = "Текст"
        editor.saveToDraftsAndClose()
        editor.saveNow()

        let next = model(storage: storage)
        #expect(next.draft == Draft())
        let saved = try #require(next.savedDrafts.first)
        next.openSavedDraft(saved.id)
        #expect(next.draft.title == "Первый" && next.draft.body == "Текст" && next.draft.community == kotiki)
        next.draft.title = "Исправленный"
        next.saveToDraftsAndClose()

        let reopened = model(storage: storage)
        #expect(reopened.draft == Draft())
        #expect(reopened.savedDrafts.map(\.id) == [saved.id])
        #expect(reopened.savedDrafts.map(\.draft.title) == ["Исправленный"])
    }

    @Test func autosaveIsRecoveredThroughDraftsAndDiscardKeepsTheSavedVersion() async throws {
        var saved = Draft()
        saved.title = "Недописанное"
        saved.community = kotiki
        let storage = MemoryDraftStorage(saved)
        let m = model(storage: storage)
        #expect(m.draft == Draft())
        let original = try #require(m.savedDrafts.first)
        m.openSavedDraft(original.id)

        m.draft.body = "ещё текст"
        try await Task.sleep(for: .milliseconds(100))
        #expect(storage.draft?.body == "ещё текст")

        let afterInterruption = model(storage: storage)
        #expect(afterInterruption.draft == Draft())
        #expect(afterInterruption.savedDrafts.map(\.id) == [original.id])
        #expect(afterInterruption.savedDrafts.first?.draft.body == "ещё текст")
        m.discard()
        try await Task.sleep(for: .milliseconds(50))
        #expect(storage.draft == nil && !m.hasContent)
        #expect(m.savedDrafts.first?.draft == saved)
    }

    @Test func savingAnotherPostAndDeletingOneDraftLeavesTheOtherDraft() throws {
        let storage = MemoryDraftStorage()
        let first = model(storage: storage)
        first.draft.title = "Первый"
        first.saveToDraftsAndClose()

        let second = model(storage: storage)
        second.draft.title = "Второй"
        second.saveToDraftsAndClose()

        let drafts = model(storage: storage)
        #expect(drafts.savedDrafts.map(\.draft.title) == ["Второй", "Первый"])
        let toDelete = try #require(drafts.savedDrafts.first)
        drafts.deleteSavedDraft(toDelete.id)
        #expect(model(storage: storage).savedDrafts.map(\.draft.title) == ["Первый"])
    }

    @Test func theOldSingleDraftIsAvailableInTheListAfterUpdating() throws {
        let defaults = UserDefaults.standard
        let previousUser = defaults.object(forKey: "compose.lastUserID")
        let userID = Int64.random(in: 1...Int64.max)
        let key = "compose.draft.\(userID)"
        defer {
            defaults.removeObject(forKey: key)
            defaults.set(previousUser, forKey: "compose.lastUserID")
        }
        var legacy = Draft()
        legacy.title = "Старый черновик"
        legacy.community = kotiki
        defaults.set(try JSONEncoder().encode(legacy), forKey: key)

        let storage = UserDefaultsDraftStorage(userID: userID)
        let editor = ComposeModel(service: FakeComposeService(), storage: storage)
        #expect(editor.draft == Draft())
        let saved = try #require(editor.savedDrafts.first)
        #expect(saved.draft == legacy)
        editor.openSavedDraft(saved.id)
        editor.saveToDraftsAndClose()
        #expect(storage.load().saved.map(\.id) == [saved.id])
    }

    @Test func removingAnAttachmentAndDiscardingChangesKeepsTheSavedFile() async throws {
        let file = try await DraftPhotoFiles.shared.save(Data([1]))
        defer { Task { await DraftPhotoFiles.shared.remove([file]) } }
        var saved = Draft()
        saved.photos = [file]
        let storage = MemoryDraftStorage(saved)
        let editor = model(storage: storage)
        let original = try #require(editor.savedDrafts.first)
        editor.openSavedDraft(original.id)
        editor.removePhoto(file)
        editor.discard()
        #expect(model(storage: storage).savedDrafts.first?.draft.photos == [file])
        #expect(try await DraftPhotoFiles.shared.read(file) == Data([1]))
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
