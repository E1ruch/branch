import Core
import DesignSystem
import Networking
import PhotosUI
import SwiftUI

struct CommunityMediaEditor: View {
    let community: Community
    let client: APIClient
    let onSaved: (Community) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var iconSelection: PhotosPickerItem?
    @State private var bannerSelection: PhotosPickerItem?
    @State private var changes: [Kind: Change] = [:]
    @State private var preparing: Kind?
    @State private var isSaving = false
    @State private var error: String?

    private enum Kind: String, CaseIterable {
        case icon, banner

        var title: String { self == .icon ? "Иконка" : "Обложка" }
        var apiField: String { rawValue + "_media_id" }
    }

    private struct Change {
        var jpeg: Data?
        var preview: CGImage?
        var mediaID: Int64?
    }

    var body: some View {
        NavigationStack {
            List {
                section(.icon, selection: $iconSelection)
                section(.banner, selection: $bannerSelection)
                if let error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.vetkaDanger)
                        .groupedRow()
                }
            }
            .groupedListStyle()
            .disabled(isSaving)
            .navigationTitle("Оформление сообщества")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .disabled(isSaving || preparing != nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Готово") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(changes.isEmpty || preparing != nil)
                            .accessibilityIdentifier("community.media.done")
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSaving || preparing != nil)
        .task(id: iconSelection) {
            guard let iconSelection else { return }
            await select(iconSelection, kind: .icon)
            if !Task.isCancelled { self.iconSelection = nil }
        }
        .task(id: bannerSelection) {
            guard let bannerSelection else { return }
            await select(bannerSelection, kind: .banner)
            if !Task.isCancelled { self.bannerSelection = nil }
        }
    }

    private func section(_ kind: Kind, selection: Binding<PhotosPickerItem?>) -> some View {
        let url = changes[kind]?.mediaID == 0 ? nil : originalURL(kind)
        let hasPhoto = url != nil || changes[kind]?.jpeg != nil
        return Section(kind.title) {
            Group {
                if kind == .icon {
                    if let preview = changes[kind]?.preview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 88, height: 88)
                            .clipShape(Circle())
                    } else {
                        AvatarView(name: community.title, size: 88, imageURL: url)
                    }
                } else {
                    Color.vetkaField
                        .overlay {
                            if let preview = changes[kind]?.preview {
                                Image(decorative: preview, scale: 1).resizable().scaledToFill()
                            } else if let url {
                                RemoteImage(url: url)
                            } else {
                                Image(systemName: "photo").foregroundStyle(Color.vetkaSecondaryText)
                            }
                        }
                        .frame(height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                }
            }
            .frame(maxWidth: .infinity)
            .groupedRow()
            .accessibilityHidden(true)

            if preparing == kind {
                ProgressView().controlSize(.small).groupedRow()
            } else {
                PhotosPicker(selection: selection, matching: .images, preferredItemEncoding: .current) {
                    Text(hasPhoto ? "Заменить фото" : "Добавить фото")
                        .foregroundStyle(Color.vetkaBrand)
                }
                .disabled(preparing != nil)
                .groupedRow()
                .accessibilityIdentifier("community.media.pick.\(kind.rawValue)")

                if hasPhoto {
                    Button("Удалить фото", role: .destructive) {
                        changes[kind] = originalURL(kind) == nil ? nil : Change(mediaID: 0)
                        error = nil
                    }
                    .disabled(preparing != nil)
                    .groupedRow()
                    .accessibilityIdentifier("community.media.remove.\(kind.rawValue)")
                }
            }
        }
    }

    private func originalURL(_ kind: Kind) -> URL? {
        kind == .icon ? community.iconUrl : community.bannerUrl
    }

    private func select(_ item: PhotosPickerItem, kind: Kind) async {
        guard preparing == nil, !isSaving else { return }
        preparing = kind
        error = nil
        defer { preparing = nil }
        do {
            let data = try await item.loadTransferable(type: Data.self)
            let jpeg = try await PhotoPreparation.shared.jpeg(from: data)
            let preview = await PhotoPreparation.shared.preview(from: jpeg, maxPixelSize: kind == .icon ? 320 : 1080)
            guard !Task.isCancelled else { return }
            changes[kind] = Change(jpeg: jpeg, preview: preview)
        } catch {
            if !Task.isCancelled { self.error = "Не удалось открыть фото. Выберите другое." }
        }
    }

    private func save() async {
        guard !isSaving, preparing == nil, !changes.isEmpty else { return }
        isSaving = true
        error = nil
        defer { isSaving = false }
        let uploader = MediaUploader(client: client)
        for kind in Kind.allCases {
            guard let change = changes[kind], let jpeg = change.jpeg, change.mediaID == nil else { continue }
            do {
                let id = try await uploader.upload(jpeg).id
                changes[kind]?.mediaID = id
            } catch {
                if error != .cancelled { self.error = "Не удалось загрузить фото. Попробуйте ещё раз." }
                return
            }
        }
        do {
            let updated = try await client.send(API.updateCommunityMedia(community.slug,
                                                                         iconMediaID: changes[.icon]?.mediaID,
                                                                         bannerMediaID: changes[.banner]?.mediaID))
            onSaved(updated)
            Haptics.success()
            dismiss()
        } catch {
            switch error {
            case .cancelled:
                return
            case .server(403, _, _, _):
                self.error = "Изменять оформление могут владельцы и модераторы."
            case let .server(_, "validation_failed", _, field):
                if let kind = Kind.allCases.first(where: { $0.apiField == field }), changes[kind]?.jpeg != nil {
                    changes[kind]?.mediaID = nil
                }
                self.error = "Не удалось сохранить фото. Попробуйте ещё раз."
            default:
                self.error = "Не удалось сохранить оформление. Попробуйте ещё раз."
            }
            Haptics.error()
        }
    }
}
