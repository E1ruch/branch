import Foundation

/// A screen any feature can open. Features depend on this enum, never on
/// each other: the app shell maps a Route to its view.
public enum Route: Hashable, Sendable {
    case post(id: Int64)
    case community(slug: String)
    case user(username: String)
    /// "Продолжить ветку": the replies of a comment as their own screen.
    case commentThread(commentID: Int64)
}

extension Route {
    /// Hosts whose https links open in the app (universal links).
    /// TODO: the real domain once it exists.
    public static let universalLinkHosts: Set<String> = ["vetka.app"]

    /// A link to a post that opens in the app (or on the site) for anyone.
    public static func shareURL(postID: Int64) -> URL {
        URL(string: "https://\(universalLinkHosts.first!)/post/\(postID)")!
    }

    /// Parses deep links:
    ///   vetka://post/42, vetka://c/cats, vetka://u/ivan, vetka://comment/7
    ///   https://vetka.app/post/42 (and the same paths)
    /// Anything else (vetka://auth/telegram callbacks, unknown paths) is nil.
    public init?(url: URL) {
        let parts: [String]
        switch url.scheme?.lowercased() {
        case "vetka":
            parts = [url.host() ?? ""] + url.pathComponents.filter { $0 != "/" }
        case "https" where Route.universalLinkHosts.contains(url.host()?.lowercased() ?? ""):
            parts = url.pathComponents.filter { $0 != "/" }
        default:
            return nil
        }
        guard parts.count == 2, !parts[1].isEmpty else { return nil }

        switch parts[0] {
        case "post":
            guard let id = Int64(parts[1]), id > 0 else { return nil }
            self = .post(id: id)
        case "c":
            self = .community(slug: parts[1])
        case "u":
            self = .user(username: parts[1])
        case "comment":
            guard let id = Int64(parts[1]), id > 0 else { return nil }
            self = .commentThread(commentID: id)
        default:
            return nil
        }
    }
}
