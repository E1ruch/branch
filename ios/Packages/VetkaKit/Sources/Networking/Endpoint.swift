import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
}

public enum AuthRequirement: Sendable {
    /// Never sends a token (sign-in, refresh).
    case none
    /// Sends a token when signed in: feeds then carry the viewer's votes.
    case optional
    /// Fails with .unauthorized without a session, before touching the network.
    case required
}

/// A request and the type of its response, so call sites cannot decode the
/// wrong thing: `let page = try await client.send(API.popularCommunities())`.
public struct Endpoint<Response: Decodable & Sendable>: Sendable {
    public var method: HTTPMethod
    public var path: String
    public var query: [URLQueryItem]
    public var body: (any Encodable & Sendable)?
    public var auth: AuthRequirement

    public init(_ method: HTTPMethod, _ path: String, query: [URLQueryItem] = [],
                body: (any Encodable & Sendable)? = nil, auth: AuthRequirement = .optional) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.auth = auth
    }
}

/// The response of endpoints that answer 204.
public struct NoContent: Decodable, Sendable {
    public init() {}
}
