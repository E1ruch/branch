import Core
import Foundation
import Networking
import Observation

/// The signed-in state as the UI sees it.
@MainActor
@Observable
public final class SessionStore {
    public enum State: Equatable, Sendable {
        case signedOut
        case signedIn
    }

    public private(set) var state: State
    public private(set) var me: Me?
    /// Just signed up: the app asks for a username before anything else.
    public private(set) var needsOnboarding = false

    private let tokens: TokenStore
    private let client: APIClient

    /// `hasSavedSession` comes from the keychain read at launch, so the first
    /// frame already shows the right tabs instead of flashing a sign-in screen.
    public init(tokens: TokenStore, client: APIClient, hasSavedSession: Bool) {
        self.tokens = tokens
        self.client = client
        self.state = hasSavedSession ? .signedIn : .signedOut
    }

    /// Call once at launch: follows server-side session ends and loads the profile.
    public func start() async {
        Task { [weak self, tokens] in
            for await event in tokens.events where event == .ended {
                self?.didEnd()
            }
        }
        if state == .signedIn {
            await reloadMe()
        }
    }

    /// The auth feature calls this after a successful sign-in.
    public func didSignIn(_ session: AuthSession) async {
        await tokens.store(session.tokens)
        // Load the profile first: onboarding opens prefilled with the
        // current username, never with an empty field.
        await reloadMe()
        needsOnboarding = session.isNewUser
        state = .signedIn
    }

    /// Onboarding saved the profile (or was skipped, with nil).
    public func finishOnboarding(_ updated: Me?) {
        if let updated {
            me = updated
        }
        needsOnboarding = false
    }

    public func signOut() async {
        if let refresh = await tokens.refreshToken {
            // Best effort: revoke on the server, but never block signing out.
            _ = try? await client.send(API.logout(refresh))
        }
        await tokens.clear()
        didEnd()
    }

    public func reloadMe() async {
        do {
            me = try await client.send(API.me())
        } catch .unauthorized {
            didEnd()
        } catch {
            // Offline at launch: keep the session, the profile loads later.
        }
    }

    private func didEnd() {
        state = .signedOut
        me = nil
        needsOnboarding = false
    }
}
