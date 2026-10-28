import Core
import DesignSystem
import SwiftUI

/// "Настройки публикации": where the post goes and how. A half-height
/// sheet over the composer, so the text stays in sight behind it.
struct PublishSettingsView: View {
    @Bindable var model: ComposeModel
    let service: any ComposeService
    @Environment(\.dismiss) private var dismiss
    @State private var isPickingCommunity = false
    @State private var isPickingStory = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { isPickingCommunity = true } label: {
                        SettingsRow(icon: "square.grid.2x2", title: "Сообщество",
                                    value: model.draft.community?.title ?? "Выбрать",
                                    highlighted: model.draft.community == nil)
                    }
                    .accessibilityIdentifier("settings.community")
                } footer: {
                    if model.draft.community == nil {
                        Text("Без сообщества пост не опубликовать.")
                    }
                }

                Section {
                    Button { isPickingStory = true } label: {
                        SettingsRow(icon: "book.pages", title: "Продолжение истории",
                                    value: model.draft.continues.map { "Часть \($0.nextPart)" } ?? "Нет",
                                    highlighted: false)
                    }
                    if model.draft.continues != nil {
                        Button("Не продолжать историю", role: .destructive) {
                            withAnimation(.vetkaSnappy) { model.draft.continues = nil }
                            Haptics.selection()
                        }
                    }
                } footer: {
                    if let continues = model.draft.continues {
                        Text("Пост станет частью \(continues.nextPart) истории «\(continues.title)».")
                    } else {
                        Text("Сделайте пост следующей частью своей истории — читатели смогут листать её по частям.")
                    }
                }

                Section {
                    Toggle(isOn: Binding(get: { model.isNSFW }, set: { on in
                        model.draft.isNSFW = on
                        Haptics.selection()
                    })) {
                        Label {
                            Text("Только для взрослых")
                        } icon: {
                            SettingsIcon(symbol: "eye.slash", color: Palette.destructive)
                        }
                    }
                    .tint(Color(uiColor: Palette.destructive))
                    .disabled(model.nsfwIsForced)
                } footer: {
                    Text(model.nsfwIsForced
                         ? "Всё сообщество отмечено 18+, поэтому и пост тоже."
                         : "Пост не попадёт в общую ленту — его увидят в сообществе и по ссылке.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.vetkaBackground)
            .navigationTitle("Настройки публикации")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                        .fontWeight(.semibold)
                        .tint(.vetkaBrand)
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
            .animation(.vetkaSnappy, value: model.draft.continues)
            .animation(.vetkaSnappy, value: model.draft.community)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(20)
    }
}

/// A settings row: a tinted icon, the name, the current value, a chevron.
private struct SettingsRow: View {
    let icon: String
    let title: String
    let value: String
    let highlighted: Bool

    var body: some View {
        HStack(spacing: Spacing.m) {
            SettingsIcon(symbol: icon, color: Palette.accent)
            Text(title)
                .foregroundStyle(Color.vetkaTextPrimary)
            Spacer(minLength: Spacing.s)
            Text(value)
                .foregroundStyle(highlighted ? Color.vetkaBrand : Color.vetkaSecondaryText)
                .fontWeight(highlighted ? .semibold : .regular)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(uiColor: Palette.textTertiary))
        }
        .contentShape(Rectangle())
    }
}

private struct SettingsIcon: View {
    let symbol: String
    let color: UIColor

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color(uiColor: color))
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: color).opacity(0.12)))
    }
}
