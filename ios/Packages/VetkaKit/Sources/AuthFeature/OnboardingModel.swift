import Core
import DesignSystem
import Foundation
import Networking
import Observation
import Session
import Stores

/// Picks the first public username or offers to change a provider's suggestion.
@MainActor
@Observable
public final class OnboardingModel {
    public var username: String {
        didSet { error = nil }
    }
    public var displayName: String
    public var availability: UsernameStatus { usernameCheck.status(for: username) }
    public private(set) var isSaving = false
    public private(set) var isSigningOut = false
    public private(set) var error: String?
    public let isRequired: Bool

    private let original: String
    private let client: APIClient
    private let session: SessionStore
    private let usernameCheck: UsernameCheck

    public init(client: APIClient, session: SessionStore) {
        self.client = client
        self.session = session
        isRequired = session.requiresUsername
        original = isRequired ? "" : session.me?.username ?? ""
        username = original
        displayName = session.me?.displayName ?? ""
        usernameCheck = UsernameCheck(original: original, client: client)
    }

    var canSave: Bool {
        !isSaving && !isSigningOut && (isRequired ? availability == .available : availability.allowsSaving)
    }

    /// Runs from `.task(id: username)`: SwiftUI cancels it when the text
    /// changes again, which is the debounce.
    func checkAvailability() async {
        await usernameCheck.run(username)
    }

    /// Returns true when onboarding is done.
    func save() async -> Bool {
        guard canSave else { return false }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let me = try await client.send(API.updateMe(
                username: username == original ? nil : username,
                displayName: isRequired ? nil : displayName.trimmingCharacters(in: .whitespaces)))
            Haptics.success()
            session.finishOnboarding(me)
            return true
        } catch .cancelled {
            return false
        } catch {
            Haptics.error()
            if case .server(_, "username_taken", _, _) = error {
                usernameCheck.markTaken()
            } else {
                self.error = AuthErrorText.message(for: error, signingIn: false)
            }
            return false
        }
    }

    func skip() {
        guard !isRequired else { return }
        session.finishOnboarding(nil)
    }

    func signOut() async {
        guard !isSaving, !isSigningOut else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        await session.signOut()
    }
}
