import Core
import Networking

/// The one copy of every post the app has seen (an identity map). Feeds and
/// the post screen keep only ids and read posts here, so a vote on the post
/// screen is already in the feed when the user swipes back.
@MainActor
public final class PostStore {
    public private(set) var posts: [Int64: Post] = [:]
    /// Raised when a vote needs an account (the session ended meanwhile).
    public var requestSignIn: () -> Void = {}

    private let votes: VoteSync
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let handler: ([Int64]) -> Void
    }

    public init(voteDebounce: Duration = .milliseconds(300), vote: @escaping VoteSync.Send) {
        votes = VoteSync(debounce: voteDebounce, send: vote)
        votes.onOutcome = { [weak self] id, outcome in self?.apply(outcome, to: id) }
    }

    public convenience init(client: APIClient) {
        self.init { id, value throws(APIError) in
            try await client.send(API.votePost(id, value: value))
        }
    }

    public subscript(id: Int64) -> Post? {
        posts[id]
    }

    /// Calls `handler` with the ids of posts that changed in place (a vote,
    /// a new comment, fresher data), for as long as `owner` lives.
    public func observe(_ owner: AnyObject, _ handler: @escaping ([Int64]) -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    /// Takes posts from the server. A vote still on its way keeps its
    /// optimistic state; a feed's preview keeps a full body already loaded.
    public func merge(_ incoming: [Post]) {
        var changed: [Int64] = []
        for post in incoming {
            guard let old = posts[post.id] else {
                posts[post.id] = post
                continue
            }
            var new = old.merged(with: post)
            if votes.isPending(post.id) {
                new = new.with(myVote: old.myVote, score: old.score)
            }
            if new != old {
                posts[post.id] = new
                changed.append(post.id)
            }
        }
        notify(changed)
    }

    /// A tap on ▲ (1) or ▼ (-1). The caller checks for an account first.
    public func vote(_ id: Int64, direction: Int) {
        guard let post = posts[id] else { return }
        let (myVote, score) = votes.tap(id, myVote: post.myVote, score: post.score, direction: direction)
        posts[id] = post.with(myVote: myVote, score: score)
        notify([id])
    }

    /// A comment was posted under the post.
    public func commentAdded(to id: Int64) {
        guard let post = posts[id] else { return }
        posts[id] = post.with(commentCount: post.commentCount + 1)
        notify([id])
    }

    /// Signing in or out changes my_vote everywhere; feeds reload after this.
    public func sessionChanged() {
        votes.reset()
    }

    private func apply(_ outcome: VoteSync.Outcome, to id: Int64) {
        guard let post = posts[id] else { return }
        switch outcome {
        case let .confirmed(myVote, score):
            posts[id] = post.with(myVote: myVote, score: score)
        case let .rolledBack(myVote, score, error):
            posts[id] = post.with(myVote: myVote, score: score)
            if error == .unauthorized {
                requestSignIn()
            }
        }
        notify([id])
    }

    private func notify(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        for observer in observers where observer.owner != nil {
            observer.handler(ids)
        }
    }
}
