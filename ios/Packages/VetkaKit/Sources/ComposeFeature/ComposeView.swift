import Core
import DesignSystem
import SwiftUI

/// The "+" sheet, in the spirit of Telegram's "new channel": the title in a
/// rounded field (up to three lines, with a clear button), the text in
/// another that styles markdown as it is typed. Formatting lives in the
/// edit menu of a selection, not on screen; the paperclip (coming soon) sits
/// by the length; the publish settings open from the subtitle under
/// "Новый пост". The draft saves itself, so closing loses nothing.
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
    @State private var isConfirmingClose = false

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
                    .padding(.top, Spacing.s)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                    .animation(.vetka, value: model.error)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Color.vetkaSurface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.vetkaSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена", action: close)
                        .foregroundStyle(Color.vetkaSecondaryText)
                }
                ToolbarItem(placement: .principal) {
                    navigationTitle
                }
                ToolbarItem(placement: .confirmationAction) {
                    publishButton
                }
            }
            .confirmationDialog("Сохранить черновик?", isPresented: $isConfirmingClose, titleVisibility: .visible) {
                Button("Сохранить черновик") {
                    model.saveNow()
                    dismiss()
                }
                Button("Удалить", role: .destructive) {
                    model.discard()
                    dismiss()
                }
                Button("Продолжить", role: .cancel) {}
            } message: {
                Text("Он откроется, когда вы снова нажмёте «+».")
            }
            .sheet(isPresented: $isShowingSettings) {
                PublishSettingsView(model: model, service: service)
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
        // Swiping the sheet down keeps the draft for next time.
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
            if model.isPublishing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
            }
        }
        .buttonStyle(PublishButtonStyle())
        .disabled(!model.isReadyExceptCommunity)
        .accessibilityLabel("Опубликовать")
        .accessibilityHint(model.missing ?? "")
        .accessibilityIdentifier("compose.publish")
    }

    // MARK: Attachments

    /// Photos and video are next: the menu says so.
    private var attachButton: some View {
        Menu {
            Section("Скоро") {
                Button("Фото", systemImage: "photo.on.rectangle") {}
                    .disabled(true)
                Button("Видео", systemImage: "video") {}
                    .disabled(true)
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(uiColor: Palette.iconPrimary))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(uiColor: Palette.surface)))
                .contentShape(Circle())
        }
        .accessibilityLabel("Прикрепить фото или видео")
    }

    private func openSettings() {
        hideKeyboard()
        isShowingSettings = true
    }

    private func hideKeyboard() {
        titleFocused = false
        bodyFocused = false
    }

    private func close() {
        if model.hasContent {
            isConfirmingClose = true
        } else {
            model.saveNow() // keeps a chosen community, drops nothing else
            dismiss()
        }
    }
}

/// The toolbar's publish button: a green circle with an arrow, like the
/// comment field's send. Token colors for enabled, pressed, disabled.
private struct PublishButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PublishButtonLabel(configuration: configuration)
    }

    private struct PublishButtonLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(Color(uiColor: Palette.buttonPrimaryText))
                .tint(Color(uiColor: Palette.buttonPrimaryText))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color(uiColor: !isEnabled ? Palette.buttonPrimaryDisabled
                    : configuration.isPressed ? Palette.buttonPrimaryPressed : Palette.buttonPrimary)))
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .animation(.vetkaSnappy, value: configuration.isPressed)
        }
    }
}
