import Core
import DesignSystem
import SwiftUI

/// The "+" sheet. Top to bottom: a title, the text in its own field with
/// its length under it, media (coming soon). Where the post goes (community,
/// story, 18+) is a row of chips riding on the keyboard, in reach while
/// typing. The draft saves itself, so closing the sheet or the app loses
/// nothing.
public struct ComposeView: View {
    @State private var model: ComposeModel
    private let service: any ComposeService
    private let onPublished: (Post) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: ComposeModel.Field?
    @State private var isPickingCommunity = false
    @State private var isPickingStory = false
    @State private var isConfirmingClose = false
    /// A tap on the media tile: say it is coming instead of doing nothing.
    @State private var mediaNudge = false

    public init(service: any ComposeService, storage: any DraftStorage, community: PickedCommunity? = nil,
                continues: ContinuedPost? = nil, onPublished: @escaping (Post) -> Void) {
        _model = State(initialValue: ComposeModel(service: service, storage: storage, community: community,
                                                  continues: continues))
        self.service = service
        self.onPublished = onPublished
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    titleField
                    bodyField
                    mediaSection
                }
                .padding(.horizontal, Spacing.l)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.vetkaSurface)
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .navigationTitle("Новый пост")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.vetkaSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена", action: close)
                        .foregroundStyle(Color.vetkaSecondaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    publishButton
                }
            }
            .navigationDestination(isPresented: $isPickingCommunity) {
                CommunityPickerView(service: service, selected: model.draft.community?.slug) { picked in
                    model.draft.community = picked
                    isPickingCommunity = false
                    Haptics.selection()
                }
            }
            .navigationDestination(isPresented: $isPickingStory) {
                StoryPickerView(service: service, selected: model.draft.continues?.postID) { post in
                    model.continueStory(of: post)
                    isPickingStory = false
                    Haptics.selection()
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
        }
        // A title is one line: Return moves on to the text instead.
        .onChange(of: model.draft.title) { _, title in
            guard title.contains("\n") else { return }
            let movesOn = title.hasSuffix("\n")
            model.draft.title = title.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: movesOn ? .whitespaces : [])
            if movesOn { focus = .body }
        }
        .onChange(of: model.errorField) { _, field in
            if let field { focus = field }
        }
        .task { focus = .title }
        // Swiping the sheet down keeps the draft for next time.
        .onDisappear { model.saveNow() }
    }

    // MARK: Fields

    private var titleField: some View {
        @Bindable var model = model
        return VStack(alignment: .trailing, spacing: Spacing.xxs) {
            TextField("Заголовок", text: $model.draft.title, axis: .vertical)
                .font(.title2.weight(.bold))
                .foregroundStyle(Color.vetkaTextPrimary)
                .focused($focus, equals: .title)
                .submitLabel(.next)
                .padding(.vertical, Spacing.s)
                .accessibilityIdentifier("compose.title")
            if let remaining = model.titleRemaining {
                Text(remaining >= 0 ? "Осталось \(remaining)" : "Лишних \(-remaining)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(remaining >= 0 ? Color.vetkaSecondaryText : Color.vetkaDanger)
                    .transition(.opacity)
            }
        }
        .animation(.vetkaSnappy, value: model.titleRemaining == nil)
    }

    /// The text in a field of its own. It grows with the text; a tap
    /// anywhere on it puts the cursor in. The footer shows the length now
    /// and gets the markdown buttons later.
    private var bodyField: some View {
        @Bindable var model = model
        let isFocused = focus == .body
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            TextField("Текст поста", text: $model.draft.body, axis: .vertical)
                .font(.body)
                .lineSpacing(3)
                .foregroundStyle(Color.vetkaTextPrimary)
                .focused($focus, equals: .body)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.m)
                .accessibilityIdentifier("compose.body")
            HStack {
                Spacer()
                Text(bodyLength)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.draft.body.count > ComposeModel.maxBody ? Color.vetkaDanger : Color.vetkaSecondaryText)
                    .contentTransition(.numericText())
                    .accessibilityLabel("\(model.draft.body.count) из \(ComposeModel.maxBody) символов")
            }
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.s)
        }
        .background(shape.fill(Color.vetkaField))
        .overlay(shape.strokeBorder(Color.vetkaBrand.opacity(isFocused ? 0.45 : 0), lineWidth: 1.5))
        .contentShape(shape)
        .onTapGesture { focus = .body }
        .animation(.vetkaSnappy, value: isFocused)
    }

    private var bodyLength: String {
        "\(model.draft.body.count.formatted()) / \(ComposeModel.maxBody.formatted())"
    }

    /// Photos and video are not there yet: the tile says so when tapped.
    private var mediaSection: some View {
        HStack(spacing: Spacing.m) {
            Button {
                Haptics.selection()
                withAnimation(.vetka) { mediaNudge = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation(.vetka) { mediaNudge = false }
                }
            } label: {
                VStack(spacing: Spacing.xs) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 22, weight: .medium))
                    Text("Фото")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(Color(uiColor: Palette.chipActiveText))
                .frame(width: 72, height: 72)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.vetkaBrandLight))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.vetkaBrand.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .scaleEffect(mediaNudge ? 0.96 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Добавить фото")
            .accessibilityHint("Скоро")

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Фото и видео")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.vetkaTextPrimary)
                Text(mediaNudge ? "Уже делаем — появится в следующих версиях" : "Скоро можно будет прикреплять")
                    .font(.footnote)
                    .foregroundStyle(Color.vetkaSecondaryText)
                    .contentTransition(.opacity)
            }
            .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Where the post goes

    /// Rides on the keyboard: the error, if any, then the chips.
    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.vetkaDanger)
                    .padding(.horizontal, Spacing.l)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.s) {
                    communityChip
                    storyChip
                    nsfwChip
                }
                .padding(.horizontal, Spacing.l)
            }
        }
        .padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .top) {
            Color.vetkaSurface
                .overlay(alignment: .top) {
                    Rectangle().fill(Color(uiColor: Palette.border)).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        }
        .animation(.vetka, value: model.error)
        .animation(.vetkaSnappy, value: model.draft.community)
        .animation(.vetkaSnappy, value: model.draft.continues)
        .animation(.vetkaSnappy, value: model.isNSFW)
    }

    /// Green until chosen: publishing waits for it.
    private var communityChip: some View {
        Button {
            focus = nil
            isPickingCommunity = true
        } label: {
            if let community = model.draft.community {
                ComposeChip(style: .plain) {
                    AvatarView(name: community.title, size: 22)
                    Text(community.title)
                        .foregroundStyle(Color.vetkaTextPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                        .fixedSize(horizontal: true, vertical: false)
                    chevron
                }
            } else {
                ComposeChip(style: .accent) {
                    Image(systemName: "square.grid.2x2")
                    Text("Сообщество")
                    chevron
                }
            }
        }
        .buttonStyle(ChipPressStyle())
        .accessibilityLabel(model.draft.community.map { "Сообщество: \($0.title)" } ?? "Выберите сообщество")
        .accessibilityIdentifier("compose.community")
    }

    @ViewBuilder
    private var storyChip: some View {
        if let continues = model.draft.continues {
            ComposeChip(style: .accent) {
                Button {
                    focus = nil
                    isPickingStory = true
                } label: {
                    HStack(spacing: Spacing.xs + 2) {
                        Image(systemName: "book.pages")
                        Text("Часть \(continues.nextPart)")
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Продолжение истории «\(continues.title)», часть \(continues.nextPart)")
                Button {
                    model.draft.continues = nil
                    Haptics.selection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color(uiColor: Palette.chipActiveText).opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Не продолжать историю")
            }
        } else {
            Button {
                focus = nil
                isPickingStory = true
            } label: {
                ComposeChip(style: .plain) {
                    Image(systemName: "book.pages")
                    Text("История")
                }
            }
            .buttonStyle(ChipPressStyle())
            .accessibilityHint("Сделать пост следующей частью вашей истории")
            .accessibilityIdentifier("compose.story")
        }
    }

    /// Locked on in an 18+ community.
    private var nsfwChip: some View {
        Button {
            model.draft.isNSFW.toggle()
            Haptics.selection()
        } label: {
            ComposeChip(style: model.isNSFW ? .danger : .plain) {
                if model.nsfwIsForced {
                    Image(systemName: "lock.fill")
                }
                Text("18+")
            }
        }
        .buttonStyle(ChipPressStyle())
        .disabled(model.nsfwIsForced)
        .accessibilityLabel(model.nsfwIsForced ? "Только для взрослых: всё сообщество 18+" : "Только для взрослых")
        .accessibilityValue(model.isNSFW ? "Включено" : "Выключено")
    }

    private var chevron: some View {
        Image(systemName: "chevron.down")
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.vetkaSecondaryText)
    }

    private var publishButton: some View {
        Button {
            Task {
                focus = nil
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
        .disabled(!model.canPublish)
        .accessibilityLabel("Опубликовать")
        .accessibilityHint(model.missing ?? "")
        .accessibilityIdentifier("compose.publish")
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

/// A capsule in the bottom row: one height, one font, three looks.
private struct ComposeChip<Content: View>: View {
    enum Style { case plain, accent, danger }

    let style: Style
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Spacing.xs + 2) { content }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, Spacing.m)
            .frame(height: 34)
            .background(Capsule().fill(background))
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch style {
        case .plain: Color(uiColor: Palette.chipInactiveText)
        case .accent: Color(uiColor: Palette.chipActiveText)
        case .danger: Color(uiColor: Palette.voteDown)
        }
    }

    private var background: Color {
        switch style {
        case .plain: Color(uiColor: Palette.chipInactiveBackground)
        case .accent: Color(uiColor: Palette.chipActiveBackground)
        case .danger: Color(uiColor: Palette.voteDownSoft)
        }
    }
}

/// A chip gives a little when pressed.
private struct ChipPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.vetkaSnappy, value: configuration.isPressed)
    }
}
