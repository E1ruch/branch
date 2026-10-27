import Core
import Foundation

/// The backend contract as typed endpoints. One place to look for what the
/// app can ask the server, mirroring backend/internal/httpapi/router.go.
public enum API {
    public enum FeedSort: String, Sendable { case hot, new }
    public enum CommentSort: String, Sendable { case best, new }

    // MARK: Auth

    public static func refresh(_ refreshToken: String) -> Endpoint<Tokens> {
        Endpoint(.post, "/v1/auth/refresh", body: ["refresh_token": refreshToken], auth: .none)
    }

    public static func logout(_ refreshToken: String) -> Endpoint<NoContent> {
        Endpoint(.post, "/v1/auth/logout", body: ["refresh_token": refreshToken], auth: .none)
    }

    // MARK: Me

    public static func me() -> Endpoint<Me> {
        Endpoint(.get, "/v1/me", auth: .required)
    }

    // MARK: Feeds

    public static func feedAll(sort: FeedSort = .hot, cursor: String? = nil) -> Endpoint<Page<Post>> {
        Endpoint(.get, "/v1/feed/all", query: page(cursor, ("sort", sort.rawValue)))
    }

    public static func feedSubscriptions(sort: FeedSort = .hot, cursor: String? = nil) -> Endpoint<Page<Post>> {
        Endpoint(.get, "/v1/feed/subscriptions", query: page(cursor, ("sort", sort.rawValue)), auth: .required)
    }

    public static func communityFeed(_ slug: String, sort: FeedSort = .hot, cursor: String? = nil) -> Endpoint<Page<Post>> {
        Endpoint(.get, "/v1/communities/\(slug)/posts", query: page(cursor, ("sort", sort.rawValue)))
    }

    // MARK: Communities

    public static func popularCommunities(cursor: String? = nil) -> Endpoint<Page<Community>> {
        Endpoint(.get, "/v1/communities", query: page(cursor))
    }

    public static func searchCommunities(_ query: String) -> Endpoint<Page<Community>> {
        Endpoint(.get, "/v1/communities/search", query: [URLQueryItem(name: "q", value: query)])
    }

    public static func community(_ slug: String) -> Endpoint<Community> {
        Endpoint(.get, "/v1/communities/\(slug)")
    }

    // MARK: Posts, comments, votes

    public static func post(_ id: Int64) -> Endpoint<Post> {
        Endpoint(.get, "/v1/posts/\(id)")
    }

    public static func thread(postID: Int64, sort: CommentSort = .best, cursor: String? = nil) -> Endpoint<Page<ThreadItem>> {
        Endpoint(.get, "/v1/posts/\(postID)/comments", query: page(cursor, ("sort", sort.rawValue)))
    }

    public static func replies(commentID: Int64, sort: CommentSort = .best, cursor: String? = nil) -> Endpoint<Page<ThreadItem>> {
        Endpoint(.get, "/v1/comments/\(commentID)/replies", query: page(cursor, ("sort", sort.rawValue)))
    }

    /// Sets the vote to a state (-1, 0, 1): safe to retry, unlike a toggle.
    public static func votePost(_ id: Int64, value: Int) -> Endpoint<VoteResult> {
        Endpoint(.put, "/v1/posts/\(id)/vote", body: ["value": value], auth: .required)
    }

    public static func voteComment(_ id: Int64, value: Int) -> Endpoint<VoteResult> {
        Endpoint(.put, "/v1/comments/\(id)/vote", body: ["value": value], auth: .required)
    }

    // MARK: Users

    public static func user(_ username: String) -> Endpoint<User> {
        Endpoint(.get, "/v1/users/\(username)")
    }

    private static func page(_ cursor: String?, _ extra: (String, String)...) -> [URLQueryItem] {
        var items = extra.map { URLQueryItem(name: $0.0, value: $0.1) }
        if let cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return items
    }
}
