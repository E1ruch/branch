import Core
import Foundation
import Networking
import Session

/// The composition root: every long-lived dependency is built here, once,
/// and handed down explicitly. No singletons, so previews and tests can build
/// their own.
@MainActor
public final class AppEnvironment {
    public let client: APIClient
    public let tokens: TokenStore
    public let session: SessionStore
    public let features = Features()
    let router = AppRouter()

    /// Switches for things that depend on how the app is signed or deployed.
    public struct Features: Sendable {
        /// Sign in with Apple needs a paid developer team: personal (free)
        /// teams cannot sign an app with its entitlement. To turn it on:
        /// set CODE_SIGN_ENTITLEMENTS = Config/Vetka.entitlements for the app
        /// target, pick the paid team in Signing, and flip this to true.
        public var signInWithApple = false
    }

    init(client: APIClient, tokens: TokenStore, session: SessionStore) {
        self.client = client
        self.tokens = tokens
        self.session = session
    }

    public static func live() -> AppEnvironment {
        let baseURL = apiBaseURL()
        let urlSession = APIClient.makeSession()

        // Refresh goes through a client without a token provider: it must
        // never try to refresh itself.
        let authless = APIClient(baseURL: baseURL, session: urlSession)
        let persistence = KeychainTokenPersistence()
        let hasSavedSession = persistence.load() != nil
        let tokens = TokenStore(persistence: persistence) { refreshToken throws(APIError) in
            try await authless.send(API.refresh(refreshToken))
        }

        let client = APIClient(baseURL: baseURL, session: urlSession, tokens: tokens)
        let session = SessionStore(tokens: tokens, client: client, hasSavedSession: hasSavedSession)
        return AppEnvironment(client: client, tokens: tokens, session: session)
    }

    /// VETKA_API_URL (set in the Xcode scheme) points a device at a Mac on
    /// the local network; the simulator reaches the Mac's localhost directly.
    private static func apiBaseURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["VETKA_API_URL"], let url = URL(string: override) {
            return url
        }
        #if DEBUG
        return URL(string: "http://localhost:8080")!
        #else
        return URL(string: "https://api.vetka.app")! // TODO: the real domain
        #endif
    }
}
