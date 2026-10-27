import AuthFeature
import CommunitiesFeature
import Core
import DesignSystem
import Networking
import Session
import SwiftUI

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
    }

    public var body: some View {
        TabView(selection: router.tabSelection) {
            stack(.feed) { FeedPlaceholderView() }
                .tabItem { Label("Лента", systemImage: "flame") }
                .tag(Tab.feed)

            stack(.communities) { CommunitiesView(client: app.client) }
                .tabItem { Label("Сообщества", systemImage: "square.grid.2x2") }
                .tag(Tab.communities)

            stack(.profile) { ProfileTabView(session: app.session, router: router) }
                .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
                .tag(Tab.profile)
        }
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

struct FeedPlaceholderView: View {
    var body: some View {
        ContentUnavailableView("Лента", systemImage: "flame",
                               description: Text("Горячее, новое и подписки на UICollectionView — следующий модуль."))
            .navigationTitle("Ветка")
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
                        .buttonStyle(.borderedProminent)
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
