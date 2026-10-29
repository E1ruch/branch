import Core
import DesignSystem
import SwiftUI

/// Where to post: the user's subscriptions on top, popular communities
/// below, search across all of them.
struct CommunityPickerView: View {
    @State private var model: CommunityPickerModel
    private let selected: String?
    private let onPick: (PickedCommunity) -> Void
    @FocusState private var searchFocused: Bool

    init(service: any ComposeService, selected: String?, onPick: @escaping (PickedCommunity) -> Void) {
        _model = State(initialValue: CommunityPickerModel(service: service))
        self.selected = selected
        self.onPick = onPick
    }

    var body: some View {
        @Bindable var model = model
        content
            .navigationTitle("Сообщество")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                SearchBar(text: $model.query, prompt: "Найти сообщество", focused: $searchFocused)
                    .padding(.horizontal, Spacing.l)
                    .padding(.vertical, Spacing.s)
                    .background(.bar)
            }
            .scrollDismissesKeyboard(.immediately)
            .task { await model.load() }
            .task(id: model.query) { await model.search() }
    }

    @ViewBuilder
    private var content: some View {
        if let results = model.results {
            List(results) { row($0) }
                .listStyle(.plain)
                .overlay {
                    if results.isEmpty { ContentUnavailableView.search(text: model.query) }
                }
        } else if model.isLoading {
            List(0..<8, id: \.self) { _ in
                HStack(spacing: Spacing.m) {
                    Circle().fill(Color.vetkaSkeleton).frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        SkeletonBar(width: 150, height: 13)
                        SkeletonBar(width: 100, height: 10)
                    }
                }
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .shimmer()
            .allowsHitTesting(false)
        } else if model.failed {
            ContentUnavailableView {
                Label("Не удалось загрузить", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Проверьте соединение или найдите сообщество поиском.")
            } actions: {
                Button("Повторить") { Task { await model.load() } }
                    .buttonStyle(.vetkaPrimary(fullWidth: false))
            }
        } else {
            List {
                if !model.subscriptions.isEmpty {
                    Section("Ваши подписки") {
                        ForEach(model.subscriptions) { row($0) }
                    }
                }
                if !model.others.isEmpty {
                    Section("Популярные") {
                        ForEach(model.others) { row($0) }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ community: Community) -> some View {
        Button {
            onPick(PickedCommunity(community))
        } label: {
            HStack(spacing: Spacing.m) {
                AvatarView(name: community.title, size: 36)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(community.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.vetkaTextPrimary)
                        .lineLimit(1)
                    Text("\(community.slug) · \(community.subscribersCount.compactFormatted) \(community.subscribersCount.ru("подписчик", "подписчика", "подписчиков"))")
                        .font(.footnote)
                        .foregroundStyle(Color.vetkaSecondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if community.slug == selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.vetkaBrand)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(community.slug == selected ? .isSelected : [])
    }
}
