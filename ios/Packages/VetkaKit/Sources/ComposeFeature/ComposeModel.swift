import Core
import DesignSystem
import Foundation
import Networking
import Observation
import PhotosUI
import SwiftUI

/// What the composer needs from the server. A protocol so publishing and
/// the community picker are tested without a network.
public protocol ComposeService: Sendable {
    func subscriptions() async throws(APIError) -> [Community]
    func popular() async throws(APIError) -> [Community]
    func search(_ query: String) async throws(APIError) -> [Community]
    func uploadPhoto(_ jpeg: Data) async throws(APIError) -> Int64
    func photoIsAvailable(_ id: Int64) async throws(APIError) -> Bool
    func publish(community slug: String, title: String, body: String, isNSFW: Bool,
                 continues: Int64?, mediaIDs: [Int64]) async throws(APIError) -> Post
    /// The user's own recent posts: the ones a new post can continue.
    func myPosts() async throws(APIError) -> [Post]
}

public struct LiveComposeService: ComposeService {
    private let client: APIClient
    private let username: String?

    public init(client: APIClient, username: String?) {
        self.client = client
        self.username = username
    }

    public func subscriptions() async throws(APIError) -> [Community] {
        try await client.send(API.mySubscriptions()).items
    }

    public func popular() async throws(APIError) -> [Community] {
        try await client.send(API.popularCommunities()).items
    }

    public func search(_ query: String) async throws(APIError) -> [Community] {
        try await client.send(API.searchCommunities(query)).items
    }

    public func uploadPhoto(_ jpeg: Data) async throws(APIError) -> Int64 {
        try await MediaUploader(client: client).upload(jpeg).id
    }

    public func photoIsAvailable(_ id: Int64) async throws(APIError) -> Bool {
        do {
            _ = try await MediaUploader(client: client).completed(id)
            return true
        } catch .server(404, "not_found", _, _) {
            return false
        }
    }

    public func publish(community slug: String, title: String, body: String, isNSFW: Bool,
                        continues: Int64?, mediaIDs: [Int64]) async throws(APIError) -> Post {
        try await client.send(API.createPost(community: slug, title: title, body: body, isNSFW: isNSFW,
                                             continues: continues, mediaIDs: mediaIDs))
    }

    public func myPosts() async throws(APIError) -> [Post] {
        guard let username else { throw .unauthorized }
        return try await client.send(API.userPosts(username)).items
    }
}

/// The community a post goes to: just what the composer shows and sends.
public struct PickedCommunity: Codable, Hashable, Sendable {
    public let slug: String
    public let title: String
    public let isNSFW: Bool

    public init(slug: String, title: String, isNSFW: Bool) {
        self.slug = slug
        self.title = title
        self.isNSFW = isNSFW
    }

    init(_ community: Community) {
        self.init(slug: community.slug, title: community.title, isNSFW: community.isNsfw)
    }
}

/// The post a new one continues: the new post becomes part `nextPart`.
public struct ContinuedPost: Codable, Hashable, Sendable {
    public let postID: Int64
    public let title: String
    public let nextPart: Int

    public init(postID: Int64, title: String, nextPart: Int) {
        self.postID = postID
        self.title = title
        self.nextPart = nextPart
    }

    /// Continuing `post` appends after the last part of its story.
    public init(_ post: Post) {
        self.init(postID: post.id, title: post.title, nextPart: (post.story?.parts ?? 1) + 1)
    }
}

/// An unfinished post. Kept on the device so closing the composer, or the
/// app being killed, loses nothing.
public struct Draft: Codable, Equatable, Sendable {
    public var title = ""
    public var body = ""
    public var isNSFW = false
    public var community: PickedCommunity?
    public var continues: ContinuedPost?
    private var photoAttachments: [DraftPhoto]?

    var photos: [DraftPhoto] {
        get { photoAttachments ?? [] }
        set { photoAttachments = newValue.isEmpty ? nil : newValue }
    }

    public init() {}

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && photos.isEmpty
    }
}

struct SavedDraft: Codable, Identifiable, Sendable {
    let id: UUID
    let draft: Draft
}

public struct DraftLibrary: Codable, Sendable {
    var saved: [SavedDraft] = []
    /// A working copy survives an interruption and is offered in the draft list.
    var recovery: SavedDraft?

    public init() {}
}

public protocol DraftStorage: Sendable {
    func load() -> DraftLibrary
    func save(_ library: DraftLibrary)
}

/// Drafts are stored separately for each account.
public struct UserDefaultsDraftStorage: DraftStorage {
    private let key: String
    private static let lastUserKey = "compose.lastUserID"

    /// `userID` nil: the profile has not loaded yet (offline launch). The
    /// draft is then the last known account's, not a shared one.
    public init(userID: Int64?) {
        let defaults = UserDefaults.standard
        if let userID {
            defaults.set(userID, forKey: Self.lastUserKey)
        }
        let id = userID ?? (defaults.object(forKey: Self.lastUserKey) as? Int64) ?? 0
        key = "compose.draft.\(id)"
    }

    public func load() -> DraftLibrary {
        var library = DraftLibrary()
        guard let data = UserDefaults.standard.data(forKey: key) else { return library }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode(DraftLibrary.self, from: data) { return decoded }
        // Older builds kept one draft directly under this key.
        if let draft = try? decoder.decode(Draft.self, from: data), !draft.isEmpty {
            library.saved = [SavedDraft(id: UUID(), draft: draft)]
        }
        return library
    }

    public func save(_ library: DraftLibrary) {
        if library.saved.isEmpty && library.recovery == nil {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(library) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// The composer's state: the draft, what may be published, and publishing.
@MainActor
@Observable
public final class ComposeModel {
    public var draft: Draft {
        didSet {
            if draft != oldValue {
                error = nil
                scheduleSave()
            }
        }
    }
    public private(set) var isPublishing = false
    private(set) var isPreparingPhotos = false
    /// Why the last publish failed, in words for the user.
    public private(set) var error: String?
    /// The field the server rejected, to put the cursor there.
    public private(set) var errorField: Field?

    public enum Field: Hashable { case title, body }

    public static let maxTitle = 300
    public static let maxBody = 40_000
    static let maxPhotos = 4

    private let service: any ComposeService
    private let storage: any DraftStorage
    private let saveDelay: Duration
    private var recoveryID = UUID()
    private var library: DraftLibrary
    private var editingSavedID: UUID?
    private var supersededPhotos: [DraftPhoto] = []
    private var saveTask: Task<Void, Never>?
    private var isFinished = false

    /// The entry point can preselect a community or story for the new post.
    public init(service: any ComposeService, storage: any DraftStorage, community: PickedCommunity? = nil,
                continues: ContinuedPost? = nil, saveDelay: Duration = .milliseconds(400)) {
        self.service = service
        self.storage = storage
        self.saveDelay = saveDelay
        var library = storage.load()
        if let recovery = library.recovery {
            if let index = library.saved.firstIndex(where: { $0.id == recovery.id }) {
                supersededPhotos = library.saved.remove(at: index).draft.photos
            }
            library.saved.insert(recovery, at: 0)
            library.recovery = nil
        }
        self.library = library
        var draft = Draft()
        draft.community = community
        draft.continues = continues
        self.draft = draft
    }

    /// Picked from the user's posts: continue it, in its community unless
    /// another one is already chosen.
    public func continueStory(of post: Post) {
        draft.continues = ContinuedPost(post)
        if draft.community == nil {
            draft.community = PickedCommunity(slug: post.community.slug, title: post.community.title, isNSFW: false)
        }
    }

    // MARK: Validation

    var trimmedTitle: String { draft.title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedBody: String { draft.body.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var hasContent: Bool { !draft.isEmpty }

    /// Characters left, shown only near the limit so it does not nag.
    public var titleRemaining: Int? {
        let left = Self.maxTitle - draft.title.count
        return left <= 50 ? left : nil
    }

    public var bodyRemaining: Int? {
        let left = Self.maxBody - draft.body.count
        return left <= 1000 ? left : nil
    }

    /// An NSFW community makes every post in it NSFW.
    public var nsfwIsForced: Bool { draft.community?.isNSFW == true }

    public var isNSFW: Bool { draft.isNSFW || nsfwIsForced }

    /// Everything but the community is in order: the publish button is
    /// live and, without a community, opens the settings instead.
    public var isReadyExceptCommunity: Bool {
        !isFinished && !isPublishing && !isPreparingPhotos && !trimmedTitle.isEmpty
            && draft.title.count <= Self.maxTitle && draft.body.count <= Self.maxBody
    }

    public var canPublish: Bool {
        isReadyExceptCommunity && draft.community != nil
    }

    /// What is missing, for the button's accessibility hint.
    public var missing: String? {
        if draft.community == nil { return "Выберите сообщество" }
        if trimmedTitle.isEmpty { return "Напишите заголовок" }
        if draft.title.count > Self.maxTitle { return "Заголовок длиннее \(Self.maxTitle) символов" }
        if draft.body.count > Self.maxBody { return "Текст длиннее \(Self.maxBody) символов" }
        return nil
    }

    // MARK: Draft

    var savedDrafts: [SavedDraft] { library.saved }

    private func scheduleSave() {
        saveTask?.cancel()
        guard !isFinished else { return }
        saveTask = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Keep a copy for recovery while editing, including after a failed publish.
    func saveNow(removing removedPhotos: [DraftPhoto] = []) {
        saveTask?.cancel()
        guard !isFinished else { return }
        let previousPhotos = library.recovery?.draft.photos ?? []
        let original = library.saved.first { $0.id == editingSavedID }
        library.recovery = hasContent && draft != original?.draft
            ? SavedDraft(id: editingSavedID ?? recoveryID, draft: draft) : nil
        persist(removing: previousPhotos + removedPhotos)
    }

    func saveToDraftsAndClose() {
        isFinished = true
        archiveDraft()
    }

    private func archiveDraft() {
        saveTask?.cancel()
        var replacedPhotos = library.recovery?.draft.photos ?? []
        if hasContent {
            let id = editingSavedID ?? recoveryID
            if let index = library.saved.firstIndex(where: { $0.id == id }) {
                replacedPhotos += library.saved.remove(at: index).draft.photos
            }
            library.saved.insert(SavedDraft(id: id, draft: draft), at: 0)
        }
        library.recovery = nil
        persist(removing: replacedPhotos)
    }

    func openSavedDraft(_ id: UUID) {
        guard editingSavedID != id, let saved = library.saved.first(where: { $0.id == id }) else { return }
        archiveDraft()
        recoveryID = UUID()
        editingSavedID = id
        draft = saved.draft
    }

    func deleteSavedDraft(_ id: UUID) {
        guard let index = library.saved.firstIndex(where: { $0.id == id }) else { return }
        var removedPhotos = library.saved.remove(at: index).draft.photos
        if editingSavedID == id {
            editingSavedID = nil
            saveTask?.cancel()
            removedPhotos += library.recovery?.draft.photos ?? []
            library.recovery = nil
        }
        persist(removing: removedPhotos)
    }

    public func discard() {
        isFinished = true
        finishEditing(removingSavedDraft: false)
        draft = Draft()
    }

    private func finishEditing(removingSavedDraft: Bool) {
        saveTask?.cancel()
        var removedPhotos = draft.photos + (library.recovery?.draft.photos ?? [])
        library.recovery = nil
        if removingSavedDraft, let index = library.saved.firstIndex(where: { $0.id == editingSavedID }) {
            removedPhotos += library.saved.remove(at: index).draft.photos
        }
        persist(removing: removedPhotos)
    }

    private func persist(removing candidates: [DraftPhoto] = []) {
        storage.save(library)
        let candidates = candidates + supersededPhotos
        supersededPhotos = []
        guard !candidates.isEmpty else { return }
        let savedPhotos = library.saved.flatMap(\.draft.photos) + (library.recovery?.draft.photos ?? [])
        let retained = Set((savedPhotos + (isFinished ? [] : draft.photos)).map(\.id))
        let unused = candidates.filter { !retained.contains($0.id) }
        if !unused.isEmpty {
            Task { await DraftPhotoFiles.shared.remove(unused) }
        }
    }

    // MARK: Photos

    func addPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty, !isPreparingPhotos, !isPublishing else { return }
        isPreparingPhotos = true
        error = nil
        defer { isPreparingPhotos = false }
        var failed = false
        for item in items.prefix(max(0, Self.maxPhotos - draft.photos.count)) {
            do {
                let data = try await item.loadTransferable(type: Data.self)
                let jpeg = try await PhotoPreparation.shared.jpeg(from: data)
                let photo = try await DraftPhotoFiles.shared.save(jpeg)
                guard !Task.isCancelled else {
                    await DraftPhotoFiles.shared.remove([photo])
                    return
                }
                draft.photos.append(photo)
                saveNow()
            } catch {
                if Task.isCancelled { return }
                failed = true
            }
        }
        if failed { error = "Одно или несколько фото не открылись. Выберите их снова." }
    }

    func removePhoto(_ photo: DraftPhoto) {
        guard !isPublishing else { return }
        draft.photos.removeAll { $0.id == photo.id }
        saveNow(removing: [photo])
    }

    // MARK: Publishing

    /// Sends the post. Returns it on success (the draft is gone then); on
    /// failure the text stays and `error` says why.
    public func publish() async -> Post? {
        guard canPublish, let community = draft.community else { return nil }
        isPublishing = true
        error = nil
        errorField = nil
        defer { isPublishing = false }
        let title = trimmedTitle
        let body = trimmedBody
        let isNSFW = self.isNSFW
        let continues = draft.continues?.postID
        var mediaIDs: [Int64] = []
        for (index, photo) in draft.photos.enumerated() {
            if let id = photo.mediaID {
                mediaIDs.append(id)
                continue
            }
            do {
                let jpeg = try await DraftPhotoFiles.shared.read(photo)
                let id = try await service.uploadPhoto(jpeg)
                draft.photos[index].mediaID = id
                mediaIDs.append(id)
                saveNow()
            } catch {
                if Task.isCancelled || (error as? APIError) == .cancelled { return nil }
                self.error = error is APIError
                    ? "Не удалось загрузить фото. Черновик сохранён — попробуйте ещё раз."
                    : "Файл фото не найден. Удалите его из черновика и прикрепите снова."
                Haptics.error()
                return nil
            }
        }
        do {
            let post = try await service.publish(community: community.slug, title: title,
                                                 body: body, isNSFW: isNSFW, continues: continues, mediaIDs: mediaIDs)
            finishPublishing()
            return post
        } catch .server(_, "validation_failed", _, "media_ids") where !mediaIDs.isEmpty {
            return await recoverPhotos(mediaIDs, in: community.slug)
        } catch {
            if error == .cancelled { return nil }
            (self.error, errorField) = Self.describe(error)
            Haptics.error()
            return nil
        }
    }

    private func finishPublishing() {
        isFinished = true
        finishEditing(removingSavedDraft: true)
        Haptics.success()
    }

    /// An expired upload can be repeated from disk. An upload already attached
    /// to a post identifies the original result when its response was lost.
    private func recoverPhotos(_ ids: [Int64], in slug: String) async -> Post? {
        do {
            if let post = try await service.myPosts().first(where: {
                $0.community.slug == slug && $0.media.map(\.id) == ids
            }) {
                finishPublishing()
                return post
            }

            var expired = Set<Int64>()
            for id in ids {
                if try await service.photoIsAvailable(id) == false {
                    expired.insert(id)
                }
            }
            for index in draft.photos.indices {
                if let id = draft.photos[index].mediaID, expired.contains(id) {
                    draft.photos[index].mediaID = nil
                }
            }
            if !expired.isEmpty { saveNow() }
            error = expired.isEmpty
                ? "Фото могли уже попасть в публикацию. Проверьте свои посты. Черновик сохранён."
                : "Загрузка фото устарела. Нажмите «Опубликовать» ещё раз — фото сохранены в черновике."
        } catch {
            if error == .cancelled { return nil }
            self.error = "Не удалось проверить фото. Черновик сохранён — попробуйте ещё раз."
        }
        Haptics.error()
        return nil
    }

    static func describe(_ error: APIError) -> (String, Field?) {
        switch error {
        case let .server(_, "validation_failed", _, field):
            return field == "body"
                ? ("Текст слишком длинный.", .body)
                : ("Заголовок должен быть от 1 до \(maxTitle) символов.", .title)
        case .server(_, "rate_limited", _, _):
            return ("Не больше 10 постов в час. Черновик сохранён — опубликуйте позже.", nil)
        case .server(_, "not_found", _, _):
            return ("Сообщество не найдено. Выберите другое.", nil)
        case .server(_, "story_not_found", _, _):
            return ("Пост, который вы продолжаете, удалён. Уберите продолжение или выберите другой.", nil)
        case .server(_, "not_story_author", _, _):
            return ("Продолжать можно только свои истории.", nil)
        case .unauthorized:
            return ("Сессия закончилась. Войдите снова — черновик сохранён.", nil)
        case .transport:
            return ("Нет соединения. Черновик сохранён — попробуйте ещё раз.", nil)
        default:
            return ("Не удалось опубликовать. Попробуйте ещё раз.", nil)
        }
    }
}

/// Communities to post to: subscriptions first, then popular ones, or
/// search results while typing.
@MainActor
@Observable
public final class CommunityPickerModel {
    public private(set) var subscriptions: [Community] = []
    public private(set) var popular: [Community] = []
    public private(set) var results: [Community]?
    public private(set) var isLoading = true
    public private(set) var failed = false
    public var query = ""

    private let service: any ComposeService

    public init(service: any ComposeService) {
        self.service = service
    }

    /// Popular ones the user is not subscribed to: no community twice.
    public var others: [Community] {
        let mine = Set(subscriptions.map(\.id))
        return popular.filter { !mine.contains($0.id) }
    }

    public func load() async {
        let service = self.service
        async let mine = Self.result { () throws(APIError) in try await service.subscriptions() }
        async let top = Self.result { () throws(APIError) in try await service.popular() }
        let (subscriptions, popular) = await (mine, top)
        if case let .success(items) = subscriptions { self.subscriptions = items }
        if case let .success(items) = popular { self.popular = items }
        failed = self.subscriptions.isEmpty && self.popular.isEmpty
            && (subscriptions.isFailure || popular.isFailure)
        isLoading = false
    }

    /// Runs from `.task(id: query)`, so typing cancels the previous search.
    public func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else {
            results = nil
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        if let items = try? await service.search(text), text == query.trimmingCharacters(in: .whitespaces) {
            results = items
        }
    }

    nonisolated private static func result<T: Sendable>(
        _ operation: @Sendable () async throws(APIError) -> T
    ) async -> Result<T, APIError> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }
}

private extension Result {
    var isFailure: Bool {
        if case .failure = self { true } else { false }
    }
}
