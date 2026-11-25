import Core
import DesignSystem
import Foundation
import Networking
import Observation
import PhotosUI
import Stores
import SwiftUI

/// Изменить профиль: name, «О себе» and the username with its live check.
/// Only what changed goes to the server.
@MainActor
@Observable
public final class EditProfileModel {
    public typealias Save = @Sendable (_ username: String?, _ displayName: String?, _ bio: String?, _ avatarID: Int64?)
        async throws(APIError) -> Me

    public var displayName: String
    public var bio: String
    public var username: String
    public private(set) var isSaving = false
    public private(set) var error: String?
    private(set) var isPreparingAvatar = false
    private(set) var avatarPreview: CGImage?
    public var usernameStatus: UsernameStatus { usernameCheck.status(for: username) }

    /// The server's limits, counted the way it counts (code points).
    static let maxDisplayName = 48
    static let maxBio = 300

    @ObservationIgnored private let original: Me
    @ObservationIgnored private let usernameCheck: UsernameCheck
    @ObservationIgnored private let save: Save
    @ObservationIgnored private let uploader: MediaUploader?
    @ObservationIgnored private let now: () -> Date
    private var avatarJPEG: Data?
    private var avatarMediaID: Int64?

    public init(me: Me, usernameCheck: UsernameCheck, now: @escaping () -> Date = Date.init,
                uploader: MediaUploader? = nil, save: @escaping Save) {
        original = me
        self.usernameCheck = usernameCheck
        self.save = save
        self.uploader = uploader
        self.now = now
        displayName = me.displayName ?? ""
        bio = me.bio ?? ""
        username = me.username
    }

    public convenience init(me: Me, client: APIClient) {
        self.init(me: me, usernameCheck: UsernameCheck(original: me.username, client: client),
                  uploader: MediaUploader(client: client)) { username, name, bio, avatarID throws(APIError) in
            try await client.send(API.updateMe(username: username, displayName: name, bio: bio, avatarMediaID: avatarID))
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

    var avatarURL: URL? { avatarMediaID == 0 ? nil : original.avatarUrl }
    var hasAvatar: Bool { avatarJPEG != nil || avatarURL != nil }

    var hasChanges: Bool { nameChanged || bioChanged || usernameChanged || avatarJPEG != nil || avatarMediaID == 0 }

    var canSave: Bool {
        hasChanges && !isSaving && !isPreparingAvatar
            && nameLength <= Self.maxDisplayName && bioLength <= Self.maxBio
            && (!usernameChanged || usernameStatus.allowsSaving)
    }

    /// Runs from `.task(id: username)`, which is the debounce.
    func checkUsername() async {
        await usernameCheck.run(username)
    }

    func selectAvatar(_ item: PhotosPickerItem) async {
        guard !isSaving, !isPreparingAvatar else { return }
        isPreparingAvatar = true
        error = nil
        defer { isPreparingAvatar = false }
        do {
            let data = try await item.loadTransferable(type: Data.self)
            let jpeg = try await PhotoPreparation.shared.jpeg(from: data)
            let preview = await PhotoPreparation.shared.preview(from: jpeg, maxPixelSize: 320)
            guard !Task.isCancelled else { return }
            avatarJPEG = jpeg
            avatarPreview = preview
            avatarMediaID = nil
        } catch {
            if !Task.isCancelled { self.error = "Не удалось открыть фото. Выберите другое." }
        }
    }

    func removeAvatar() {
        guard !isSaving, !isPreparingAvatar else { return }
        avatarJPEG = nil
        avatarPreview = nil
        avatarMediaID = original.avatarUrl == nil ? nil : 0
        error = nil
    }

    /// The saved profile, or nil (the error is shown).
    func submit() async -> Me? {
        guard canSave else { return nil }
        isSaving = true
        error = nil
        defer { isSaving = false }
        if let avatarJPEG, avatarMediaID == nil {
            do throws(APIError) {
                guard let uploader else { throw .unexpectedStatus(0) }
                avatarMediaID = try await uploader.upload(avatarJPEG).id
            } catch {
                if error != .cancelled { self.error = "Не удалось загрузить фото. Попробуйте ещё раз." }
                return nil
            }
        }
        do throws(APIError) {
            // Empty clears a name or bio on the server.
            let me = try await save(usernameChanged ? username : nil,
                                    nameChanged ? trimmedName : nil,
                                    bioChanged ? trimmedBio : nil,
                                    avatarMediaID)
            Haptics.success()
            return me
        } catch {
            if error == .cancelled { return nil }
            Haptics.error()
            if case .server(_, "username_taken", _, _) = error {
                usernameCheck.markTaken()
            }
            if case .server(_, "validation_failed", _, "avatar_media_id") = error, avatarJPEG != nil {
                avatarMediaID = nil
            }
            self.error = Self.message(for: error)
            return nil
        }
    }

    static func message(for error: APIError) -> String {
        switch error {
        case .server(_, "username_taken", _, _): "Этот ник уже занят"
        case .server(_, "username_change_too_soon", _, _): "Ник можно менять раз в 30 дней"
        case .server(_, "validation_failed", let message, "username"): UsernameRule.validationMessage(message)
        case .server(_, "validation_failed", _, "avatar_media_id"): "Не удалось сохранить фото. Попробуйте ещё раз."
        case .server(_, "validation_failed", _, _): "Слишком длинный текст"
        case .transport: "Нет соединения с сервером"
        default: "Не удалось сохранить. Попробуйте ещё раз."
        }
    }
}
