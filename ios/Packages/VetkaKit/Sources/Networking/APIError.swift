import Foundation

public enum APIError: Error, Sendable, Equatable {
    /// The backend's error envelope {"error": {"code", "message", "field"}}.
    /// `code` is stable and drives the UI; `message` is for developers.
    case server(status: Int, code: String, message: String, field: String?)
    /// No session, or the session ended (refresh rejected). Show sign-in.
    case unauthorized
    /// Offline, timeout, DNS: worth a retry, never a sign-out.
    case transport(URLError.Code)
    /// The request was cancelled (a cell scrolled away). Not an error to show.
    case cancelled
    case decoding(String)
    case unexpectedStatus(Int)

    /// The backend error code, if this is one.
    public var code: String? {
        if case let .server(_, code, _, _) = self { return code }
        return nil
    }

    public var isRetryable: Bool {
        switch self {
        case .transport: true
        case let .server(status, _, _, _): status >= 500 || status == 429
        default: false
        }
    }
}

struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String
        let field: String?
    }
    let error: Body
}
