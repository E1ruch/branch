import Core
import DesignSystem
import Networking
import Stores
import SwiftUI

/// The communities tab: Популярное and Подписки with their counters; typing
/// in its search field switches the list to search results. Every row subscribes (or
/// unsubscribes) in one tap.
public struct CommunitiesView: View {
    @State private var model: CommunitiesModel
    private let isSignedIn: Bool
    private let requestSignIn: () -> Void
    // `@State` holds an @Observable model; bindings need @Bindable.
    private var bindable: Bindable<CommunitiesModel> { Bindable(model) }

    public init(client: APIClient, store: CommunityStore, isSignedIn: Bool, requestSignIn: @escaping () -> Void) {
        _model = State(initialValue: CommunitiesModel(client: client, store: store))
        self.isSignedIn = isSignedIn
        self.requestSignIn = requestSignIn
    }

    public var body: some View {
        content
            .background(Color.vetkaBackground)
            .navigationTitle("Сообщества")
            .toolbarBackground(Color.vetkaSurface, for: .navigationBar)
            .searchable(text: bindable.query, prompt: "Найти сообщество")
            // Again on sign-in or out: subscriptions belong to the account.
            .task(id: isSignedIn) { await model.load(signedIn: isSignedIn) }
            .task(id: model.query) { await model.search() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading where model.popular.isEmpty:
            List {
                ForEach(0..<10, id: \.self) { _ in CommunityRowSkeleton() }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .shimmer()
            .allowsHitTesting(false)
        case .failed:
            ContentUnavailableView {
                Label("Не удалось загрузить", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Проверьте соединение и попробуйте ещё раз.")
            } actions: {
                Button("Повторить") { Task { await model.load(signedIn: isSignedIn) } }
                    .buttonStyle(.vetkaPrimary(fullWidth: false))
            }
        default:
            if let results = model.results {
                List {
                    rows(results)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .overlay {
                    if results.isEmpty {
                        ContentUnavailableView.search(text: model.query)
                    }
                }
            } else {
                discover
            }
        }
    }

    /// Популярное and Подписки under the search field, pinned while the
    /// list scrolls, each with its counter.
    private var discover: some View {
        List {
            Section {
                switch model.tab {
                case .popular:
                    rows(model.popular, paginated: true)
                case .subscriptions:
                    rows(model.subscriptionRows)
                }
            } header: {
                PillPicker([
                    (CommunitiesModel.Tab.popular, "Популярное", model.popularCount),
                    (.subscriptions, "Подписки", model.subscriptionCount.map(String.init)),
                ], selection: bindable.tab)
                .animation(.vetkaSnappy, value: model.subscriptionCount)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                .background(Color.vetkaBackground)
                .listRowInsets(EdgeInsets())
                .textCase(nil)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load(signedIn: isSignedIn) }
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch model.tab {
        case .popular where model.popular.isEmpty:
            ContentUnavailableView("Пока пусто", systemImage: "leaf",
                                   description: Text("Сообществ ещё нет — создайте первое."))
        case .subscriptions where !isSignedIn:
            ContentUnavailableView {
                Label("Ваши подписки", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Войдите, чтобы подписываться на сообщества.")
            } actions: {
                Button("Войти", action: requestSignIn)
                    .buttonStyle(.vetkaPrimary(fullWidth: false))
            }
        case .subscriptions where model.mySlugs?.isEmpty == true && model.subscriptionRows.isEmpty:
            ContentUnavailableView {
                Label("Подписок пока нет", systemImage: "square.grid.2x2")
            } description: {
                Text("Подпишитесь на интересные сообщества — их посты появятся в ленте «Подписки».")
            } actions: {
                Button("К популярным") { withAnimation(.vetkaSnappy) { model.tab = .popular } }
                    .buttonStyle(.vetkaPrimary(fullWidth: false))
            }
        default:
            EmptyView()
        }
    }

    private func rows(_ slugs: [String], paginated: Bool = false) -> some View {
        ForEach(slugs, id: \.self) { slug in
            if let community = model[slug] {
                // The link sits behind the row: the whole row opens the
                // community, without the chevron eating into the title.
                CommunityRow(community: community) { model.toggleSubscription(slug) }
                    .background {
                        NavigationLink(value: Route.community(slug: community.slug)) { EmptyView() }
                            .opacity(0)
                    }
                .listRowBackground(Color.vetkaSurface)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 56 + Spacing.m }
                .task {
                    if paginated {
                        await model.loadMoreIfNeeded(after: slug)
                    }
                }
            }
        }
    }
}

struct CommunityRow: View {
    let community: Community
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            AvatarView(name: community.title, size: 44)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(community.title)
                    .font(.headline)
                    .foregroundStyle(Color.vetkaTextPrimary)
                    .lineLimit(1)
                if !community.description.isEmpty {
                    Text(community.description)
                        .font(.subheadline)
                        .foregroundStyle(Color.vetkaTextPrimary)
                        .lineLimit(1)
                }
                Text(subscribers)
                    .font(.footnote)
                    .foregroundStyle(Color.vetkaSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Subscribed: grey and says what a tap does.
            Button(community.isSubscribed ? "Отписаться" : "Подписаться", action: toggle)
                .buttonStyle(.pill(community.isSubscribed ? .muted : .filled))
            .animation(.vetkaSnappy, value: community.isSubscribed)
        }
        .padding(.vertical, Spacing.xs)
    }

    private var subscribers: String {
        let count = community.subscribersCount
        return "\(count.compactFormatted) \(count.ru("подписчик", "подписчика", "подписчиков"))"
    }
}

struct CommunityRowSkeleton: View {
    var body: some View {
        HStack(spacing: Spacing.m) {
            Circle().fill(Color.vetkaSkeleton).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: Spacing.s) {
                SkeletonBar(width: 160, height: 14)
                SkeletonBar(width: 110, height: 11)
            }
            Spacer()
            Capsule().fill(Color.vetkaSkeleton).frame(width: 104, height: 32)
        }
        .padding(.vertical, Spacing.xs)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.vetkaSurface)
    }
}
