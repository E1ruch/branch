import Core
import Foundation

/// The backend contract as typed endpoints. One place to look for what the
/// app can ask the server, mirroring backend/internal/httpapi/router.go.
public enum API {
    public enum FeedSort: String, Sendable { case hot, new }
    public enum CommentSort: String, Sendable { case best, new }

    // MARK: Auth

    public struct AppleSignIn: Encodable, Sendable {
        public var identityToken: String
        /// The raw nonce; Apple got its SHA-256.
        public var nonce: String
        /// Apple sends the name only on the very first authorization.
        public var givenName: String?
        public var familyName: String?
        public var deviceName: String

        public init(identityToken: String, nonce: String, givenName: String?, familyName: String?, deviceName: String) {
            self.identityToken = identityToken
            self.nonce = nonce
            self.givenName = givenName
            self.familyName = familyName
            self.deviceName = deviceName
        }
    }

    public static func signInWithApple(_ body: AppleSignIn) -> Endpoint<AuthSession> {
        Endpoint(.post, "/v1/auth/apple", body: body, auth: .none)
    }

    private struct PasswordAuth: Encodable, Sendable {
        let username: String
        let password: String
        let deviceName: String
    }

    /// Creates an account with a chosen username: no onboarding afterwards.
    public static func register(username: String, password: String, deviceName: String) -> Endpoint<AuthSession> {
        Endpoint(.post, "/v1/auth/register",
                 body: PasswordAuth(username: username, password: password, deviceName: deviceName), auth: .none)
    }

    public static func login(username: String, password: String, deviceName: String) -> Endpoint<AuthSession> {
        Endpoint(.post, "/v1/auth/login",
                 body: PasswordAuth(username: username, password: password, deviceName: deviceName), auth: .none)
    }

    private struct TelegramSignIn: Encodable, Sendable {
        let data: [String: String]
        let deviceName: String
    }

    /// `data` is the callback's query parameters exactly as Telegram signed them.
    public static func signInWithTelegram(data: [String: String], deviceName: String) -> Endpoint<AuthSession> {
        Endpoint(.post, "/v1/auth/telegram", body: TelegramSignIn(data: data, deviceName: deviceName), auth: .none)
    }

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

    private struct ProfileUpdate: Encodable, Sendable {
        let username: String?
        let displayName: String?
        let bio: String?
    }

    /// nil fields are left out of the body and stay as they are on the
    /// server; an empty string clears a display name or bio.
    public static func updateMe(username: String? = nil, displayName: String? = nil, bio: String? = nil) -> Endpoint<Me> {
        Endpoint(.patch, "/v1/me", body: ProfileUpdate(username: username, displayName: displayName, bio: bio), auth: .required)
    }

    public static func usernameAvailability(_ username: String) -> Endpoint<UsernameAvailability> {
        Endpoint(.get, "/v1/usernames/\(username)/availability", auth: .none)
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

    /// The signed-in user's subscriptions, all in one page.
    public static func mySubscriptions() -> Endpoint<Page<Community>> {
        Endpoint(.get, "/v1/me/subscriptions", auth: .required)
    }

    public static func community(_ slug: String) -> Endpoint<Community> {
        Endpoint(.get, "/v1/communities/\(slug)")
    }

    /// Sets the subscription to a state (PUT subscribes, DELETE leaves), so
    /// a retry never flips it back. Returns the community with the fresh
    /// subscriber count.
    public static func setSubscription(_ slug: String, subscribed: Bool) -> Endpoint<Community> {
        Endpoint(subscribed ? .put : .delete, "/v1/communities/\(slug)/subscription", auth: .required)
    }

    // MARK: Posts, comments, votes

    private struct NewPost: Encodable, Sendable {
        let title: String
        let body: String
        let isNsfw: Bool
        let continuesPostId: Int64?
    }

    /// `continues`: the author's post this one follows; the new post
    /// becomes the next part of that story.
    public static func createPost(community slug: String, title: String, body: String, isNSFW: Bool,
                                  continues: Int64? = nil) -> Endpoint<Post> {
        Endpoint(.post, "/v1/communities/\(slug)/posts",
                 body: NewPost(title: title, body: body, isNsfw: isNSFW, continuesPostId: continues), auth: .required)
    }

    /// The parts of the post's story in order; empty outside a story.
    public static func story(postID: Int64) -> Endpoint<Page<StoryPart>> {
        Endpoint(.get, "/v1/posts/\(postID)/story")
    }

    public static func post(_ id: Int64) -> Endpoint<Post> {
        Endpoint(.get, "/v1/posts/\(id)")
    }

    public static func thread(postID: Int64, sort: CommentSort = .best, cursor: String? = nil) -> Endpoint<Page<ThreadItem>> {
        Endpoint(.get, "/v1/posts/\(postID)/comments", query: page(cursor, ("sort", sort.rawValue)))
    }

    public static func replies(commentID: Int64, sort: CommentSort = .best, cursor: String? = nil) -> Endpoint<Page<ThreadItem>> {
        Endpoint(.get, "/v1/comments/\(commentID)/replies", query: page(cursor, ("sort", sort.rawValue)))
    }

    public static func comment(_ id: Int64) -> Endpoint<Comment> {
        Endpoint(.get, "/v1/comments/\(id)")
    }

    private struct NewComment: Encodable, Sendable {
        let body: String
        let parentId: Int64?
    }

    /// A top-level comment (parentID nil) or a reply.
    public static func createComment(postID: Int64, parentID: Int64?, body: String) -> Endpoint<Comment> {
        Endpoint(.post, "/v1/posts/\(postID)/comments", body: NewComment(body: body, parentId: parentID), auth: .required)
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

    public static func userPosts(_ username: String, cursor: String? = nil) -> Endpoint<Page<Post>> {
        Endpoint(.get, "/v1/users/\(username)/posts", query: page(cursor))
    }

    private static func page(_ cursor: String?, _ extra: (String, String)...) -> [URLQueryItem] {
        var items = extra.map { URLQueryItem(name: $0.0, value: $0.1) }
        if let cursor {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }
        return items
    }
}
