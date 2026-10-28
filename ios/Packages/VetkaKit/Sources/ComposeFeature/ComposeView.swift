import Core
import DesignSystem
import SwiftUI

/// The "+" sheet: where to post, a title, an optional text. The draft saves
/// itself as the user types, so closing the sheet or the app loses nothing.
public struct ComposeView: View {
    @State private var model: ComposeModel
    private let service: any ComposeService
    private let onPublished: (Post) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focus: ComposeModel.Field?
    @State private var isPickingCommunity = false
    @State private var isPickingStory = false
    @State private var isConfirmingClose = false

    public init(service: any ComposeService, storage: any DraftStorage, community: PickedCommunity? = nil,
                continues: ContinuedPost? = nil, onPublished: @escaping (Post) -> Void) {
        _model = State(initialValue: ComposeModel(service: service, storage: storage, community: community,
                                                  continues: continues))
        self.service = service
        self.onPublished = onPublished
    }

    public var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        communityButton
                        storyButton
                    }
                    .padding(.horizontal, Spacing.l)
                    .padding(.top, Spacing.m)
                    .padding(.bottom, Spacing.s)

                    TextField("Заголовок", text: $model.draft.title, axis: .vertical)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Color.vetkaTextPrimary)
                        .focused($focus, equals: .title)
                        .submitLabel(.next)
                        .padding(.horizontal, Spacing.l)
                        .padding(.vertical, Spacing.m)
                        .accessibilityIdentifier("compose.title")
                    counter(model.titleRemaining)

                    Rectangle()
                        .fill(Color(uiColor: Palette.borderSubtle))
                        .frame(height: 1)
                        .padding(.horizontal, Spacing.l)

                    TextField("Текст поста (необязательно)", text: $model.draft.body, axis: .vertical)
                        .font(.body)
                        .foregroundStyle(Color.vetkaTextPrimary)
                        .focused($focus, equals: .body)
                        .padding(.horizontal, Spacing.l)
                        .padding(.vertical, Spacing.m)
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .onTapGesture { focus = .body }
                        .accessibilityIdentifier("compose.body")
                    counter(model.bodyRemaining)
                }
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

    private var communityButton: some View {
        Button {
            focus = nil
            isPickingCommunity = true
        } label: {
            HStack(spacing: Spacing.s) {
                if let community = model.draft.community {
                    AvatarView(name: community.title, size: 26)
                    Text(community.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.vetkaTextPrimary)
                        .lineLimit(1)
                } else {
                    Image(systemName: "square.grid.2x2")
                        .font(.subheadline.weight(.semibold))
                    Text("Выберите сообщество")
                        .font(.subheadline.weight(.semibold))
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.vetkaSecondaryText)
            }
            .foregroundStyle(Color(uiColor: Palette.chipActiveText))
            .padding(.leading, model.draft.community == nil ? Spacing.m : Spacing.xs)
            .padding(.trailing, Spacing.m)
            .padding(.vertical, Spacing.xs + 1)
            .frame(minHeight: 36)
            .background(Capsule().fill(Color(uiColor: model.draft.community == nil
                    ? Palette.chipActiveBackground : Palette.chipInactiveBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.draft.community.map { "Сообщество: \($0.title)" } ?? "Выберите сообщество")
        .accessibilityIdentifier("compose.community")
    }

    /// "Часть 3 · «Ремонт Нивы»" with a cross, or an offer to continue one
    /// of the user's stories.
    @ViewBuilder
    private var storyButton: some View {
        if let continues = model.draft.continues {
            HStack(spacing: Spacing.s) {
                Button {
                    focus = nil
                    isPickingStory = true
                } label: {
                    Label {
                        Text("Часть \(continues.nextPart) · «\(continues.title)»")
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "book.pages")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(uiColor: Palette.chipActiveText))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Продолжение истории «\(continues.title)», часть \(continues.nextPart)")
                Button {
                    model.draft.continues = nil
                    Haptics.selection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.vetkaSecondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Не продолжать историю")
            }
            .padding(.horizontal, Spacing.m)
            .frame(minHeight: 36)
            .background(Capsule().fill(Color(uiColor: Palette.chipActiveBackground)))
        } else {
            Button {
                focus = nil
                isPickingStory = true
            } label: {
                Label("Продолжение истории", systemImage: "book.pages")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(uiColor: Palette.chipInactiveText))
                    .padding(.horizontal, Spacing.m)
                    .frame(minHeight: 36)
                    .background(Capsule().fill(Color(uiColor: Palette.chipInactiveBackground)))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Сделать пост следующей частью вашей истории")
            .accessibilityIdentifier("compose.story")
        }
    }

    @ViewBuilder
    private func counter(_ remaining: Int?) -> some View {
        if let remaining {
            Text(remaining >= 0 ? "Осталось \(remaining)" : "Лишних \(-remaining)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(remaining >= 0 ? Color.vetkaSecondaryText : Color.vetkaDanger)
                .padding(.horizontal, Spacing.l)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
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

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.vetkaDanger)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack {
                Button {
                    model.draft.isNSFW.toggle()
                    Haptics.selection()
                } label: {
                    Label("18+", systemImage: model.isNSFW ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(uiColor: model.isNSFW ? Palette.destructive : Palette.chipInactiveText))
                        .padding(.horizontal, Spacing.m)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color(uiColor: Palette.chipInactiveBackground)))
                }
                .buttonStyle(.plain)
                .disabled(model.nsfwIsForced)
                .accessibilityLabel("Только для взрослых")
                .accessibilityValue(model.isNSFW ? "Включено" : "Выключено")
                if model.nsfwIsForced {
                    Text("Всё сообщество 18+")
                        .font(.caption)
                        .foregroundStyle(Color.vetkaSecondaryText)
                }
                Spacer()
            }
        }
        .padding(.horizontal, Spacing.l)
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
