import Core
import DesignSystem
import FeedUI
import Networking
import Stores
import SwiftUI
import UIKit

/// A community page (Route.community): the header with the subscribe
/// button, then Лента (newest), Популярное (hot) and Правила. SwiftUI owns
/// the navigation bar; UIKit owns the header and the lists.
public struct CommunityScreen: View {
    private let slug: String
    private let communities: CommunityStore
    private let posts: PostStore
    private let feed: any FeedService
    private let isSignedIn: Bool
    private let open: (Route) -> Void
    private let requestSignIn: () -> Void
    private let compose: (Community) -> Void
    @State private var titleHidden = false
    @State private var failure: APIError?

    /// `compose` opens the composer with this community picked.
    public init(slug: String, communities: CommunityStore, posts: PostStore, feed: any FeedService, isSignedIn: Bool,
                open: @escaping (Route) -> Void, requestSignIn: @escaping () -> Void,
                compose: @escaping (Community) -> Void) {
        self.slug = slug
        self.communities = communities
        self.posts = posts
        self.feed = feed
        self.isSignedIn = isSignedIn
        self.open = open
        self.requestSignIn = requestSignIn
        self.compose = compose
    }

    public var body: some View {
        let community = communities[slug]
        Group {
            if community == nil, let failure {
                CommunityUnavailable(error: failure) { Task { await load() } }
            } else {
                CommunityContainer(slug: slug, community: community, communities: communities, posts: posts, feed: feed,
                                   isSignedIn: isSignedIn, open: open, requestSignIn: requestSignIn,
                                   onTitleHidden: { titleHidden = $0 })
                    .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        // Surface, like the header: the bar stays transparent (nothing
        // SwiftUI scrolls under it) and shows this, so bar and header read
        // as one piece.
        .background(Color.vetkaSurface)
        .navigationTitle(titleHidden ? community?.title ?? "" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.vetkaSurface, for: .navigationBar)
        // With several lists in the pager the tab bar cannot tell which one
        // scrolls under it and stays transparent over the posts.
        .toolbarBackground(.visible, for: .tabBar)
        .toolbar {
            if let community {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { compose(community) } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color(uiColor: Palette.iconPrimary))
                    }
                    .accessibilityLabel("Написать пост")
                }
            }
        }
        // Again on sign-in or out: is_subscribed and the role are per viewer.
        .task(id: isSignedIn) { await load() }
    }

    private func load() async {
        do throws(APIError) {
            try await communities.load(slug)
            failure = nil
        } catch .cancelled {
        } catch {
            failure = error
        }
    }
}

private struct CommunityUnavailable: View {
    let error: APIError
    let retry: () -> Void

    var body: some View {
        if case .server(status: 404, code: _, message: _, field: _) = error {
            ContentUnavailableView("Сообщество не найдено", systemImage: "square.grid.2x2",
                                   description: Text("Возможно, его переименовали или удалили."))
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

private struct CommunityContainer: UIViewControllerRepresentable {
    let slug: String
    let community: Community?
    let communities: CommunityStore
    let posts: PostStore
    let feed: any FeedService
    let isSignedIn: Bool
    let open: (Route) -> Void
    let requestSignIn: () -> Void
    let onTitleHidden: (Bool) -> Void

    func makeUIViewController(context: Context) -> CommunityViewController {
        let vc = CommunityViewController(slug: slug, posts: posts, feed: feed, isSignedIn: isSignedIn,
                                         open: open, requestSignIn: requestSignIn,
                                         subscribe: { [communities] in communities.toggleSubscription(slug) })
        vc.onTitleHidden = { hidden in
            // Never during a SwiftUI update: the title is SwiftUI state.
            DispatchQueue.main.async { onTitleHidden(hidden) }
        }
        vc.update(community)
        return vc
    }

    func updateUIViewController(_ vc: CommunityViewController, context: Context) {
        vc.update(community)
        vc.setSignedIn(isSignedIn)
    }
}

/// The header pager with the community's three pages.
final class CommunityViewController: UIViewController {
    var onTitleHidden: ((Bool) -> Void)?

    private let header: CommunityHeaderView
    private let feeds: [FeedViewController]
    private let rules = RulesViewController()
    private let pager: HeaderPagerViewController
    private var shown: Community?
    private var isSignedIn: Bool

    init(slug: String, posts: PostStore, feed: any FeedService, isSignedIn: Bool,
         open: @escaping (Route) -> Void, requestSignIn: @escaping () -> Void, subscribe: @escaping () -> Void) {
        self.isSignedIn = isSignedIn
        header = CommunityHeaderView(slug: slug)
        header.onSubscribe = subscribe
        feeds = [API.FeedSort.new, .hot].map { sort in
            let model = FeedModel(source: .community(slug: slug, sort: sort), service: feed, store: posts,
                                  isSignedIn: isSignedIn, requestSignIn: requestSignIn)
            return FeedViewController(model: model, open: open, requestSignIn: requestSignIn)
        }
        pager = HeaderPagerViewController(header: header, titles: ["Лента", "Популярное", "Правила"],
                                          pages: feeds + [rules])
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

    func update(_ community: Community?) {
        guard community != shown else { return }
        let layoutChanged = community?.description != shown?.description || community?.title != shown?.title
            || (community == nil) != (shown == nil)
        shown = community
        header.configure(community)
        rules.configure(community?.rules)
        if layoutChanged {
            pager.headerDidChange()
        }
    }

    func setSignedIn(_ signedIn: Bool) {
        guard signedIn != isSignedIn else { return }
        isSignedIn = signedIn
        for feed in feeds {
            Task { await feed.model.sessionChanged(signedIn: signedIn) }
        }
    }
}
