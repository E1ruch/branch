import Core
import DesignSystem
import Foundation
import Networking
import Stores
import UIKit

/// Which thread a screen shows.
public enum ThreadMode: Hashable, Sendable {
    /// A post and its comments.
    case post(id: Int64)
    /// "Продолжить ветку": one comment and the replies under it.
    case branch(commentID: Int64)
}

/// A row as the collection view sees it.
enum Row: Hashable, Sendable {
    case post
    /// The post is part of a story: previous and next parts, all parts.
    case story
    /// Branch mode: links to the whole post and one level up.
    case branchHeader
    case commentsHeader
    case comment(Int64)
    case more(parentID: Int64)
    case `continue`(parentID: Int64)
    /// Loading, empty, failed or loading the next page.
    case status
}

/// One entry of the thread in display order, as the server flattened it.
enum Entry: Equatable, Sendable {
    case comment(Int64)
    case more(parentID: Int64, depth: Int, count: Int, cursor: String?)
    case `continue`(parentID: Int64, depth: Int, count: Int)
}

/// One thread screen's state: the post (from the shared store), the
/// flattened comments with their precomputed layouts, folds, optimistic
/// votes and comments still being sent. Main-actor bound like its view
/// controller; network and measuring run elsewhere.
@MainActor
final class ThreadModel {
    enum Phase: Equatable {
        case loading, loaded, failed(APIError)
    }

    enum Status: Equatable {
        case none, loading, empty, failed, loadingMore
    }

    enum Change {
        /// Rows were added, removed or folded; `reconfigure` changed too.
        case rows(animated: Bool, reconfigure: [Row])
        /// The same rows with new content (votes, counters).
        case inPlace([Row])
        /// Everything was measured again (first load, width, text size).
        case reload
    }

    let mode: ThreadMode
    private(set) var postID: Int64?
    /// The comment a branch starts from.
    private(set) var root: Comment?
    private(set) var entries: [Entry] = []
    private(set) var comments: [Int64: Comment] = [:]
    private(set) var layouts: [Int64: CommentLayout] = [:]
    private(set) var postLayout: PostDetailLayout?
    private(set) var rows: [Row] = []
    private(set) var postPhase: Phase = .loading
    private(set) var commentsPhase: Phase = .loading
    private(set) var collapsed: Set<Int64> = []
    /// Comments shown before the server confirmed them (negative ids).
    private(set) var pending: Set<Int64> = []
    private(set) var loadingStubs: Set<Int64> = []
    private(set) var sort: API.CommentSort = .best
    /// The story's table of contents; empty until loaded or outside a story.
    private(set) var storyParts: [StoryPart] = []
    private(set) var fonts: ThreadFonts

    var isSignedIn: Bool
    /// The signed-in user, the author of comments sent from this screen.
    var viewer: AuthorRef?
    var onChange: ((Change) -> Void)?
    /// A comment did not go through: its text goes back to the composer.
    var onSendFailed: ((_ text: String, _ parentID: Int64?, APIError) -> Void)?
    /// An edit did not go through: the old text is back in the thread, the
    /// new one goes back to the composer.
    var onEditFailed: ((_ id: Int64, _ text: String, APIError) -> Void)?

    private let service: any PostService
    private let store: PostStore
    private let requestSignIn: () -> Void
    private let votes: VoteSync
    private var width: CGFloat = 0
    private var nextCursor: String?
    private var isLoadingMore = false
    private var loadGeneration = 0
    private var lastTempID: Int64 = 0
    /// Comments with an edit on its way: the text the server last confirmed.
    private var confirmedEdits: [Int64: Comment] = [:]

    /// Load the next page this many rows before the end.
    static let prefetchDistance = 8

    init(mode: ThreadMode, service: any PostService, store: PostStore, isSignedIn: Bool, viewer: AuthorRef?,
         requestSignIn: @escaping () -> Void, voteDebounce: Duration = .milliseconds(300),
         category: UIContentSizeCategory = .large) {
        self.mode = mode
        self.service = service
        self.store = store
        self.isSignedIn = isSignedIn
        self.viewer = viewer
        self.requestSignIn = requestSignIn
        self.fonts = ThreadFonts(category: category)
        votes = VoteSync(debounce: voteDebounce) { id, value throws(APIError) in
            try await service.voteComment(id, value: value)
        }
        if case let .post(id) = mode {
            postID = id
            // Opened from a feed: the post is already here, show it at once.
            if store[id] != nil {
                postPhase = .loaded
            }
        }
        votes.onOutcome = { [weak self] id, outcome in self?.apply(outcome, to: id) }
        store.observe(self) { [weak self] ids in
            guard let self, let postID, ids.contains(postID) else { return }
            Task { await self.postChanged() }
        }
        rebuildRows()
    }

    var post: Post? {
        postID.flatMap { store[$0] }
    }

    /// Branches indent from their root, so deep ones start at the left edge.
    var baseDepth: Int {
        root?.depth ?? 0
    }

    /// The viewer wrote this post: they may add the next part of its story.
    var canContinueStory: Bool {
        guard let viewer, let author = post?.author else { return false }
        return isSignedIn && author.id == viewer.id
    }

    /// The parts around this one, once the table of contents is loaded.
    var neighbourParts: (previous: StoryPart?, next: StoryPart?) {
        guard let postID, let index = storyParts.firstIndex(where: { $0.postId == postID }) else { return (nil, nil) }
        return (index > 0 ? storyParts[index - 1] : nil,
                index + 1 < storyParts.count ? storyParts[index + 1] : nil)
    }

    var title: String {
        switch mode {
        case .post: post?.community.title ?? "Пост"
        case .branch: "Ветка"
        }
    }

    var status: Status {
        if entries.isEmpty {
            return switch commentsPhase {
            case .loading: .loading
            case .failed: .failed
            case .loaded: isPostMode ? .empty : .none
            }
        }
        return nextCursor != nil ? .loadingMore : .none
    }

    var isPostMode: Bool {
        if case .post = mode { true } else { false }
    }

    func isOP(_ comment: Comment) -> Bool {
        guard let author = comment.author, let postAuthor = post?.author else { return false }
        return author.id == postAuthor.id
    }

    // MARK: Layout

    var hasWidth: Bool { width > 0 }

    func setWidth(_ newWidth: CGFloat, category: UIContentSizeCategory) async {
        let newFonts = ThreadFonts(category: category)
        guard newWidth > 0, newWidth != width || newFonts.postBody.pointSize != fonts.postBody.pointSize else { return }
        width = newWidth
        fonts = newFonts
        let all = Array(comments.values)
        let post = self.post
        async let measuredComments = Self.measure(all, baseDepth: baseDepth, width: newWidth, fonts: newFonts)
        async let measuredPost = Self.measure(post, width: newWidth, fonts: newFonts)
        (layouts, postLayout) = await (measuredComments, measuredPost)
        onChange?(.reload)
    }

    nonisolated static func measure(_ comments: [Comment], baseDepth: Int, width: CGFloat,
                                    fonts: ThreadFonts) async -> [Int64: CommentLayout] {
        var result: [Int64: CommentLayout] = [:]
        result.reserveCapacity(comments.count)
        for comment in comments {
            result[comment.id] = CommentLayout.make(for: comment, baseDepth: baseDepth, width: width, fonts: fonts)
        }
        return result
    }

    nonisolated static func measure(_ post: Post?, width: CGFloat, fonts: ThreadFonts) async -> PostDetailLayout? {
        post.map { PostDetailLayout.make(for: $0, width: width, fonts: fonts) }
    }

    // MARK: Loading

    /// The first load, a pull-to-refresh or a new sort.
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let service = self.service
        let sort = self.sort
        if entries.isEmpty {
            commentsPhase = .loading
        }

        switch mode {
        case let .post(id):
            async let postResult = Self.result { () throws(APIError) in try await service.post(id) }
            async let pageResult = Self.result { () throws(APIError) in
                try await service.thread(postID: id, sort: sort, cursor: nil)
            }
            let (post, page) = await (postResult, pageResult)
            guard generation == loadGeneration else { return }
            await applyPost(post)
            await applyFirstPage(page.map { (nil, $0) }, generation: generation)
            await loadStory()

        case let .branch(commentID):
            async let rootResult = Self.result { () throws(APIError) in try await service.comment(commentID) }
            async let pageResult = Self.result { () throws(APIError) in
                try await service.replies(commentID: commentID, sort: sort, cursor: nil)
            }
            let (root, page) = await (rootResult, pageResult)
            guard generation == loadGeneration else { return }
            let combined: Result<(Comment?, Page<ThreadItem>), APIError> = root.flatMap { root in
                page.map { (root, $0) }
            }
            await applyFirstPage(combined, generation: generation)
            // The header names the post: fetch it unless a feed already did.
            if let postID, store[postID] == nil {
                let post = await Self.result { () throws(APIError) in try await service.post(postID) }
                await applyPost(post)
            }
        }
    }

    /// Typed errors do not survive `async let` of a throwing call yet, so
    /// parallel requests return a Result instead.
    nonisolated private static func result<T: Sendable>(
        _ operation: @Sendable () async throws(APIError) -> T
    ) async -> Result<T, APIError> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    private func applyPost(_ result: Result<Post, APIError>) async {
        switch result {
        case let .success(post):
            postID = post.id
            store.merge([post]) // the observer re-measures if the text changed
            postLayout = await Self.measure(store[post.id], width: width, fonts: fonts)
            postPhase = .loaded
            rebuildRows()
            onChange?(.reload)
        case .failure(.cancelled):
            break
        case let .failure(error):
            if post == nil {
                postPhase = .failed(error)
                rebuildRows()
                onChange?(.reload)
            }
        }
    }

    private func applyFirstPage(_ result: Result<(Comment?, Page<ThreadItem>), APIError>, generation: Int) async {
        switch result {
        case let .success((root, page)):
            var fresh: [Int64: Comment] = [:]
            var newEntries: [Entry] = []
            if let root {
                fresh[root.id] = root
                newEntries.append(.comment(root.id))
            }
            newEntries += Self.absorb(page.items, into: &fresh)
            let base = root?.depth ?? 0
            let measured = await Self.measure(Array(fresh.values), baseDepth: base, width: width, fonts: fonts)
            guard generation == loadGeneration else { return }

            if let root {
                self.root = root
                postID = root.postId
            }
            // A comment still being sent stays at the top of its place.
            for id in pending {
                fresh[id] = comments[id]
            }
            let kept = entries.filter { if case let .comment(id) = $0 { pending.contains(id) } else { false } }
            comments = fresh
            layouts = measured.merging(layouts.filter { pending.contains($0.key) }) { new, _ in new }
            entries = kept.isEmpty ? newEntries : Self.insertPending(kept, into: newEntries, comments: comments)
            nextCursor = page.nextCursor
            commentsPhase = .loaded
        case .failure(.cancelled):
            return
        case let .failure(error):
            guard generation == loadGeneration else { return }
            if entries.isEmpty {
                commentsPhase = .failed(error)
            }
        }
        rebuildRows()
        onChange?(.reload)
    }

    /// The table of contents of the post's story, for the story row.
    private func loadStory() async {
        guard let postID, post?.story != nil else {
            storyParts = []
            return
        }
        let service = self.service
        if case let .success(parts) = await Self.result({ () throws(APIError) in try await service.storyParts(postID: postID) }) {
            storyParts = parts
            onChange?(.inPlace([.story]))
        }
    }

    /// Pending comments go back right under their parent (or on top).
    private static func insertPending(_ pendingEntries: [Entry], into entries: [Entry],
                                      comments: [Int64: Comment]) -> [Entry] {
        var result = entries
        for entry in pendingEntries.reversed() {
            guard case let .comment(id) = entry, let comment = comments[id] else { continue }
            let index = comment.parentId.flatMap { parent in result.firstIndex(of: .comment(parent)).map { $0 + 1 } } ?? 0
            result.insert(entry, at: index)
        }
        return result
    }

    /// Server items → entries, collecting the comments. Comments already on
    /// screen (one just sent, a page that moved) are skipped.
    private static func absorb(_ items: [ThreadItem], into comments: inout [Int64: Comment]) -> [Entry] {
        var entries: [Entry] = []
        entries.reserveCapacity(items.count)
        for item in items {
            switch item {
            case let .comment(comment):
                guard comments[comment.id] == nil else { continue }
                comments[comment.id] = comment
                entries.append(.comment(comment.id))
            case let .more(parentID, depth, count, cursor):
                entries.append(.more(parentID: parentID, depth: depth, count: count, cursor: cursor))
            case let .continue(parentID, depth, count):
                entries.append(.continue(parentID: parentID, depth: depth, count: count))
            }
        }
        return entries
    }

    func loadMoreIfNeeded(displaying row: Int) async {
        guard let cursor = nextCursor, !isLoadingMore,
              row >= rows.count - Self.prefetchDistance else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let generation = loadGeneration
        let page: Page<ThreadItem>
        do {
            switch mode {
            case let .post(id): page = try await service.thread(postID: id, sort: sort, cursor: cursor)
            case let .branch(id): page = try await service.replies(commentID: id, sort: sort, cursor: cursor)
            }
        } catch {
            return // the status row stays; the next scroll retries
        }
        var all = comments
        let newEntries = Self.absorb(page.items, into: &all)
        let added = all.filter { comments[$0.key] == nil }.map(\.value)
        let measured = await Self.measure(added, baseDepth: baseDepth, width: width, fonts: fonts)
        guard generation == loadGeneration else { return }
        for comment in added {
            comments[comment.id] = comment
        }
        layouts.merge(measured) { _, new in new }
        entries += newEntries
        nextCursor = page.nextCursor
        rebuildRows()
        onChange?(.rows(animated: false, reconfigure: []))
    }

    /// "Ещё N ответов": the next replies of `parentID` replace the stub in
    /// place, followed by a new stub if there are more still.
    func expandStub(parentID: Int64) async {
        guard !loadingStubs.contains(parentID),
              let index = entries.firstIndex(where: { if case .more(parentID, _, _, _) = $0 { true } else { false } }),
              case let .more(_, depth, count, cursor) = entries[index] else { return }
        loadingStubs.insert(parentID)
        onChange?(.inPlace([.more(parentID: parentID)]))
        let generation = loadGeneration
        defer { loadingStubs.remove(parentID) }

        let page: Page<ThreadItem>
        do {
            page = try await service.replies(commentID: parentID, sort: sort, cursor: cursor)
        } catch {
            guard generation == loadGeneration else { return }
            loadingStubs.remove(parentID)
            if error != .cancelled { Haptics.error() }
            onChange?(.inPlace([.more(parentID: parentID)]))
            return
        }
        var all = comments
        var replacement = Self.absorb(page.items, into: &all)
        let added = all.filter { comments[$0.key] == nil }.map(\.value)
        let measured = await Self.measure(added, baseDepth: baseDepth, width: width, fonts: fonts)
        guard generation == loadGeneration,
              let current = entries.firstIndex(where: { if case .more(parentID, _, _, _) = $0 { true } else { false } })
        else { return }

        // Direct replies the server sent, including any already on screen.
        let shown = page.items.reduce(0) { n, item in
            if case let .comment(c) = item, c.depth == depth { n + 1 } else { n }
        }
        if let next = page.nextCursor, count - shown > 0 {
            replacement.append(.more(parentID: parentID, depth: depth, count: count - shown, cursor: next))
        }
        for comment in added {
            comments[comment.id] = comment
        }
        layouts.merge(measured) { _, new in new }
        entries.replaceSubrange(current...current, with: replacement)
        loadingStubs.remove(parentID)
        rebuildRows()
        onChange?(.rows(animated: true, reconfigure: []))
    }

    func setSort(_ newSort: API.CommentSort) async {
        guard newSort != sort else { return }
        sort = newSort
        Haptics.selection()
        onChange?(.inPlace([.commentsHeader]))
        await load()
    }

    // MARK: Folding

    /// Folds a comment and everything under it, or unfolds it.
    func toggleCollapse(_ id: Int64) {
        guard comments[id] != nil, !pending.contains(id) else { return }
        if collapsed.remove(id) == nil {
            collapsed.insert(id)
        }
        Haptics.selection()
        rebuildRows()
        onChange?(.rows(animated: true, reconfigure: [.comment(id)]))
    }

    /// Unfolds whatever hides `id`, so "к родительскому" can scroll to it.
    func reveal(_ id: Int64) {
        var changed = false
        var parent = comments[id]?.parentId
        while let p = parent {
            if collapsed.remove(p) != nil { changed = true }
            parent = comments[p]?.parentId
        }
        if changed {
            rebuildRows()
            onChange?(.rows(animated: false, reconfigure: []))
        }
    }

    private func depth(of entry: Entry) -> Int {
        switch entry {
        case let .comment(id): comments[id]?.depth ?? 0
        case let .more(_, depth, _, _), let .continue(_, depth, _): depth
        }
    }

    private func rebuildRows() {
        var rows: [Row] = []
        switch mode {
        case .post:
            rows = post?.story != nil ? [.post, .story, .commentsHeader] : [.post, .commentsHeader]
        case .branch:
            if root != nil { rows = [.branchHeader] }
        }
        var hideDeeperThan: Int?
        for entry in entries {
            let d = depth(of: entry)
            if let limit = hideDeeperThan {
                if d > limit { continue }
                hideDeeperThan = nil
            }
            switch entry {
            case let .comment(id):
                rows.append(.comment(id))
                if collapsed.contains(id) { hideDeeperThan = d }
            case let .more(parentID, _, _, _):
                rows.append(.more(parentID: parentID))
            case let .continue(parentID, _, _):
                rows.append(.continue(parentID: parentID))
            }
        }
        if status != .none {
            rows.append(.status)
        }
        self.rows = rows
    }

    func stub(for parentID: Int64) -> Entry? {
        entries.first {
            switch $0 {
            case .more(parentID, _, _, _), .continue(parentID, _, _): true
            default: false
            }
        }
    }

    private func postChanged() async {
        guard let post else { return }
        if let layout = postLayout, layout.title == post.title, layout.body == PostDetailLayout.displayBody(of: post) {
            onChange?(.inPlace([.post, .story, .commentsHeader]))
            return
        }
        postLayout = await Self.measure(post, width: width, fonts: fonts)
        postPhase = .loaded
        rebuildRows()
        onChange?(.reload)
    }

    // MARK: Votes

    func tapPostVote(direction: Int) {
        guard isSignedIn else {
            requestSignIn()
            return
        }
        if let postID {
            store.vote(postID, direction: direction)
        }
    }

    func tapCommentVote(_ id: Int64, direction: Int) {
        guard isSignedIn else {
            requestSignIn()
            return
        }
        guard let comment = comments[id], !comment.isDeleted, !pending.contains(id) else { return }
        let (myVote, score) = votes.tap(id, myVote: comment.myVote, score: comment.score, direction: direction)
        comments[id] = comment.with(myVote: myVote, score: score)
        onChange?(.inPlace([.comment(id)]))
    }

    private func apply(_ outcome: VoteSync.Outcome, to id: Int64) {
        guard let comment = comments[id] else { return }
        switch outcome {
        case let .confirmed(myVote, score):
            comments[id] = comment.with(myVote: myVote, score: score)
        case let .rolledBack(myVote, score, error):
            comments[id] = comment.with(myVote: myVote, score: score)
            if error == .unauthorized { requestSignIn() }
        }
        onChange?(.inPlace([.comment(id)]))
    }

    // MARK: Sending

    /// Shows the comment at once (dimmed) and sends it. `parentID` nil is a
    /// top-level comment; in a branch, a reply to its root. Returns the row
    /// to scroll to, or nil when nothing was sent.
    @discardableResult
    func send(_ text: String, replyTo parentID: Int64?) -> Row? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let postID else { return nil }
        guard isSignedIn, let viewer else {
            requestSignIn()
            return nil
        }
        let parentID = parentID ?? root?.id
        let parent = parentID.flatMap { comments[$0] }
        lastTempID -= 1
        let tempID = lastTempID
        let comment = Comment(id: tempID, postId: postID, parentId: parentID, depth: parent.map { $0.depth + 1 } ?? 0,
                              body: body, isDeleted: false, author: viewer, score: 0, myVote: 0, replyCount: 0,
                              createdAt: Date(), editedAt: nil)
        comments[tempID] = comment
        layouts[tempID] = CommentLayout.make(for: comment, baseDepth: baseDepth, width: width, fonts: fonts)
        pending.insert(tempID)
        if let parentID {
            collapsed.remove(parentID)
        }
        // Right under the parent (or on top): where the user is looking.
        let index = parentID.flatMap { entries.firstIndex(of: .comment($0)).map { $0 + 1 } } ?? 0
        entries.insert(.comment(tempID), at: index)
        if commentsPhase != .loaded && isPostMode {
            commentsPhase = .loaded
        }
        rebuildRows()
        onChange?(.rows(animated: true, reconfigure: parentID.map { [.comment($0)] } ?? []))

        // A branch's root is the composer's default, not a reply it chose.
        let composerParent = parentID == root?.id ? nil : parentID
        Task { [weak self] in
            await self?.deliver(tempID, body: body, parentID: parentID, composerParent: composerParent)
        }
        return .comment(tempID)
    }

    private func deliver(_ tempID: Int64, body: String, parentID: Int64?, composerParent: Int64?) async {
        guard let postID else { return }
        do {
            let saved = try await service.createComment(postID: postID, parentID: parentID, body: body)
            pending.remove(tempID)
            comments[tempID] = nil
            comments[saved.id] = saved
            layouts[saved.id] = CommentLayout.make(for: saved, baseDepth: baseDepth, width: width, fonts: fonts)
            layouts[tempID] = nil
            if let index = entries.firstIndex(of: .comment(tempID)) {
                entries[index] = .comment(saved.id)
            }
            var reconfigure: [Row] = [.comment(saved.id)]
            if let parentID, let parent = comments[parentID] {
                comments[parentID] = parent.with(replyCount: parent.replyCount + 1)
                reconfigure.append(.comment(parentID))
            }
            store.commentAdded(to: postID)
            Haptics.success()
            rebuildRows()
            onChange?(.rows(animated: false, reconfigure: reconfigure))
        } catch {
            pending.remove(tempID)
            comments[tempID] = nil
            layouts[tempID] = nil
            entries.removeAll { $0 == .comment(tempID) }
            Haptics.error()
            rebuildRows()
            onChange?(.rows(animated: true, reconfigure: []))
            onSendFailed?(body, composerParent, error)
            if error == .unauthorized { requestSignIn() }
        }
    }

    /// Whether the signed-in user may edit this comment.
    func canEdit(_ comment: Comment) -> Bool {
        guard let viewer, !comment.isDeleted, comment.body != nil, !pending.contains(comment.id) else { return false }
        return comment.author?.id == viewer.id
    }

    /// Shows the new text at once ("изменено" included) and saves it. An
    /// error puts the confirmed text back and hands the new one to the
    /// composer for another try.
    func edit(_ id: Int64, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comment = comments[id], canEdit(comment), !body.isEmpty, body != comment.body else { return }
        if confirmedEdits[id] == nil {
            confirmedEdits[id] = comment
        }
        show(comment.with(body: body, editedAt: Date()))
        Task { [weak self] in
            await self?.saveEdit(id, body: body)
        }
    }

    private func saveEdit(_ id: Int64, body: String) async {
        do {
            let saved = try await service.editComment(id, body: body)
            guard let current = comments[id] else { return }
            let confirmed = current.with(body: saved.body, editedAt: saved.editedAt)
            if current.body == body {
                confirmedEdits[id] = nil
                Haptics.success()
            } else {
                confirmedEdits[id] = confirmed // a newer edit is on its way
            }
        } catch {
            // A newer edit took over: its own outcome decides.
            guard comments[id]?.body == body, let old = confirmedEdits.removeValue(forKey: id),
                  let current = comments[id] else { return }
            show(current.with(body: old.body, editedAt: old.editedAt))
            Haptics.error()
            onEditFailed?(id, body, error)
            if error == .unauthorized { requestSignIn() }
        }
    }

    /// A comment changed its text: measure it again and resize its row.
    private func show(_ comment: Comment) {
        comments[comment.id] = comment
        layouts[comment.id] = CommentLayout.make(for: comment, baseDepth: baseDepth, width: width, fonts: fonts)
        onChange?(.rows(animated: true, reconfigure: [.comment(comment.id)]))
    }

    /// Signing in or out changes my_vote everywhere: load again.
    func sessionChanged(signedIn: Bool, viewer: AuthorRef?) async {
        self.viewer = viewer
        guard signedIn != isSignedIn else { return }
        isSignedIn = signedIn
        votes.reset()
        await load()
    }
}
