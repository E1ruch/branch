import AuthFeature
import CommunitiesFeature
import ComposeFeature
import Core
import FeedFeature
import FeedUI
import DesignSystem
import Networking
import PostFeature
import ProfileFeature
import SearchFeature
import Session
import SettingsFeature
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

    /// A post just published: shown once the composer has closed. Pushed
    /// while the sheet is still going away, the screen gets no safe area
    /// and slides under the bars.
    @State private var publishedPostID: Int64?

    private func openPublishedPost() {
        router.composeContinuing = nil
        router.composeCommunity = nil
        guard let id = publishedPostID else { return }
        publishedPostID = nil
        router.push(.post(id: id))
    }

    public var body: some View {
        TabView(selection: router.tabSelection) {
            stack(.feed) {
                FeedScreen(service: LiveFeedService(client: app.client),
                           store: app.posts,
                           isSignedIn: app.session.state == .signedIn,
                           myName: app.session.me?.username,
                           open: { router.push($0) },
                           requestSignIn: { router.isAuthPresented = true },
                           openSearch: {
                               router.tabSelection.wrappedValue = .search
                               router.searchFocusRequest += 1
                           },
                           openActivity: { router.push(.activity) },
                           openProfile: { router.tabSelection.wrappedValue = .profile })
            }
                .tabItem { Label("Лента", systemImage: "flame") }
                .tag(Tab.feed)

            stack(.search) {
                SearchScreen(service: LiveSearchService(client: app.client), communities: app.communities,
                             posts: app.posts, storage: UserDefaultsRecentStorage(userID: app.session.me?.id),
                             isSignedIn: app.session.state == .signedIn, focusRequest: router.searchFocusRequest,
                             open: { router.push($0) })
                    // "Недавние" are per account: a new account gets its own list.
                    .id(app.session.me?.id)
            }
                .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
                .tag(Tab.search)

            Color.clear
                .tabItem {
                    Image(uiImage: Self.composeIcon)
                        .accessibilityLabel("Создать пост")
                }
                .tag(Tab.create)

            stack(.communities) {
                CommunitiesView(client: app.client, store: app.communities, isSignedIn: app.session.state == .signedIn,
                                requestSignIn: { router.isAuthPresented = true })
            }
                .tabItem { Label("Сообщества", systemImage: "square.grid.2x2") }
                .tag(Tab.communities)

            stack(.profile) { ProfileTabView(app: app, router: router) }
                .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
                .tag(Tab.profile)
        }
        .tint(.vetkaBrand)
        .background(ThemeWindowHook(store: app.theme))
        .overlay(alignment: .bottom) {
            Button { router.compose() } label: { Color.clear }
                .frame(width: 76, height: 49)
                .contentShape(Rectangle())
                .accessibilityLabel("Создать пост")
                .accessibilityIdentifier("tab.compose")
        }
        .sheet(isPresented: $router.isComposePresented, onDismiss: openPublishedPost) {
            let continuing = router.composeContinuing
            let community = continuing.map {
                PickedCommunity(slug: $0.community.slug, title: $0.community.title, isNSFW: false)
            } ?? router.composeCommunity.map {
                PickedCommunity(slug: $0.slug, title: $0.title, isNSFW: $0.isNsfw)
            }
            ComposeView(service: LiveComposeService(client: app.client, username: app.session.me?.username),
                        storage: UserDefaultsDraftStorage(userID: app.session.me?.id),
                        community: community,
                        continues: continuing.map(ContinuedPost.init)) { post in
                app.posts.merge([post])
                publishedPostID = post.id
                router.isComposePresented = false
            }
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
        .onChange(of: app.session.state == .signedIn) {
            // Subscriptions and follows belong to the account: screens reload them.
            app.communities.sessionChanged()
            app.profiles.sessionChanged()
            seedMyProfile()
        }
        // Your profile is on screen the moment you open the tab: the store
        // has it from /me before the profile request returns.
        .onChange(of: app.session.me, initial: true) { seedMyProfile() }
    }

    private func seedMyProfile() {
        guard let me = app.session.me else { return }
        app.profiles.merge([Profile(me)])
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
                .navigationDestination(for: Route.self) {
                    RouteView(route: $0, app: app, router: router)
                        .vetkaBackButton()
                }
        }
    }
}

/// Maps a route to its screen. Screens arrive module by module; until then
/// a route shows what it will be (Активность).
struct RouteView: View {
    let route: Route
    let app: AppEnvironment
    let router: AppRouter

    var body: some View {
        switch route {
        case let .post(id):
            thread(.post(id: id))
        case let .community(slug):
            CommunityScreen(slug: slug, communities: app.communities, posts: app.posts,
                            feed: LiveFeedService(client: app.client),
                            isSignedIn: app.session.state == .signedIn,
                            open: { router.push($0) },
                            requestSignIn: { router.isAuthPresented = true },
                            compose: { router.compose(in: $0) })
        case let .user(username):
            ProfileScreen(username: username,
                          isMe: username.lowercased() == app.session.me?.username.lowercased(),
                          profiles: app.profiles, posts: app.posts, feed: LiveFeedService(client: app.client),
                          isSignedIn: app.session.state == .signedIn,
                          open: { router.push($0) },
                          requestSignIn: { router.isAuthPresented = true })
        case let .commentThread(id):
            thread(.branch(commentID: id))
        case .activity:
            ActivityPlaceholder()
        case .settings:
            SettingsScreen(me: app.session.me, theme: app.theme) {
                // Back to the profile tab's root, which turns into the
                // sign-in invitation once the session ends.
                router.popToRoot(.profile)
                await app.session.signOut()
            }
        case .appearance:
            AppearanceScreen(theme: app.theme)
        case .privacy:
            PrivacyScreen(username: app.session.me?.username) { () throws(APIError) in
                try await app.session.deleteAccount()
                // The profile tab's root is the sign-in invitation now.
                router.popToRoot(.profile)
            }
        case let .follows(username, list):
            FollowsScreen(username: username, list: list, profiles: app.profiles, client: app.client,
                          myUsername: app.session.me?.username)
        case .editProfile:
            if let me = app.session.me {
                EditProfileScreen(model: EditProfileModel(me: me, client: app.client)) { app.session.didUpdate($0) }
            }
        }
    }

    private func thread(_ mode: ThreadMode) -> some View {
        let me = app.session.me
        return ThreadScreen(mode: mode, service: LivePostService(client: app.client), store: app.posts,
                            isSignedIn: app.session.state == .signedIn,
                            viewer: me.map { AuthorRef(id: $0.id, username: $0.username, displayName: $0.displayName) },
                            open: { router.push($0) },
                            requestSignIn: { router.isAuthPresented = true },
                            continueStory: { router.compose(continuing: $0) })
    }
}

struct ActivityPlaceholder: View {
    var body: some View {
        ContentUnavailableView("Активность", systemImage: "bell",
                               description: Text("Ответы, упоминания, реакции и новые подписчики появятся здесь."))
            .navigationTitle("Активность")
            .navigationBarTitleDisplayMode(.inline)
    }
}


struct ProfileTabView: View {
    let app: AppEnvironment
    let router: AppRouter

    var body: some View {
        switch app.session.state {
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
            .navigationTitle("Профиль")
        case .signedIn:
            if let me = app.session.me {
                ProfileScreen(username: me.username, isMe: true, profiles: app.profiles, posts: app.posts,
                              feed: LiveFeedService(client: app.client), isSignedIn: true,
                              open: { router.push($0) },
                              requestSignIn: { router.isAuthPresented = true },
                              openSettings: { router.push(.settings) })
                    // A new username is another profile: the screen starts over.
                    .id(me.username)
            } else {
                // Signed in, /me still on its way (offline at launch).
                List { SkeletonBar(width: 180) ; SkeletonBar(width: 140) }
                    .shimmer()
                    .navigationTitle("Профиль")
                    .task { await app.session.reloadMe() }
            }
        }
    }
}
