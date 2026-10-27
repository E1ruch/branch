import Core
import DesignSystem
import Foundation
import Networking
import Observation
import Session

/// After a provider sign-up (Apple, later Telegram) the account has a
/// generated or borrowed username; onboarding lets the person pick theirs.
@MainActor
@Observable
public final class OnboardingModel {
    public enum Availability: Equatable {
        /// The name the account already has: fine to keep.
        case current
        case checking
        case available
        case taken
        case invalid(String)
        /// The check itself failed (offline); saving will tell for sure.
        case unknown
    }

    public var username: String
    public var displayName: String
    public private(set) var availability: Availability = .current
    public private(set) var isSaving = false
    public private(set) var error: String?

    private let original: String
    private let client: APIClient
    private let session: SessionStore

    /// Typing pause before asking the server, so a name typed in one go
    /// costs one request, not one per letter.
    static let debounce: Duration = .milliseconds(350)

    public init(client: APIClient, session: SessionStore) {
        self.client = client
        self.session = session
        original = session.me?.username ?? ""
        username = original
        displayName = session.me?.displayName ?? ""
    }

    var canSave: Bool {
        !isSaving && [.current, .available, .unknown].contains(availability)
    }

    /// Runs from `.task(id: username)`: SwiftUI cancels it when the text
    /// changes again, which is the debounce.
    func checkAvailability() async {
        let name = username
        if name == original {
            availability = .current
            return
        }
        guard UsernameRule.isValid(name) else {
            availability = .invalid(UsernameRule.hint)
            return
        }
        availability = .checking
        do {
            try await Task.sleep(for: Self.debounce)
        } catch {
            return // cancelled: a newer name is being checked
        }
        do {
            let result = try await client.send(API.usernameAvailability(name))
            guard name == username else { return }
            switch (result.available, result.reason) {
            case (true, _): availability = .available
            case (false, "taken"): availability = .taken
            default: availability = .invalid(result.message.map(Self.translate) ?? UsernameRule.hint)
            }
        } catch {
            if name == username { availability = .unknown }
        }
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
            if case .server(_, "username_taken", _, _) = error { availability = .taken }
            self.error = AuthErrorText.message(for: error, signingIn: false)
            return false
        }
    }

    func skip() {
        session.finishOnboarding(nil)
    }

    private static func translate(_ serverMessage: String) -> String {
        serverMessage == "this name is reserved" ? "Этот ник зарезервирован" : UsernameRule.hint
    }
}
