import Core
import DesignSystem
import Foundation
import Networking
import Observation

/// What the composer needs from the server. A protocol so publishing and
/// the community picker are tested without a network.
public protocol ComposeService: Sendable {
    func subscriptions() async throws(APIError) -> [Community]
    func popular() async throws(APIError) -> [Community]
    func search(_ query: String) async throws(APIError) -> [Community]
    func publish(community slug: String, title: String, body: String, isNSFW: Bool,
                 continues: Int64?) async throws(APIError) -> Post
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

    public func publish(community slug: String, title: String, body: String, isNSFW: Bool,
                        continues: Int64?) async throws(APIError) -> Post {
        try await client.send(API.createPost(community: slug, title: title, body: body, isNSFW: isNSFW,
                                             continues: continues))
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

    public init() {}

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public protocol DraftStorage: Sendable {
    func load() -> Draft?
    func save(_ draft: Draft)
    func clear()
}

/// One draft per account, so signing in as someone else never shows
/// another person's text.
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

    public func load() -> Draft? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(Draft.self, from: $0) }
    }

    public func save(_ draft: Draft) {
        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    public func clear() {
        UserDefaults.standard.removeObject(forKey: key)
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
    /// Why the last publish failed, in words for the user.
    public private(set) var error: String?
    /// The field the server rejected, to put the cursor there.
    public private(set) var errorField: Field?

    public enum Field: Hashable { case title, body }

    public static let maxTitle = 300
    public static let maxBody = 40_000

    private let service: any ComposeService
    private let storage: any DraftStorage
    private let saveDelay: Duration
    private var saveTask: Task<Void, Never>?
    /// Published: the closing sheet must not save the text back as a draft.
    private var isPublished = false

    /// `community` preselects where to post (opened from a community page),
    /// `continues` the story to add a part to (from a post's menu); either
    /// wins over the saved draft's.
    public init(service: any ComposeService, storage: any DraftStorage, community: PickedCommunity? = nil,
                continues: ContinuedPost? = nil, saveDelay: Duration = .milliseconds(400)) {
        self.service = service
        self.storage = storage
        self.saveDelay = saveDelay
        var draft = storage.load() ?? Draft()
        if let community {
            draft.community = community
        }
        if let continues {
            draft.continues = continues
        }
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
        !isPublishing && !trimmedTitle.isEmpty
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

    private func scheduleSave() {
        saveTask?.cancel()
        guard !isPublished else { return }
        let draft = self.draft
        saveTask = Task { [storage, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            if draft.isEmpty && draft.community == nil {
                storage.clear()
            } else {
                storage.save(draft)
            }
        }
    }

    /// The composer is closing: write the draft now, not after the delay.
    public func saveNow() {
        saveTask?.cancel()
        guard !isPublished else { return }
        if hasContent || draft.community != nil {
            storage.save(draft)
        } else {
            storage.clear()
        }
    }

    public func discard() {
        draft = Draft()
        saveTask?.cancel()
        storage.clear()
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
        do {
            let post = try await service.publish(community: community.slug, title: trimmedTitle,
                                                 body: trimmedBody, isNSFW: isNSFW,
                                                 continues: draft.continues?.postID)
            isPublished = true
            saveTask?.cancel()
            storage.clear()
            Haptics.success()
            return post
        } catch {
            if error == .cancelled { return nil }
            (self.error, errorField) = Self.describe(error)
            Haptics.error()
            return nil
        }
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
