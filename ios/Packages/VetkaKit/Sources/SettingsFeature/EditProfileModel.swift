import Core
import DesignSystem
import Foundation
import Networking
import Observation
import Stores

/// Изменить профиль: name, «О себе» and the username with its live check.
/// Only what changed goes to the server.
@MainActor
@Observable
public final class EditProfileModel {
    public typealias Save = @Sendable (_ username: String?, _ displayName: String?, _ bio: String?)
        async throws(APIError) -> Me

    public var displayName: String
    public var bio: String
    public var username: String
    public private(set) var isSaving = false
    public private(set) var error: String?
    public var usernameStatus: UsernameStatus { usernameCheck.status }

    /// The server's limits, counted the way it counts (code points).
    static let maxDisplayName = 48
    static let maxBio = 300

    @ObservationIgnored private let original: Me
    @ObservationIgnored private let usernameCheck: UsernameCheck
    @ObservationIgnored private let save: Save
    @ObservationIgnored private let now: () -> Date

    public init(me: Me, usernameCheck: UsernameCheck, now: @escaping () -> Date = Date.init, save: @escaping Save) {
        original = me
        self.usernameCheck = usernameCheck
        self.save = save
        self.now = now
        displayName = me.displayName ?? ""
        bio = me.bio ?? ""
        username = me.username
    }

    public convenience init(me: Me, client: APIClient) {
        self.init(me: me, usernameCheck: UsernameCheck(original: me.username, client: client)) { username, name, bio throws(APIError) in
            try await client.send(API.updateMe(username: username, displayName: name, bio: bio))
        }
    }

    /// Until when the username stays as it is (changed less than 30 days
    /// ago); nil when it can be changed now.
    var usernameLockedUntil: Date? {
        guard let date = original.usernameChangeableAt, date > now() else { return nil }
        return date
    }

    private var trimmedName: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedBio: String { bio.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameChanged: Bool { trimmedName != (original.displayName ?? "") }
    private var bioChanged: Bool { trimmedBio != (original.bio ?? "") }
    private var usernameChanged: Bool { username != original.username }

    var nameLength: Int { trimmedName.unicodeScalars.count }
    var bioLength: Int { trimmedBio.unicodeScalars.count }

    var hasChanges: Bool { nameChanged || bioChanged || usernameChanged }

    var canSave: Bool {
        hasChanges && !isSaving
            && nameLength <= Self.maxDisplayName && bioLength <= Self.maxBio
            && (!usernameChanged || usernameStatus.allowsSaving)
    }

    /// Runs from `.task(id: username)`, which is the debounce.
    func checkUsername() async {
        await usernameCheck.run(username)
    }

    /// The saved profile, or nil (the error is shown).
    func submit() async -> Me? {
        guard canSave else { return nil }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do throws(APIError) {
            // Empty clears a name or bio on the server.
            let me = try await save(usernameChanged ? username : nil,
                                    nameChanged ? trimmedName : nil,
                                    bioChanged ? trimmedBio : nil)
            Haptics.success()
            return me
        } catch {
            Haptics.error()
            if case .server(_, "username_taken", _, _) = error {
                usernameCheck.markTaken()
            }
            self.error = Self.message(for: error)
            return nil
        }
    }

    static func message(for error: APIError) -> String {
        switch error {
        case .server(_, "username_taken", _, _): "Этот ник уже занят"
        case .server(_, "username_change_too_soon", _, _): "Ник можно менять раз в 30 дней"
        case .server(_, "validation_failed", _, "username"): "Ник: \(UsernameRule.hint)"
        case .server(_, "validation_failed", _, _): "Слишком длинный текст"
        case .transport: "Нет соединения с сервером"
        default: "Не удалось сохранить. Попробуйте ещё раз."
        }
    }
}
