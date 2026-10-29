import Foundation

// Wire models, one-to-one with the backend JSON (snake_case is converted by
// JSON.decoder). Value types and Sendable: they cross from the network
// decoding task to the main actor without copies of shared state.

public struct User: Codable, Sendable, Hashable, Identifiable {
    public let id: Int64
    public let username: String
    public let displayName: String?
    public let bio: String?
    public let postKarma: Int
    public let commentKarma: Int
    public let createdAt: Date
    public let postsCount: Int
    public let followersCount: Int
    public let followingCount: Int
}

/// The signed-in user's own profile: the public one plus owner-only fields.
public struct Me: Codable, Sendable, Hashable, Identifiable {
    public let id: Int64
    public let username: String
    public let displayName: String?
    public let bio: String?
    public let postKarma: Int
    public let commentKarma: Int
    public let createdAt: Date
    public let postsCount: Int
    public let followersCount: Int
    public let followingCount: Int
    /// When a new username can be picked; nil means now.
    public let usernameChangeableAt: Date?
}

/// Someone's profile as the viewer sees it (GET /v1/users/{username}).
public struct Profile: Codable, Sendable, Hashable, Identifiable {
    public let id: Int64
    public let username: String
    public let displayName: String?
    public let bio: String?
    public let postKarma: Int
    public let commentKarma: Int
    public let createdAt: Date
    public let postsCount: Int
    public let followersCount: Int
    public let followingCount: Int
    /// Always false for yourself and when signed out.
    public let isFollowing: Bool

    public init(id: Int64, username: String, displayName: String?, bio: String?, postKarma: Int, commentKarma: Int,
                createdAt: Date, postsCount: Int, followersCount: Int, followingCount: Int, isFollowing: Bool) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.bio = bio
        self.postKarma = postKarma
        self.commentKarma = commentKarma
        self.createdAt = createdAt
        self.postsCount = postsCount
        self.followersCount = followersCount
        self.followingCount = followingCount
        self.isFollowing = isFollowing
    }

    /// Your own profile, known before the request for it returns.
    public init(_ me: Me) {
        self.init(id: me.id, username: me.username, displayName: me.displayName, bio: me.bio,
                  postKarma: me.postKarma, commentKarma: me.commentKarma, createdAt: me.createdAt,
                  postsCount: me.postsCount, followersCount: me.followersCount,
                  followingCount: me.followingCount, isFollowing: false)
    }

    /// What the header shows first: the display name, else the username.
    public var name: String { displayName ?? username }

    /// Both kinds of karma: the header shows the sum, the split on tap.
    public var karma: Int { postKarma + commentKarma }

    /// A copy with the viewer's follow changed: optimistic UI shows it
    /// before the server confirms.
    public func with(isFollowing: Bool, followersCount: Int) -> Profile {
        Profile(id: id, username: username, displayName: displayName, bio: bio, postKarma: postKarma,
                commentKarma: commentKarma, createdAt: createdAt, postsCount: postsCount,
                followersCount: followersCount, followingCount: followingCount, isFollowing: isFollowing)
    }

    /// A copy with another "подписки" count: you followed someone from
    /// another screen while your own profile was loaded.
    public func with(followingCount: Int) -> Profile {
        Profile(id: id, username: username, displayName: displayName, bio: bio, postKarma: postKarma,
                commentKarma: commentKarma, createdAt: createdAt, postsCount: postsCount,
                followersCount: followersCount, followingCount: followingCount, isFollowing: isFollowing)
    }
}

public struct Community: Codable, Sendable, Hashable, Identifiable {
    public let id: Int64
    public let slug: String
    public let title: String
    public let description: String
    public let isNsfw: Bool
    public let subscribersCount: Int
    public let createdAt: Date
    public let isSubscribed: Bool
    public let viewerRole: String?
    /// Only a single community (GET /v1/communities/{slug}) carries its
    /// rules; in lists this is nil, meaning "not loaded", not "none".
    public let rules: [CommunityRule]?

    public init(id: Int64, slug: String, title: String, description: String, isNsfw: Bool, subscribersCount: Int,
                createdAt: Date, isSubscribed: Bool, viewerRole: String?, rules: [CommunityRule]?) {
        self.id = id
        self.slug = slug
        self.title = title
        self.description = description
        self.isNsfw = isNsfw
        self.subscribersCount = subscribersCount
        self.createdAt = createdAt
        self.isSubscribed = isSubscribed
        self.viewerRole = viewerRole
        self.rules = rules
    }
}

public struct CommunityRule: Codable, Sendable, Hashable {
    public let title: String
    /// May be empty: some rules are only a title.
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public struct CommunityRef: Codable, Sendable, Hashable {
    public let id: Int64
    public let slug: String
    public let title: String
}

public struct AuthorRef: Codable, Sendable, Hashable {
    public let id: Int64
    public let username: String
    public let displayName: String?

    public init(id: Int64, username: String, displayName: String?) {
        self.id = id
        self.username = username
        self.displayName = displayName
    }
}

public struct Post: Codable, Sendable, Hashable, Identifiable {
    public let id: Int64
    public let title: String
    /// A 600-character preview in feeds (see bodyTruncated), full in a post.
    public let body: String
    public let bodyTruncated: Bool
    public let isNsfw: Bool
    public let score: Int
    public let commentCount: Int
    public let myVote: Int
    public let createdAt: Date
    public let editedAt: Date?
    public let community: CommunityRef
    /// nil when the account is deleted.
    public let author: AuthorRef?
    /// Where the post stands in its story; nil outside a story.
    public let story: StoryRef?
}

/// "Часть 2 из 3": counts live parts only.
public struct StoryRef: Codable, Sendable, Hashable {
    public let id: Int64
    public let part: Int
    public let parts: Int

    public var isLast: Bool { part == parts }
}

/// One entry of a story's table of contents (GET /v1/posts/{id}/story).
public struct StoryPart: Codable, Sendable, Hashable, Identifiable {
    public let postId: Int64
    public let title: String
    public let part: Int
    public let createdAt: Date

    public var id: Int64 { postId }
}

public struct Comment: Codable, Sendable, Hashable, Identifiable {
    public let id: Int64
    public let postId: Int64
    public let parentId: Int64?
    /// Absolute depth: the app indents by it, no tree logic needed.
    public let depth: Int
    /// nil for a deleted comment (a tombstone that keeps its replies).
    public let body: String?
    public let isDeleted: Bool
    public let author: AuthorRef?
    public let score: Int
    public let myVote: Int
    public let replyCount: Int
    public let createdAt: Date
    public let editedAt: Date?

    public init(id: Int64, postId: Int64, parentId: Int64?, depth: Int, body: String?, isDeleted: Bool,
                author: AuthorRef?, score: Int, myVote: Int, replyCount: Int, createdAt: Date, editedAt: Date?) {
        self.id = id
        self.postId = postId
        self.parentId = parentId
        self.depth = depth
        self.body = body
        self.isDeleted = isDeleted
        self.author = author
        self.score = score
        self.myVote = myVote
        self.replyCount = replyCount
        self.createdAt = createdAt
        self.editedAt = editedAt
    }
}

/// One row of a comment thread, in display order.
public enum ThreadItem: Decodable, Sendable, Hashable {
    case comment(Comment)
    /// "ещё N ответов": load with GET /v1/comments/{parentId}/replies?cursor=.
    case more(parentId: Int64, depth: Int, count: Int, cursor: String?)
    /// "продолжить ветку": open the replies of parentId as a new screen.
    case `continue`(parentId: Int64, depth: Int, count: Int)

    private enum CodingKeys: String, CodingKey {
        case kind, comment, parentId, depth, count, cursor
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "comment":
            self = .comment(try c.decode(Comment.self, forKey: .comment))
        case "more":
            self = .more(parentId: try c.decode(Int64.self, forKey: .parentId),
                         depth: try c.decode(Int.self, forKey: .depth),
                         count: try c.decode(Int.self, forKey: .count),
                         cursor: try c.decodeIfPresent(String.self, forKey: .cursor))
        case "continue":
            self = .continue(parentId: try c.decode(Int64.self, forKey: .parentId),
                             depth: try c.decode(Int.self, forKey: .depth),
                             count: try c.decode(Int.self, forKey: .count))
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "unknown thread item kind \(kind)")
        }
    }
}

/// The envelope of every paginated list. The cursor is opaque: pass it back.
public struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Item]
    public let nextCursor: String?

    public init(items: [Item], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct VoteResult: Codable, Sendable, Hashable {
    public let myVote: Int
    /// Includes votes the server has not folded into counters yet.
    public let score: Int
}

public struct Tokens: Codable, Sendable, Hashable {
    public let accessToken: String
    public let accessExpiresAt: Date
    public let refreshToken: String

    public init(accessToken: String, accessExpiresAt: Date, refreshToken: String) {
        self.accessToken = accessToken
        self.accessExpiresAt = accessExpiresAt
        self.refreshToken = refreshToken
    }
}

/// A successful sign-in.
public struct AuthSession: Decodable, Sendable {
    public let accessToken: String
    public let accessExpiresAt: Date
    public let refreshToken: String
    public let user: User
    /// Show onboarding (pick a username).
    public let isNewUser: Bool

    public var tokens: Tokens {
        Tokens(accessToken: accessToken, accessExpiresAt: accessExpiresAt, refreshToken: refreshToken)
    }
}

/// GET /v1/usernames/{name}/availability.
public struct UsernameAvailability: Decodable, Sendable, Hashable {
    public let username: String
    public let available: Bool
    /// "invalid" or "taken" when not available.
    public let reason: String?
    /// Why an invalid name is invalid, from the server's rules.
    public let message: String?

    public init(username: String, available: Bool, reason: String?, message: String?) {
        self.username = username
        self.available = available
        self.reason = reason
        self.message = message
    }
}

extension Post {
    /// A copy with the viewer's vote changed: optimistic UI applies it
    /// before the server confirms.
    public func with(myVote: Int, score: Int) -> Post {
        Post(id: id, title: title, body: body, bodyTruncated: bodyTruncated, isNsfw: isNsfw,
             score: score, commentCount: commentCount, myVote: myVote, createdAt: createdAt,
             editedAt: editedAt, community: community, author: author, story: story)
    }

    /// A copy with another comment count: a comment was just posted.
    public func with(commentCount: Int) -> Post {
        Post(id: id, title: title, body: body, bodyTruncated: bodyTruncated, isNsfw: isNsfw,
             score: score, commentCount: commentCount, myVote: myVote, createdAt: createdAt,
             editedAt: editedAt, community: community, author: author, story: story)
    }

    /// The same post with the body and edit time of `other`: a feed's
    /// preview must not replace the full text a post screen loaded.
    func with(contentOf other: Post) -> Post {
        Post(id: id, title: title, body: other.body, bodyTruncated: other.bodyTruncated, isNsfw: isNsfw,
             score: score, commentCount: commentCount, myVote: myVote, createdAt: createdAt,
             editedAt: other.editedAt, community: community, author: author, story: story)
    }

    /// Merges a newer copy from the server, keeping a full body over a
    /// preview of the same edit.
    public func merged(with newer: Post) -> Post {
        if newer.bodyTruncated && !bodyTruncated && newer.editedAt == editedAt {
            return newer.with(contentOf: self)
        }
        return newer
    }
}

extension Community {
    /// A copy with the viewer's subscription changed: optimistic UI shows
    /// it before the server confirms.
    public func with(isSubscribed: Bool, subscribersCount: Int) -> Community {
        Community(id: id, slug: slug, title: title, description: description, isNsfw: isNsfw,
                  subscribersCount: subscribersCount, createdAt: createdAt, isSubscribed: isSubscribed,
                  viewerRole: viewerRole, rules: rules)
    }

    /// Merges a newer copy from the server: a list entry (no rules) keeps
    /// the rules a community page already loaded.
    public func merged(with newer: Community) -> Community {
        guard newer.rules == nil, let rules else { return newer }
        return Community(id: newer.id, slug: newer.slug, title: newer.title, description: newer.description,
                         isNsfw: newer.isNsfw, subscribersCount: newer.subscribersCount, createdAt: newer.createdAt,
                         isSubscribed: newer.isSubscribed, viewerRole: newer.viewerRole, rules: rules)
    }
}

extension Comment {
    public func with(myVote: Int, score: Int) -> Comment {
        Comment(id: id, postId: postId, parentId: parentId, depth: depth, body: body, isDeleted: isDeleted,
                author: author, score: score, myVote: myVote, replyCount: replyCount,
                createdAt: createdAt, editedAt: editedAt)
    }

    public func with(replyCount: Int) -> Comment {
        Comment(id: id, postId: postId, parentId: parentId, depth: depth, body: body, isDeleted: isDeleted,
                author: author, score: score, myVote: myVote, replyCount: replyCount,
                createdAt: createdAt, editedAt: editedAt)
    }
}
