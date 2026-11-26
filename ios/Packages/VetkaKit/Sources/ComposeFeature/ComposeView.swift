import Core
import DesignSystem
import Networking
import PhotosUI
import SwiftUI
import UIKit

/// The "+" sheet. The editor shows formatting inline and keeps it in drafts as Markdown.
public struct ComposeView: View {
    @State private var model: ComposeModel
    private let service: any ComposeService
    private let author: Me?
    private let onPublished: (Post) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    /// The text is a UITextView: its focus is a plain binding.
    @State private var bodyFocused = false
    @State private var editor = MarkdownEditor()
    @State private var isShowingTitle = false
    @State private var isShowingSettings = false
    @State private var isPickingCommunity = false
    @State private var isShowingDrafts = false
    @State private var isShowingScheduleNotice = false
    @State private var isConfirmingClose = false
    @State private var photoSelection: [PhotosPickerItem] = []

    public init(service: any ComposeService, storage: any DraftStorage, author: Me? = nil, community: PickedCommunity? = nil,
                continues: ContinuedPost? = nil, onPublished: @escaping (Post) -> Void) {
        _model = State(initialValue: ComposeModel(service: service, storage: storage, community: community,
                                                  continues: continues))
        self.service = service
        self.author = author
        self.onPublished = onPublished
    }

    public var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        postEditor
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(Color.vetkaDanger)
                                .padding(.horizontal, Spacing.xs)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        // The rest of the screen: a tap here puts the keyboard away.
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: hideKeyboard)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, Spacing.l)
                    .disabled(model.isPublishing)
                    .padding(.top, Spacing.s)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                    .animation(.vetka, value: model.error)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                publishBar
            }
            .background(Color.vetkaSurface)
            .navigationTitle("Новый пост")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.vetkaSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена", action: close)
                        .foregroundStyle(Color.vetkaSecondaryText)
                        .disabled(model.isPublishing || model.isPreparingPhotos)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: openDrafts) {
                        Image(systemName: "doc.text")
                    }
                    .accessibilityLabel("Черновики")
                    .accessibilityIdentifier("compose.drafts")
                    .disabled(model.isPublishing || model.isPreparingPhotos)
                    moreMenu
                        .disabled(model.isPublishing || model.isPreparingPhotos)
                }
            }
            .alert("Сохранить пост в черновиках?", isPresented: $isConfirmingClose) {
                Button("Сохранить в черновиках") {
                    model.saveToDraftsAndClose()
                    dismiss()
                }
                Button("Не сохранять", role: .destructive) {
                    model.discard()
                    dismiss()
                }
                Button("Продолжить редактирование", role: .cancel) {}
            }
            .sheet(isPresented: $isShowingSettings) {
                PublishSettingsView(model: model, service: service)
            }
            .sheet(isPresented: $isPickingCommunity) {
                communityPicker
            }
            .sheet(isPresented: $isShowingDrafts) {
                ComposeDraftsView(model: model) { id in
                    model.openSavedDraft(id)
                    isShowingTitle = !model.draft.title.isEmpty
                }
            }
            .alert("Запланировать публикацию", isPresented: $isShowingScheduleNotice) {
                Button("Понятно", role: .cancel) {}
            } message: {
                Text("Отложенная публикация пока недоступна.")
            }
        }
        // A title has no line breaks: Return moves on to the text.
        .onChange(of: model.draft.title) { _, title in
            guard title.contains("\n") else { return }
            let movesOn = title.hasSuffix("\n")
            model.draft.title = title.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: movesOn ? .whitespaces : [])
            // The text view takes the keyboard; the title lets go by itself
            // and the text view's begin-editing sets bodyFocused.
            if movesOn {
                DispatchQueue.main.async { editor.focus() }
            }
        }
        .onChange(of: model.errorField) { _, field in
            switch field {
            case .title: showTitle()
            case .body: bodyFocused = true
            case nil: break
            }
        }
        .task { bodyFocused = true }
        .task(id: photoSelection) {
            guard !photoSelection.isEmpty else { return }
            hideKeyboard()
            await model.addPhotos(photoSelection)
            if !Task.isCancelled { photoSelection = [] }
        }
        .background(ComposeDismissalHandler(onAttempt: close))
        .interactiveDismissDisabled(model.hasContent || model.isPublishing || model.isPreparingPhotos)
        .onDisappear { model.saveNow() }
    }

    // MARK: Editor

    private var authorName: String {
        guard let name = author?.username, !name.isEmpty else { return "Вы" }
        return name
    }

    private var postEditor: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            AvatarView(name: authorName, size: 40, imageURL: author?.avatarUrl)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                authorRow
                if isShowingTitle {
                    titleField
                } else {
                    Button(action: showTitle) {
                        Text("Добавить заголовок")
                            .font(.subheadline)
                            .foregroundStyle(Color.vetkaSecondaryText)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("compose.addTitle")
                }
                bodyField
                if !model.draft.photos.isEmpty {
                    photoStrip
                }
                attachmentsBar
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var authorRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) {
                username
                communityButton
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 0) {
                username
                communityButton
            }
        }
        .frame(minHeight: 28, alignment: .leading)
    }

    private var username: some View {
        Text(authorName)
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.vetkaTextPrimary)
            .lineLimit(1)
            .accessibilityIdentifier("compose.author")
    }

    private var communityButton: some View {
        Button {
            hideKeyboard()
            isPickingCommunity = true
        } label: {
            HStack(spacing: Spacing.xxs) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                Text(model.draft.community?.title ?? "Выбрать сообщество")
                    .font(.subheadline)
                    .lineLimit(1)
            }
            .foregroundStyle(model.draft.community == nil ? Color.vetkaSecondaryText : Color.vetkaBrand)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Выбрать сообщество")
        .accessibilityValue(model.draft.community?.title ?? "")
        .accessibilityIdentifier("compose.community")
    }

    private var communityPicker: some View {
        NavigationStack {
            CommunityPickerView(service: service, selected: model.draft.community?.slug) { community in
                model.draft.community = community
                Haptics.selection()
                isPickingCommunity = false
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { isPickingCommunity = false }
                }
            }
        }
    }

    private var titleField: some View {
        @Bindable var model = model
        return VStack(alignment: .trailing, spacing: Spacing.xs) {
            HStack(alignment: .top, spacing: Spacing.s) {
                TextField("Заголовок (необязательно)", text: $model.draft.title, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.vetkaTextPrimary)
                    .focused($titleFocused)
                    .submitLabel(.next)
                    // A hardware Return submits instead of typing a newline.
                    .onSubmit { editor.focus() }
                    .accessibilityIdentifier("compose.title")
                Button {
                    model.draft.title = ""
                    isShowingTitle = false
                    editor.focus()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color.vetkaSecondaryText)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Убрать заголовок")
            }

            if let remaining = model.titleRemaining {
                Text(remaining >= 0 ? "Осталось \(remaining)" : "Лишних \(-remaining)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(remaining >= 0 ? Color.vetkaSecondaryText : Color.vetkaDanger)
                    .padding(.trailing, Spacing.xs)
                    .transition(.opacity)
            }
        }
        .animation(.vetkaSnappy, value: model.titleRemaining == nil)
    }

    private var bodyField: some View {
        @Bindable var model = model
        return MarkdownTextView(text: $model.draft.body, isFocused: $bodyFocused, editor: editor,
                                placeholder: "Что нового?", minHeight: 62)
    }

    private func showTitle() {
        isShowingTitle = true
        bodyFocused = false
        titleFocused = true
    }

    // MARK: Navigation bar

    private var settingsButton: some View {
        Button(action: openSettings) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.medium))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Настройки публикации")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let settingsSummary {
                        Text(settingsSummary)
                            .font(.caption)
                            .foregroundStyle(Color.vetkaSecondaryText)
                            .lineLimit(1)
                    }
                }
            }
            .foregroundStyle(Color.vetkaSecondaryText)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isPublishing)
        .accessibilityLabel("Настройки публикации")
        .accessibilityValue(settingsSummary ?? "")
        .accessibilityIdentifier("compose.settingsSummary")
    }

    private var settingsSummary: String? {
        var parts: [String] = []
        if let continues = model.draft.continues { parts.append("Часть \(continues.nextPart)") }
        if model.isNSFW { parts.append("18+") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var moreMenu: some View {
        Menu {
            Button {
                hideKeyboard()
                isShowingScheduleNotice = true
            } label: {
                Label("Запланировать…", systemImage: "clock")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Ещё")
        .accessibilityIdentifier("compose.more")
    }

    private var publishBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Spacing.s) {
                settingsButton
                Spacer(minLength: 0)
                publishButton
                    .layoutPriority(1)
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
        }
        .background(Color.vetkaSurface)
    }

    private var publishButton: some View {
        Button {
            // Everything but the community is there: ask where it goes.
            guard model.draft.community != nil else {
                Haptics.selection()
                openSettings()
                return
            }
            Task {
                hideKeyboard()
                if let post = await model.publish() {
                    onPublished(post)
                }
            }
        } label: {
            Text("Опубликовать")
                .frame(minHeight: 44)
                .opacity(model.isPublishing ? 0 : 1)
                .overlay {
                    if model.isPublishing { ProgressView().controlSize(.small) }
                }
        }
        .buttonStyle(.vetkaPrimary(fullWidth: false))
        .disabled(!model.isReadyExceptCommunity)
        .accessibilityLabel("Опубликовать")
        .accessibilityHint(model.missing ?? "")
        .accessibilityIdentifier("compose.publish")
    }

    // MARK: Attachments

    private var attachmentsBar: some View {
        HStack(spacing: 0) {
            attachButton
            attachmentPlaceholder("Стикеры", id: "compose.stickers") {
                Image(systemName: "face.smiling")
            }
            attachmentPlaceholder("GIF", id: "compose.gif") {
                Text("GIF")
                    .font(.caption2.weight(.heavy))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(lineWidth: 1.5))
            }
            attachmentPlaceholder("Ещё вложения", id: "compose.attachments.more") {
                Image(systemName: "ellipsis.circle")
            }
            if let remaining = model.bodyRemaining {
                Spacer(minLength: 0)
                Text(remaining.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(remaining < 0 ? Color.vetkaDanger : Color.vetkaSecondaryText)
                    .accessibilityLabel("\(model.draft.body.count) из \(ComposeModel.maxBody) символов")
            }
        }
    }

    private func attachmentPlaceholder<Icon: View>(_ label: String, id: String, @ViewBuilder icon: () -> Icon) -> some View {
        Button {} label: {
            icon().modifier(AttachmentIcon())
        }
        .buttonStyle(.plain)
        .disabled(true)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private var attachButton: some View {
        let isPreparing = model.isPreparingPhotos
        return PhotosPicker(selection: $photoSelection, maxSelectionCount: max(1, ComposeModel.maxPhotos - model.draft.photos.count),
                     selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
            Group {
                if isPreparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "photo")
                }
            }
            .modifier(AttachmentIcon())
        }
        .buttonStyle(.plain)
        .disabled(model.draft.photos.count >= ComposeModel.maxPhotos || model.isPreparingPhotos)
        .accessibilityLabel("Прикрепить фото")
        .accessibilityHint("До \(ComposeModel.maxPhotos) фото")
        .accessibilityIdentifier("compose.attachPhotos")
    }

    private struct AttachmentIcon: ViewModifier {
        @Environment(\.isEnabled) private var isEnabled

        func body(content: Content) -> some View {
            content
                .font(.title3)
                .foregroundStyle(Color(uiColor: Palette.iconSecondary).opacity(isEnabled ? 1 : 0.75))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
    }

    private var photoStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.s) {
                ForEach(model.draft.photos) { photo in
                    DraftPhotoThumbnail(photo: photo) { model.removePhoto(photo) }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private struct DraftPhotoThumbnail: View {
        let photo: DraftPhoto
        let remove: () -> Void
        @State private var preview: CGImage?

        var body: some View {
            ZStack(alignment: .topTrailing) {
                Color.vetkaField
                    .overlay {
                        if let preview {
                            Image(decorative: preview, scale: 1)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: "photo").foregroundStyle(Color.vetkaSecondaryText)
                        }
                    }
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card))
                    .accessibilityHidden(true)
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.7))
                        .font(.system(size: 20))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Удалить фото")
            }
            .task(id: photo.id) {
                preview = await PhotoPreparation.shared.preview(at: photo.url, maxPixelSize: 240)
            }
        }
    }

    private func openSettings() {
        hideKeyboard()
        isShowingSettings = true
    }

    private func openDrafts() {
        hideKeyboard()
        isShowingDrafts = true
    }

    private func hideKeyboard() {
        titleFocused = false
        bodyFocused = false
    }

    private func close() {
        guard !model.isPublishing, !model.isPreparingPhotos else { return }
        if model.hasContent {
            isConfirmingClose = true
        } else {
            model.discard()
            dismiss()
        }
    }
}

private struct ComposeDraftsView: View {
    let model: ComposeModel
    let onOpen: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draftToDelete: SavedDraft?

    var body: some View {
        NavigationStack {
            Group {
                if !model.savedDrafts.isEmpty {
                    List {
                        ForEach(model.savedDrafts) { saved in
                            draftRow(saved)
                        }
                    }
                    .scrollContentBackground(.hidden)
                } else {
                    ContentUnavailableView("Черновиков пока нет", systemImage: "doc.text")
                }
            }
            .background(Color.vetkaBackground)
            .navigationTitle("Черновики")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .alert("Удалить черновик?", isPresented: Binding(
                get: { draftToDelete != nil },
                set: { if !$0 { draftToDelete = nil } }
            ), presenting: draftToDelete) { saved in
                Button("Удалить", role: .destructive) { model.deleteSavedDraft(saved.id) }
                Button("Отмена", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func draftRow(_ saved: SavedDraft) -> some View {
        HStack(spacing: Spacing.s) {
            Button {
                onOpen(saved.id)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(draftTitle(saved.draft))
                        .font(.headline)
                        .foregroundStyle(Color.vetkaTextPrimary)
                        .lineLimit(2)
                    if let community = saved.draft.community {
                        Text(community.title)
                            .font(.subheadline)
                            .foregroundStyle(Color.vetkaSecondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("compose.drafts.open")

            Menu {
                Button(role: .destructive) { draftToDelete = saved } label: {
                    Label("Удалить", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Ещё")
            .accessibilityIdentifier("compose.drafts.menu")
        }
    }

    private func draftTitle(_ draft: Draft) -> String {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { return body }
        return "Пост с фото"
    }
}

/// Route an interactive sheet dismissal through the same choices as «Отмена».
private struct ComposeDismissalHandler: UIViewControllerRepresentable {
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onAttempt = onAttempt
        controller.observePresentation()
    }

    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var onAttempt: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            observePresentation()
        }

        func observePresentation() {
            var ancestor = parent
            while let controller = ancestor {
                if let presentation = controller.presentationController,
                   presentation.presentedViewController === controller {
                    presentation.delegate = self
                    return
                }
                ancestor = controller.parent
            }
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool { false }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            onAttempt?()
        }
    }
}
