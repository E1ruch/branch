import Core
import DesignSystem
import FeedUI
import Networking
import Stores
import SwiftUI

/// The search tab: the field in the navigation bar, filter chips under it;
/// popular queries and recent results while nothing is typed.
public struct SearchScreen: View {
    @State private var model: SearchModel
    private let isSignedIn: Bool
    /// Bumped by the magnifier in the feed header: focus the field.
    private let focusRequest: Int
    private let open: (Route) -> Void
    @FocusState private var focused: Bool
    private var bindable: Bindable<SearchModel> { Bindable(model) }

    public init(service: any SearchService, communities: CommunityStore, posts: PostStore,
                storage: any RecentStorage, isSignedIn: Bool, focusRequest: Int, open: @escaping (Route) -> Void) {
        _model = State(initialValue: SearchModel(service: service, communities: communities, posts: posts,
                                                 storage: storage, isSignedIn: isSignedIn))
        self.isSignedIn = isSignedIn
        self.focusRequest = focusRequest
        self.open = open
    }

    public var body: some View {
        VStack(spacing: 0) {
            FilterChips(selection: bindable.filter)
            content
                .frame(maxHeight: .infinity)
        }
        .background(Color.vetkaSurface)
        .navigationTitle("Поиск")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.vetkaSurface, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                SearchField(text: bindable.query, focused: $focused, submit: model.submit)
            }
        }
        .task { await model.loadPopular() }
        .task(id: model.query) { await model.search() }
        .task(id: focusRequest) {
            guard focusRequest > 0 else { return }
            // Set while the tab is still switching in, focus does not take.
            try? await Task.sleep(for: .milliseconds(150))
            focused = true
        }
        .onChange(of: isSignedIn) { model.isSignedIn = isSignedIn }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            SearchHome(model: model, go: go)
        case .loading:
            List {
                ForEach(0..<6, id: \.self) { _ in CommunityRowSkeleton() }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .shimmer()
            .allowsHitTesting(false)
        case let .failed(rateLimited):
            ContentUnavailableView {
                Label(rateLimited ? "Слишком много запросов" : "Не удалось найти",
                      systemImage: rateLimited ? "hourglass" : "wifi.exclamationmark")
            } description: {
                Text(rateLimited ? "Подождите минуту и попробуйте снова." : "Проверьте соединение и попробуйте ещё раз.")
            }
        case let .loaded(results):
            SearchResults(model: model, results: results, go: go)
        }
    }

    private func go(_ item: RecentItem) {
        focused = false
        open(model.opened(item))
    }
}

// MARK: - Field and filters

private struct SearchField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let submit: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.vetkaSecondaryText)
            TextField("Поиск", text: $text)
                .focused(focused)
                .submitLabel(.search)
                .onSubmit(submit)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("search.field")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color(uiColor: Palette.iconSecondary))
                }
                .accessibilityLabel("Очистить")
            }
        }
        .font(.body)
        .padding(.horizontal, Spacing.m)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Color.vetkaField))
        .frame(maxWidth: .infinity)
    }
}

/// Всё · Сообщества · Пользователи · Посты: separate capsules, the chosen
/// one filled green.
private struct FilterChips: View {
    @Binding var selection: SearchModel.Filter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(SearchModel.Filter.allCases, id: \.self) { filter in
                    let selected = filter == selection
                    Button {
                        guard !selected else { return }
                        Haptics.selection()
                        withAnimation(.vetkaSnappy) { selection = filter }
                    } label: {
                        // Small enough that all four fit across a phone.
                        Text(filter.title)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(uiColor: selected ? Palette.buttonPrimaryText : Palette.chipInactiveText))
                            .padding(.horizontal, Spacing.m)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color(uiColor: selected ? Palette.buttonPrimary : Palette.chipInactiveBackground)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.s)
        }
    }
}

// MARK: - Empty field

/// Популярные запросы as chips, then Недавние.
private struct SearchHome: View {
    let model: SearchModel
    let go: (RecentItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                if !model.popular.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        SectionTitle("Популярные запросы")
                        FlowLayout(spacing: Spacing.s) {
                            ForEach(model.popular, id: \.self) { text in
                                Button { model.pick(text) } label: {
                                    Text(text)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.vetkaSecondaryText)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Capsule().fill(Color(uiColor: Palette.surfaceSecondary)))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.l)
                }

                if !model.recent.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack {
                            SectionTitle("Недавние")
                            Spacer()
                            Button("Очистить") {
                                withAnimation(.vetkaSnappy) { model.clearRecent() }
                            }
                            .font(.subheadline)
                            .foregroundStyle(Color.vetkaBrand)
                        }
                        .padding(.horizontal, Spacing.l)
                        ForEach(model.recent) { item in
                            Button { go(item) } label: { RecentRow(item: item) }
                                .buttonStyle(RowButtonStyle())
                        }
                    }
                }

                if model.popular.isEmpty && model.recent.isEmpty {
                    ContentUnavailableView("Найдите что угодно", systemImage: "magnifyingglass",
                                           description: Text("Сообщества, людей и посты."))
                        .padding(.top, Spacing.xl)
                }
            }
            .padding(.vertical, Spacing.m)
        }
        .scrollDismissesKeyboard(.immediately)
    }
}

private struct RecentRow: View {
    let item: RecentItem

    var body: some View {
        HStack(spacing: Spacing.m) {
            switch item {
            case let .community(_, title):
                AvatarView(name: title, size: 44)
                Text(title).foregroundStyle(Color.vetkaTextPrimary)
            case let .user(username, name):
                AvatarView(name: username, size: 44)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(name ?? username).foregroundStyle(Color.vetkaTextPrimary)
                    if name != nil {
                        Text("@\(username)").font(.footnote).foregroundStyle(Color.vetkaSecondaryText)
                    }
                }
            case let .post(_, title, community):
                Image(systemName: "doc.text")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(uiColor: Palette.iconSecondary))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color(uiColor: Palette.surfaceSecondary)))
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title).foregroundStyle(Color.vetkaTextPrimary).lineLimit(1)
                    Text(community).font(.footnote).foregroundStyle(Color.vetkaSecondaryText)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(uiColor: Palette.iconSecondary))
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
        .contentShape(Rectangle())
    }
}

// MARK: - Results

private struct SearchResults: View {
    let model: SearchModel
    let results: SearchModel.Results
    let go: (RecentItem) -> Void

    var body: some View {
        let filter = model.filter
        let preview = filter == .all ? SearchModel.previewCount : Int.max
        List {
            if filter == .all || filter == .communities, !results.communities.isEmpty {
                Section {
                    ForEach(results.communities.prefix(preview), id: \.self) { slug in
                        if let community = model.communities[slug] {
                            CommunityRow(community: community) { model.communities.toggleSubscription(slug) }
                                .contentShape(Rectangle())
                                .onTapGesture { go(.community(slug: community.slug, title: community.title)) }
                                .listRowBackground(Color.vetkaSurface)
                        }
                    }
                } header: {
                    header("Сообщества", count: results.communities.count, show: .communities)
                }
            }
            if filter == .all || filter == .users, !results.users.isEmpty {
                Section {
                    ForEach(results.users.prefix(preview)) { user in
                        Button { go(.user(username: user.username, name: user.displayName)) } label: { UserRow(user: user) }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.vetkaSurface)
                    }
                } header: {
                    header("Пользователи", count: results.users.count, show: .users)
                }
            }
            if filter == .all || filter == .posts, !results.posts.isEmpty {
                Section {
                    ForEach(results.posts.prefix(preview), id: \.self) { id in
                        if let post = model.posts[id] {
                            Button { go(.post(id: id, title: post.title, community: post.community.title)) } label: {
                                PostRow(post: post)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.vetkaSurface)
                        }
                    }
                } header: {
                    header("Посты", count: results.posts.count, show: .posts)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if isEmpty(for: filter) {
                ContentUnavailableView.search(text: model.query)
            }
        }
    }

    private func isEmpty(for filter: SearchModel.Filter) -> Bool {
        switch filter {
        case .all: results.isEmpty
        case .communities: results.communities.isEmpty
        case .users: results.users.isEmpty
        case .posts: results.posts.isEmpty
        }
    }

    /// "Сообщества … Все 12" under Всё; just the title in its own filter.
    private func header(_ title: String, count: Int, show filter: SearchModel.Filter) -> some View {
        HStack {
            SectionTitle(title)
            Spacer()
            if model.filter == .all, count > SearchModel.previewCount {
                Button("Все \(count)") {
                    Haptics.selection()
                    withAnimation(.vetkaSnappy) { model.filter = filter }
                }
                .font(.subheadline)
                .foregroundStyle(Color.vetkaBrand)
            }
        }
        .padding(.vertical, Spacing.xs)
        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.l, bottom: 0, trailing: Spacing.l))
        .background(Color.vetkaSurface)
    }
}

private struct UserRow: View {
    let user: User

    var body: some View {
        HStack(spacing: Spacing.m) {
            AvatarView(name: user.username, size: 44)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(user.displayName ?? user.username)
                    .font(.headline)
                    .foregroundStyle(Color.vetkaTextPrimary)
                    .lineLimit(1)
                Text("@\(user.username) · карма \((user.postKarma + user.commentKarma).compactFormatted)")
                    .font(.footnote)
                    .foregroundStyle(Color.vetkaSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.xs)
        .contentShape(Rectangle())
    }
}

/// A post found: its title, then where and how it is doing.
private struct PostRow: View {
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(post.title)
                .font(.headline)
                .foregroundStyle(Color.vetkaTextPrimary)
                .lineLimit(2)
            HStack(spacing: Spacing.s) {
                Text(post.community.title)
                Label(post.score.compactFormatted, systemImage: "arrowshape.up")
                Label(post.commentCount.compactFormatted, systemImage: "bubble.left")
            }
            .labelStyle(CompactLabelStyle())
            .font(.footnote)
            .foregroundStyle(Color.vetkaSecondaryText)
        }
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

private struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(Color.vetkaTextPrimary)
            .textCase(nil)
    }
}

/// A row-wide button with the list's pressed highlight.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(uiColor: Palette.surfaceHover) : .clear)
    }
}

/// Chips that wrap onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty {
            rows.append(row)
        }
        return rows
    }
}
