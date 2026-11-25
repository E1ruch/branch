import Core
import DesignSystem
import Networking
import PhotosUI
import Stores
import SwiftUI

/// Изменить профиль, in the grouped style of the settings: the avatar on
/// top, then name, «О себе» and the username, each with a short note under
/// it. «Готово» saves and goes back.
public struct EditProfileScreen: View {
    @State private var model: EditProfileModel
    private let onSaved: (Me) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: Field?
    @State private var pickedAvatar: PhotosPickerItem?

    private enum Field { case name, bio, username }

    public init(model: EditProfileModel, onSaved: @escaping (Me) -> Void) {
        _model = State(initialValue: model)
        self.onSaved = onSaved
    }

    public var body: some View {
        List {
            avatarEditor

            Section {
                TextField("Имя", text: $model.displayName)
                    .textContentType(.name)
                    .focused($focus, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focus = .bio }
                    .groupedRow()
                    .accessibilityIdentifier("editProfile.name")
            } footer: {
                limitNote("Так вас видят в постах и комментариях. Можно по-русски.",
                          count: model.nameLength, max: EditProfileModel.maxDisplayName)
            }

            Section {
                TextField("О себе", text: $model.bio, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focus, equals: .bio)
                    .groupedRow()
                    .accessibilityIdentifier("editProfile.bio")
            } footer: {
                limitNote("Пара слов о себе: чем увлекаетесь, откуда вы.",
                          count: model.bioLength, max: EditProfileModel.maxBio)
            }

            Section {
                HStack(spacing: Spacing.xxs) {
                    Text("@").foregroundStyle(Color.vetkaSecondaryText)
                    TextField("ник", text: $model.username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .username)
                        .disabled(model.usernameLockedUntil != nil)
                        .accessibilityIdentifier("editProfile.username")
                }
                .groupedRow()
            } header: {
                Text("Ник")
            } footer: {
                usernameNote
                    .animation(.vetkaSnappy, value: model.usernameStatus)
            }

            if let error = model.error {
                Section {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.vetkaDanger)
                        .groupedRow()
                }
            }
        }
        .disabled(model.isSaving)
        .groupedListStyle()
        .scrollDismissesKeyboard(.interactively)
        .animation(.vetkaSnappy, value: model.error)
        .navigationTitle("Изменить профиль")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.vetkaBackground, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if model.isSaving {
                    ProgressView()
                } else {
                    Button("Готово") {
                        Task {
                            guard let me = await model.submit() else { return }
                            onSaved(me)
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .tint(.vetkaBrand)
                    .disabled(!model.canSave)
                    .accessibilityIdentifier("editProfile.done")
                }
            }
        }
        .task(id: model.username) { await model.checkUsername() }
        .task(id: pickedAvatar) {
            guard let pickedAvatar else { return }
            focus = nil
            await model.selectAvatar(pickedAvatar)
            if !Task.isCancelled { self.pickedAvatar = nil }
        }
    }

    private var avatarEditor: some View {
        let hasAvatar = model.hasAvatar
        return VStack(spacing: Spacing.s) {
            if let preview = model.avatarPreview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
            } else {
                AvatarView(name: model.username.isEmpty ? "?" : model.username, size: 96, imageURL: model.avatarURL)
            }
            if model.isPreparingAvatar {
                ProgressView().controlSize(.small)
            } else {
                HStack(spacing: Spacing.l) {
                    PhotosPicker(selection: $pickedAvatar, matching: .images, preferredItemEncoding: .current) {
                        Text(hasAvatar ? "Заменить фото" : "Добавить фото")
                    }
                    .foregroundStyle(Color.vetkaBrand)
                    .accessibilityIdentifier("editProfile.pickAvatar")
                    if hasAvatar {
                        Button("Удалить", role: .destructive, action: model.removeAvatar)
                            .foregroundStyle(Color.vetkaDanger)
                            .accessibilityIdentifier("editProfile.removeAvatar")
                    }
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: Spacing.s, leading: 0, bottom: 0, trailing: 0))
        .animation(.vetkaSnappy, value: model.username.first)
    }

    private func limitNote(_ text: String, count: Int, max: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
            Spacer(minLength: Spacing.s)
            // The count shows only near the limit, as Telegram does.
            if count > max * 3 / 4 {
                Text("\(max - count)")
                    .monospacedDigit()
                    .foregroundStyle(count > max ? Color.vetkaDanger : Color.vetkaSecondaryText)
                    .transition(.opacity)
            }
        }
        .animation(.vetkaSnappy, value: count > max * 3 / 4)
    }

    @ViewBuilder
    private var usernameNote: some View {
        if let until = model.usernameLockedUntil {
            Text("Ник можно менять раз в 30 дней. Следующий раз — \(until.formatted(.dateTime.day().month(.wide))).")
        } else {
            switch model.usernameStatus {
            case .current:
                Text("По нику вас находят и упоминают. Менять его можно раз в 30 дней.")
            case .checking:
                Text("Проверяем…")
            case .available:
                Label("Свободен", systemImage: "checkmark.circle.fill").foregroundStyle(Color.vetkaSuccess)
            case .taken:
                Label("Занят", systemImage: "xmark.circle.fill").foregroundStyle(Color.vetkaDanger)
            case let .invalid(message):
                Text(message).foregroundStyle(Color.vetkaDanger)
            case .unknown:
                Text("Не удалось проверить — проверим при сохранении")
            }
        }
    }
}
