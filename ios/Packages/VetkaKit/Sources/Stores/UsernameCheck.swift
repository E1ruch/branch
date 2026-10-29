import Core
import Networking
import Observation

/// What the live check under a username field says.
public enum UsernameStatus: Equatable, Sendable {
    /// The name the account already has: fine to keep.
    case current
    case checking
    case available
    case taken
    case invalid(String)
    /// The check itself failed (offline); saving will tell for sure.
    case unknown

    /// Whether a form may save with this name.
    public var allowsSaving: Bool {
        switch self {
        case .current, .available, .unknown: true
        case .checking, .taken, .invalid: false
        }
    }
}

/// The live check under a username field: the local rule at once, the
/// server after a typing pause. Onboarding and profile editing share it.
@MainActor
@Observable
public final class UsernameCheck {
    public typealias Check = @Sendable (_ name: String) async throws(APIError) -> UsernameAvailability

    public private(set) var status: UsernameStatus = .current

    @ObservationIgnored private let original: String
    @ObservationIgnored private let check: Check
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var latest = ""

    /// `debounce`: typing pause before asking the server, so a name typed
    /// in one go costs one request, not one per letter.
    public init(original: String, debounce: Duration = .milliseconds(350), check: @escaping Check) {
        self.original = original
        self.debounce = debounce
        self.check = check
    }

    public convenience init(original: String, client: APIClient) {
        self.init(original: original) { name throws(APIError) in
            try await client.send(API.usernameAvailability(name))
        }
    }

    /// Call from `.task(id: name)`: SwiftUI cancels it when the text
    /// changes again, which is the debounce.
    public func run(_ name: String) async {
        latest = name
        if name == original {
            status = .current
            return
        }
        guard UsernameRule.isValid(name) else {
            status = .invalid(UsernameRule.hint)
            return
        }
        status = .checking
        do {
            try await Task.sleep(for: debounce)
        } catch {
            return // cancelled: a newer name is being checked
        }
        do throws(APIError) {
            let result = try await check(name)
            guard name == latest else { return }
            switch (result.available, result.reason) {
            case (true, _): status = .available
            case (false, "taken"): status = .taken
            default: status = .invalid(result.message.map(Self.translate) ?? UsernameRule.hint)
            }
        } catch {
            if name == latest { status = .unknown }
        }
    }

    /// Saving found out the name was taken after all (a race).
    public func markTaken() {
        status = .taken
    }

    private static func translate(_ serverMessage: String) -> String {
        serverMessage == "this name is reserved" ? "Этот ник зарезервирован" : UsernameRule.hint
    }
}
