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
    public private(set) var requiresUsername = false
    public var needsOnboarding: Bool { requiresUsername || offersProviderOnboarding }

    private var offersProviderOnboarding = false
    private var profileRevision = 0
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
        requiresUsername = session.user.username.isEmpty
        offersProviderOnboarding = session.isNewUser && !requiresUsername
        if !requiresUsername {
            await reloadMe()
        }
        guard await tokens.isSignedIn else { return }
        state = .signedIn
    }

    /// Onboarding saved the profile (or was skipped, with nil).
    public func finishOnboarding(_ updated: Me?) {
        if let updated {
            didUpdate(updated)
        }
        offersProviderOnboarding = false
    }

    /// The profile was edited and saved.
    public func didUpdate(_ updated: Me) {
        profileRevision += 1
        requiresUsername = updated.username.isEmpty
        me = updated
    }

    /// Deletes the account on the server, then ends the session here. On
    /// an error nothing changes and the caller shows it.
    public func deleteAccount() async throws(APIError) {
        _ = try await client.send(API.deleteMe())
        await tokens.clear()
        didEnd()
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
        let revision = profileRevision
        do {
            let profile = try await client.send(API.me())
            guard revision == profileRevision else { return }
            didUpdate(profile)
        } catch .unauthorized {
            if revision == profileRevision { didEnd() }
        } catch {
            // Offline at launch: keep the session, the profile loads later.
        }
    }

    private func didEnd() {
        profileRevision += 1
        state = .signedOut
        me = nil
        requiresUsername = false
        offersProviderOnboarding = false
    }
}
