import Core
import DesignSystem
import FeedUI
import Networking
import Stores
import SwiftUI
import UIKit

/// A profile, your own or someone else's: the header with the counters and
/// the follow button, then the posts. The profile tab shows yours as the
/// root of its stack; Route.user shows anyone's (yours too, without the
/// follow button). SwiftUI owns the navigation bar; UIKit owns the header
/// and the list.
public struct ProfileScreen: View {
    private let username: String
    private let isMe: Bool
    private let profiles: ProfileStore
    private let posts: PostStore
    private let feed: any FeedService
    private let isSignedIn: Bool
    private let open: (Route) -> Void
    private let requestSignIn: () -> Void
    private let openSettings: (() -> Void)?
    @State private var titleHidden = false
    @State private var failure: APIError?

    /// `openSettings` is for your own profile in the profile tab: it adds
    /// the gear.
    public init(username: String, isMe: Bool, profiles: ProfileStore, posts: PostStore, feed: any FeedService,
                isSignedIn: Bool, open: @escaping (Route) -> Void, requestSignIn: @escaping () -> Void,
                openSettings: (() -> Void)? = nil) {
        self.username = username
        self.isMe = isMe
        self.profiles = profiles
        self.posts = posts
        self.feed = feed
        self.isSignedIn = isSignedIn
        self.open = open
        self.requestSignIn = requestSignIn
        self.openSettings = openSettings
    }

    public var body: some View {
        let profile = profiles[username]
        Group {
            if profile == nil, let failure {
                ProfileUnavailable(error: failure) { Task { await load() } }
            } else {
                ProfileContainer(username: username, isMe: isMe, profile: profile, profiles: profiles, posts: posts,
                                 feed: feed, isSignedIn: isSignedIn, open: open, requestSignIn: requestSignIn,
                                 onTitleHidden: { titleHidden = $0 })
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        // Surface, like the header: the bar stays transparent (nothing
        // SwiftUI scrolls under it) and shows this, so bar and header read
        // as one piece.
        .background(Color.vetkaSurface)
        .navigationTitle(titleHidden ? profile?.name ?? username : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.vetkaSurface, for: .navigationBar)
        // The tab bar cannot tell the pager's list scrolls under it.
        .toolbarBackground(.visible, for: .tabBar)
        .toolbar {
            if let openSettings {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: openSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color(uiColor: Palette.iconPrimary))
                    }
                    .accessibilityLabel("Настройки")
                    .accessibilityIdentifier("profile.settings")
                }
            }
        }
        // Again on every appearance: counters move while you are away (a
        // new post, a follow). Again on sign-in or out: is_following is per viewer.
        .task(id: isSignedIn) { await load() }
    }

    private func load() async {
        do throws(APIError) {
            try await profiles.load(username)
            failure = nil
        } catch .cancelled {
        } catch {
            failure = error
        }
    }
}

private struct ProfileUnavailable: View {
    let error: APIError
    let retry: () -> Void

    var body: some View {
        if case .server(status: 404, code: _, message: _, field: _) = error {
            ContentUnavailableView("Пользователь не найден", systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text("Возможно, он сменил ник или удалил аккаунт."))
        } else {
            ContentUnavailableView {
                Label("Не удалось загрузить", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Проверьте соединение и попробуйте ещё раз.")
            } actions: {
                Button("Повторить", action: retry)
                    .buttonStyle(.vetkaPrimary(fullWidth: false))
            }
        }
    }
}

private struct ProfileContainer: UIViewControllerRepresentable {
    let username: String
    let isMe: Bool
    let profile: Profile?
    let profiles: ProfileStore
    let posts: PostStore
    let feed: any FeedService
    let isSignedIn: Bool
    let open: (Route) -> Void
    let requestSignIn: () -> Void
    let onTitleHidden: (Bool) -> Void

    func makeUIViewController(context: Context) -> ProfileViewController {
        let vc = ProfileViewController(username: username, isMe: isMe, posts: posts, feed: feed,
                                       isSignedIn: isSignedIn, open: open, requestSignIn: requestSignIn,
                                       follow: { [profiles, username] in profiles.toggleFollow(username) })
        vc.onTitleHidden = { hidden in
            // Never during a SwiftUI update: the title is SwiftUI state.
            DispatchQueue.main.async { onTitleHidden(hidden) }
        }
        vc.update(profile)
        return vc
    }

    func updateUIViewController(_ vc: ProfileViewController, context: Context) {
        vc.update(profile)
        vc.setSignedIn(isSignedIn)
    }
}

/// The header pager with one page, the posts: no tabs to switch.
final class ProfileViewController: UIViewController {
    var onTitleHidden: ((Bool) -> Void)?

    private let header: ProfileHeaderView
    private let feed: FeedViewController
    private let pager: HeaderPagerViewController
    private var shown: Profile?
    private var isSignedIn: Bool

    init(username: String, isMe: Bool, posts: PostStore, feed service: any FeedService, isSignedIn: Bool,
         open: @escaping (Route) -> Void, requestSignIn: @escaping () -> Void, follow: @escaping () -> Void) {
        self.isSignedIn = isSignedIn
        header = ProfileHeaderView(username: username, isMe: isMe)
        header.onFollow = follow
        header.onOpenList = { list in open(.follows(username: username, list: list)) }
        let model = FeedModel(source: .user(username: username), service: service, store: posts,
                              isSignedIn: isSignedIn, requestSignIn: requestSignIn)
        feed = FeedViewController(model: model, open: open, requestSignIn: requestSignIn)
        pager = HeaderPagerViewController(header: header, titles: ["Публикации"], pages: [feed])
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.onTitleHidden = { [weak self] in self?.onTitleHidden?($0) }
    }

    func update(_ profile: Profile?) {
        guard profile != shown else { return }
        // Only what changes the header's height is measured again; a new
        // follower count is not.
        let layoutChanged = (profile == nil) != (shown == nil) || profile?.bio != shown?.bio
            || profile?.name != shown?.name || profile?.username != shown?.username
        shown = profile
        header.configure(profile)
        if layoutChanged {
            pager.headerDidChange()
        }
    }

    func setSignedIn(_ signedIn: Bool) {
        guard signedIn != isSignedIn else { return }
        isSignedIn = signedIn
        Task { await feed.model.sessionChanged(signedIn: signedIn) }
    }
}
