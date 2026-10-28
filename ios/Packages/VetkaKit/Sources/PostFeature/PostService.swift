import Core
import Networking

/// What the post screen needs from the server. A protocol so the thread
/// logic (stubs, replies, optimistic votes and comments) is tested without
/// a network. Post votes go through the shared PostStore.
public protocol PostService: Sendable {
    func post(_ id: Int64) async throws(APIError) -> Post
    func comment(_ id: Int64) async throws(APIError) -> Comment
    func thread(postID: Int64, sort: API.CommentSort, cursor: String?) async throws(APIError) -> Page<ThreadItem>
    func replies(commentID: Int64, sort: API.CommentSort, cursor: String?) async throws(APIError) -> Page<ThreadItem>
    func createComment(postID: Int64, parentID: Int64?, body: String) async throws(APIError) -> Comment
    func voteComment(_ id: Int64, value: Int) async throws(APIError) -> VoteResult
}

public struct LivePostService: PostService {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public func post(_ id: Int64) async throws(APIError) -> Post {
        try await client.send(API.post(id))
    }

    public func comment(_ id: Int64) async throws(APIError) -> Comment {
        try await client.send(API.comment(id))
    }

    public func thread(postID: Int64, sort: API.CommentSort, cursor: String?) async throws(APIError) -> Page<ThreadItem> {
        try await client.send(API.thread(postID: postID, sort: sort, cursor: cursor))
    }

    public func replies(commentID: Int64, sort: API.CommentSort, cursor: String?) async throws(APIError) -> Page<ThreadItem> {
        try await client.send(API.replies(commentID: commentID, sort: sort, cursor: cursor))
    }

    public func createComment(postID: Int64, parentID: Int64?, body: String) async throws(APIError) -> Comment {
        try await client.send(API.createComment(postID: postID, parentID: parentID, body: body))
    }

    public func voteComment(_ id: Int64, value: Int) async throws(APIError) -> VoteResult {
        try await client.send(API.voteComment(id, value: value))
    }
}
