import Core
import DesignSystem
import Foundation
import Networking
import Session
import Stores

/// The composition root: every long-lived dependency is built here, once,
/// and handed down explicitly. No singletons, so previews and tests can build
/// their own.
@MainActor
public final class AppEnvironment {
    public let client: APIClient
    public let tokens: TokenStore
    public let session: SessionStore
    /// Every post on screen, shared by feeds and post screens.
    public let posts: PostStore
    /// Every community on screen, shared by the search tab and community pages.
    public let communities: CommunityStore
    /// Every profile on screen, shared by profile pages (and your own tab).
    public let profiles: ProfileStore
    /// Light or dark, as picked in Оформление.
    public let theme = ThemeStore()
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
        posts = PostStore(client: client)
        communities = CommunityStore(client: client)
        profiles = ProfileStore(client: client)
        router.isSignedIn = { [weak session] in session?.state == .signedIn }
        posts.requestSignIn = { [weak router] in router?.isAuthPresented = true }
        communities.requestSignIn = { [weak router] in router?.isAuthPresented = true }
        communities.isSignedIn = { [weak session] in session?.state == .signedIn }
        profiles.requestSignIn = { [weak router] in router?.isAuthPresented = true }
        profiles.isSignedIn = { [weak session] in session?.state == .signedIn }
        profiles.myUsername = { [weak session] in session?.me?.username }
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

    /// Where the API is.
    ///
    /// The simulator reaches the Mac's localhost directly. A phone needs the
    /// Mac's address on the Wi-Fi: set VETKA_API_URL=http://<Mac IP>:8080 in
    /// the Xcode scheme (Run → Arguments → Environment Variables) and run once.
    /// Scheme variables only exist while Xcode launches the app, so a debug
    /// build remembers the value: later launches from the home screen keep
    /// talking to the same Mac.
    private static func apiBaseURL() -> URL {
        #if DEBUG
        let savedKey = "dev.apiBaseURL"
        let defaults = UserDefaults.standard
        if let value = ProcessInfo.processInfo.environment["VETKA_API_URL"], let url = URL(string: value) {
            defaults.set(value, forKey: savedKey)
            return url
        }
        if let value = defaults.string(forKey: savedKey), let url = URL(string: value) {
            return url
        }
        return URL(string: "http://localhost:8080")!
        #else
        return URL(string: "https://api.vetka.app")! // TODO: the real domain
        #endif
    }
}
