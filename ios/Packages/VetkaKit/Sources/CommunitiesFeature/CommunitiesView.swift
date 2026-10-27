import Core
import DesignSystem
import Networking
import SwiftUI

public struct CommunitiesView: View {
    @State private var model: CommunitiesModel

    public init(client: APIClient) {
        _model = State(initialValue: CommunitiesModel(client: client))
    }

    public var body: some View {
        content
            .navigationTitle("Сообщества")
            .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading where model.items.isEmpty:
            List(0..<10, id: \.self) { _ in CommunityRowSkeleton() }
                .listStyle(.plain)
                .shimmer()
                .allowsHitTesting(false)
        case .failed:
            ContentUnavailableView {
                Label("Не удалось загрузить", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Проверьте соединение и попробуйте ещё раз.")
            } actions: {
                Button("Повторить") { Task { await model.load() } }
                    .buttonStyle(.borderedProminent)
            }
        default:
            List(model.items) { community in
                NavigationLink(value: Route.community(slug: community.slug)) {
                    CommunityRow(community: community)
                }
                .task { await model.loadMoreIfNeeded(after: community) }
            }
            .listStyle(.plain)
            .refreshable { await model.load() }
            .overlay {
                if model.items.isEmpty {
                    ContentUnavailableView("Пока пусто", systemImage: "leaf",
                                           description: Text("Сообществ ещё нет — создайте первое."))
                }
            }
        }
    }
}

struct CommunityRow: View {
    let community: Community

    var body: some View {
        HStack(spacing: Spacing.m) {
            Avatar(letter: community.title.first)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(community.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(community.slug) · \(community.subscribersCount.compactFormatted) \(community.subscribersCount.ru("подписчик", "подписчика", "подписчиков"))")
                    .font(.subheadline)
                    .foregroundStyle(Color.vetkaSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if community.isSubscribed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Вы подписаны")
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

struct CommunityRowSkeleton: View {
    var body: some View {
        HStack(spacing: Spacing.m) {
            Circle().fill(Color.vetkaSkeleton).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: Spacing.s) {
                SkeletonBar(width: 160, height: 14)
                SkeletonBar(width: 110, height: 11)
            }
        }
        .padding(.vertical, Spacing.xs)
        .listRowSeparator(.hidden)
    }
}

/// A letter avatar until communities get icons (media module).
struct Avatar: View {
    let letter: Character?

    var body: some View {
        Circle()
            .fill(.tint.opacity(0.15))
            .frame(width: 40, height: 40)
            .overlay {
                Text(letter.map { String($0).uppercased() } ?? "?")
                    .font(.headline)
                    .foregroundStyle(.tint)
            }
            .accessibilityHidden(true)
    }
}
