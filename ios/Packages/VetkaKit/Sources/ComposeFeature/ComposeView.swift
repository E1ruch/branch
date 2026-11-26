import Core
import DesignSystem
import Networking
import PhotosUI
import SwiftUI
import UIKit

/// The "+" sheet, in the spirit of Telegram's "new channel": the title in a
/// rounded field (up to three lines, with a clear button), the text in
/// another that styles markdown as it is typed. Formatting lives in the
/// edit menu of a selection, not on screen; the paperclip sits
/// by the length; the publish settings open from the subtitle under
/// "Новый пост". Saved drafts open from the navigation bar.
public struct ComposeView: View {
    @State private var model: ComposeModel
    private let service: any ComposeService
    private let onPublished: (Post) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var titleFocused: Bool
    /// The text is a UITextView: its focus is a plain binding.
    @State private var bodyFocused = false
    @State private var editor = MarkdownEditor()
    @State private var isShowingSettings = false
    @State private var isShowingDrafts = false
    @State private var isShowingScheduleNotice = false
    @State private var isConfirmingClose = false
    @State private var photoSelection: [PhotosPickerItem] = []

    public init(service: any ComposeService, storage: any DraftStorage, community: PickedCommunity? = nil,
                continues: ContinuedPost? = nil, onPublished: @escaping (Post) -> Void) {
        _model = State(initialValue: ComposeModel(service: service, storage: storage, community: community,
                                                  continues: continues))
        self.service = service
        self.onPublished = onPublished
    }

    public var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        titleField
                        bodyField
                        if !model.draft.photos.isEmpty {
                            photoStrip
                        }
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.vetkaSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена", action: close)
                        .foregroundStyle(Color.vetkaSecondaryText)
                        .disabled(model.isPublishing || model.isPreparingPhotos)
                }
                ToolbarItem(placement: .principal) {
                    navigationTitle
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
            .sheet(isPresented: $isShowingDrafts) {
                ComposeDraftsView(model: model)
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
            case .title: titleFocused = true
            case .body: bodyFocused = true
            case nil: break
            }
        }
        .task { titleFocused = true }
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

    // MARK: Title and text

    /// A rounded field like Telegram's channel name: up to three lines,
    /// then it scrolls inside; the cross clears it.
    private var titleField: some View {
        @Bindable var model = model
        let hasTitle = !model.draft.title.isEmpty
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return VStack(alignment: .trailing, spacing: Spacing.xs) {
            HStack(alignment: .top, spacing: Spacing.s) {
                TextField("Заголовок", text: $model.draft.title, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.vetkaTextPrimary)
                    .focused($titleFocused)
                    .submitLabel(.next)
                    // A hardware Return submits instead of typing a newline.
                    .onSubmit { editor.focus() }
                    .accessibilityIdentifier("compose.title")
                if hasTitle {
                    Button {
                        model.draft.title = ""
                        titleFocused = true
                        Haptics.selection()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Color(uiColor: Palette.textTertiary))
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                    .accessibilityLabel("Очистить заголовок")
                }
            }
            .padding(.leading, Spacing.m)
            .padding(.trailing, Spacing.s)
            .padding(.vertical, Spacing.m)
            .background(shape.fill(Color.vetkaField))
            .overlay(shape.strokeBorder(Color.vetkaBrand.opacity(titleFocused ? 0.45 : 0), lineWidth: 1.5))
            .contentShape(shape)
            .onTapGesture { titleFocused = true }

            if let remaining = model.titleRemaining {
                Text(remaining >= 0 ? "Осталось \(remaining)" : "Лишних \(-remaining)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(remaining >= 0 ? Color.vetkaSecondaryText : Color.vetkaDanger)
                    .padding(.trailing, Spacing.xs)
                    .transition(.opacity)
            }
        }
        .animation(.vetkaSnappy, value: hasTitle)
        .animation(.vetkaSnappy, value: titleFocused)
        .animation(.vetkaSnappy, value: model.titleRemaining == nil)
    }

    /// The text in a field of its own that grows with it. Its footer has
    /// the paperclip and the length.
    private var bodyField: some View {
        @Bindable var model = model
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        let tooLong = model.draft.body.count > ComposeModel.maxBody
        return VStack(alignment: .leading, spacing: 0) {
            MarkdownTextView(text: $model.draft.body, isFocused: $bodyFocused, editor: editor,
                             placeholder: "Текст поста", minHeight: 150)
            HStack(spacing: Spacing.s) {
                attachButton
                Spacer()
                Text(bodyLength)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(tooLong ? Color.vetkaDanger : Color.vetkaSecondaryText)
                    .contentTransition(.numericText())
                    .accessibilityLabel("\(model.draft.body.count) из \(ComposeModel.maxBody) символов")
            }
            .padding(.leading, Spacing.s)
            .padding(.trailing, Spacing.m)
            .padding(.bottom, Spacing.s)
            .contentShape(Rectangle())
            .onTapGesture { bodyFocused = true }
        }
        .background(shape.fill(Color.vetkaField))
        .overlay(shape.strokeBorder(Color.vetkaBrand.opacity(bodyFocused ? 0.45 : 0), lineWidth: 1.5))
        .animation(.vetkaSnappy, value: bodyFocused)
    }

    private var bodyLength: String {
        "\(model.draft.body.count.formatted()) / \(ComposeModel.maxBody.formatted())"
    }

    // MARK: Navigation bar

    /// "Новый пост" and, under it, where it goes: tap to change.
    private var navigationTitle: some View {
        Button(action: openSettings) {
            VStack(spacing: 1) {
                Text("Новый пост")
                    .font(.headline)
                    .foregroundStyle(Color.vetkaTextPrimary)
                HStack(spacing: 3) {
                    Text(settingsSummary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(model.draft.community == nil ? Color.vetkaBrand : Color.vetkaSecondaryText)
                .contentTransition(.opacity)
            }
            .frame(maxWidth: 220)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isPublishing)
        .animation(.vetkaSnappy, value: settingsSummary)
        .accessibilityLabel("Настройки публикации: \(settingsSummary)")
        .accessibilityIdentifier("compose.settingsSummary")
    }

    private var settingsSummary: String {
        var parts = [model.draft.community?.title ?? "Выберите сообщество"]
        if let continues = model.draft.continues { parts.append("Часть \(continues.nextPart)") }
        if model.isNSFW { parts.append("18+") }
        return parts.joined(separator: " · ")
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
            publishButton
                .frame(maxWidth: .infinity, alignment: .trailing)
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

    private var attachButton: some View {
        let isPreparing = model.isPreparingPhotos
        return PhotosPicker(selection: $photoSelection, maxSelectionCount: max(1, ComposeModel.maxPhotos - model.draft.photos.count),
                     selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .current) {
            Group {
                if isPreparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .foregroundStyle(Color(uiColor: Palette.iconPrimary))
            .frame(width: 32, height: 32)
            .background(Circle().fill(Color(uiColor: Palette.surface)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(model.draft.photos.count >= ComposeModel.maxPhotos || model.isPreparingPhotos)
        .accessibilityLabel("Прикрепить фото")
        .accessibilityHint("До \(ComposeModel.maxPhotos) фото")
        .accessibilityIdentifier("compose.attachPhotos")
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
                model.openSavedDraft(saved.id)
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
