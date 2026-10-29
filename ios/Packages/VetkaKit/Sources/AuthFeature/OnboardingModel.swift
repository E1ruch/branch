import Core
import DesignSystem
import Foundation
import Networking
import Observation
import Session
import Stores

/// After a provider sign-up (Apple, later Telegram) the account has a
/// generated or borrowed username; onboarding lets the person pick theirs.
@MainActor
@Observable
public final class OnboardingModel {
    public var username: String
    public var displayName: String
    public var availability: UsernameStatus { usernameCheck.status }
    public private(set) var isSaving = false
    public private(set) var error: String?

    private let original: String
    private let client: APIClient
    private let session: SessionStore
    private let usernameCheck: UsernameCheck

    public init(client: APIClient, session: SessionStore) {
        self.client = client
        self.session = session
        original = session.me?.username ?? ""
        username = original
        displayName = session.me?.displayName ?? ""
        usernameCheck = UsernameCheck(original: original, client: client)
    }

    var canSave: Bool {
        !isSaving && availability.allowsSaving
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
                displayName: displayName.trimmingCharacters(in: .whitespaces)))
            Haptics.success()
            session.finishOnboarding(me)
            return true
        } catch {
            Haptics.error()
            if case .server(_, "username_taken", _, _) = error { usernameCheck.markTaken() }
            self.error = AuthErrorText.message(for: error, signingIn: false)
            return false
        }
    }

    func skip() {
        session.finishOnboarding(nil)
    }
}
