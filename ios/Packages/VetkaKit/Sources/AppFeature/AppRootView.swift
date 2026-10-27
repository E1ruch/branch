import AuthFeature
import CommunitiesFeature
import Core
import FeedFeature
import DesignSystem
import Networking
import Session
import SwiftUI
import UIKit

/// The app shell: tabs, a NavigationStack per tab, and route → screen mapping.
///
/// Stacks use the system navigation bar, which keeps the interactive
/// back-swipe working everywhere; custom bars that hide it break the gesture.
public struct AppRootView: View {
    private let app: AppEnvironment
    @State private var router: AppRouter

    public init(app: AppEnvironment) {
        self.app = app
        _router = State(initialValue: app.router)
        // Inactive tabs: the design system's icon-secondary, not system gray.
        UITabBar.appearance().unselectedItemTintColor = Palette.iconSecondary
    }

    public var body: some View {
        TabView(selection: router.tabSelection) {
            stack(.feed) {
                FeedScreen(service: LiveFeedService(client: app.client),
                           isSignedIn: app.session.state == .signedIn,
                           myName: app.session.me?.username,
                           open: { router.push($0) },
                           requestSignIn: { router.isAuthPresented = true },
                           openSearch: { router.tabSelection.wrappedValue = .search },
                           openProfile: { router.tabSelection.wrappedValue = .profile })
            }
                .tabItem { Label("Лента", systemImage: "flame") }
                .tag(Tab.feed)

            stack(.search) { CommunitiesView(client: app.client) }
                .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            Color.clear
                .tabItem {
                    Image(uiImage: Self.composeIcon)
                        .accessibilityLabel("Создать пост")
                }
                .tag(Tab.create)

            stack(.activity) { ActivityPlaceholder() }
                .tabItem { Label("Активность", systemImage: "bell") }
                .tag(Tab.activity)

            stack(.profile) { ProfileTabView(session: app.session, router: router) }
                .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
                .tag(Tab.profile)
        }
        .tint(.vetkaBrand)
        .sheet(isPresented: $router.isComposePresented) { ComposePlaceholder() }
        .onOpenURL { router.open($0) }
        .sheet(isPresented: $router.isAuthPresented) {
            AuthFlowView(client: app.client, session: app.session,
                         showsSignInWithApple: app.features.signInWithApple)
        }
        .task {
            Haptics.prepare()
            await app.session.start()
        }
    }

    /// The green "+" in the tab bar, drawn once. Tab bar icons are tinted
    /// templates by default; this one keeps its own colors.
    static let composeIcon: UIImage = {
        let size = CGSize(width: 36, height: 36)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            Palette.buttonPrimary.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).setFill()
            UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
            let plus = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))!
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            plus.draw(at: CGPoint(x: (size.width - plus.size.width) / 2, y: (size.height - plus.size.height) / 2))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }()

    private func stack<Root: View>(_ tab: Tab, @ViewBuilder root: () -> Root) -> some View {
        NavigationStack(path: router.path(for: tab)) {
            root()
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
    }
}

/// Maps a route to its screen. Screens arrive module by module; until then
/// each route shows what it will be.
struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case let .post(id):
            Placeholder(title: "Пост #\(id)", systemImage: "doc.text",
                        note: "Экран поста с комментариями — в модуле «Пост».")
        case let .community(slug):
            Placeholder(title: slug, systemImage: "square.grid.2x2",
                        note: "Лента сообщества — вместе с лентой на UICollectionView.")
        case let .user(username):
            Placeholder(title: username, systemImage: "person",
                        note: "Публичный профиль — в модуле «Профиль».")
        case let .commentThread(id):
            Placeholder(title: "Ветка #\(id)", systemImage: "text.bubble",
                        note: "Ветка комментариев — в модуле «Пост».")
        }
    }
}

struct Placeholder: View {
    let title: String
    let systemImage: String
    let note: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(note))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct ActivityPlaceholder: View {
    var body: some View {
        ContentUnavailableView("Активность", systemImage: "bell",
                               description: Text("Ответы, упоминания, реакции и новые подписчики появятся здесь."))
            .navigationTitle("Активность")
    }
}

struct ComposePlaceholder: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView("Создание поста", systemImage: "square.and.pencil",
                                   description: Text("Текст, выбор сообщества и публикация — следующий шаг."))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрыть") { dismiss() }
                    }
                }
        }
    }
}

struct ProfileTabView: View {
    let session: SessionStore
    let router: AppRouter

    var body: some View {
        Group {
            switch session.state {
            case .signedOut:
                ContentUnavailableView {
                    Label("Вы не вошли", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Войдите, чтобы голосовать, комментировать и подписываться на сообщества.")
                } actions: {
                    Button("Войти") { router.isAuthPresented = true }
                        .buttonStyle(.vetkaPrimary(fullWidth: false))
                        .accessibilityIdentifier("profile.signIn")
                }
            case .signedIn:
                if let me = session.me {
                    List {
                        if let name = me.displayName {
                            LabeledContent("Имя", value: name)
                        }
                        LabeledContent("Ник", value: me.username)
                            .accessibilityIdentifier("profile.username")
                        LabeledContent("Карма за посты", value: me.postKarma.formatted())
                        LabeledContent("Карма за комментарии", value: me.commentKarma.formatted())
                        Button("Выйти", role: .destructive) { Task { await session.signOut() } }
                    }
                } else {
                    List { SkeletonBar(width: 180) ; SkeletonBar(width: 140) }
                        .shimmer()
                }
            }
        }
        .navigationTitle("Профиль")
    }
}
