import Core
import FeedUI
import Stores
import UIKit

/// Holds one FeedViewController per kind and shows the selected one, so
/// switching is instant and each feed keeps its scroll position.
public final class FeedContainerViewController: UIViewController {
    private let service: any FeedService
    private let store: PostStore
    private let open: (Route) -> Void
    private let requestSignIn: () -> Void
    private var isSignedIn: Bool
    private var feeds: [FeedKind: FeedViewController] = [:]
    private var current: FeedKind?

    public init(service: any FeedService, store: PostStore, isSignedIn: Bool,
                open: @escaping (Route) -> Void, requestSignIn: @escaping () -> Void) {
        self.service = service
        self.store = store
        self.isSignedIn = isSignedIn
        self.open = open
        self.requestSignIn = requestSignIn
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func show(_ kind: FeedKind) {
        guard kind != current else { return }
        let feed = feeds[kind] ?? makeFeed(kind)
        for (other, vc) in feeds where other != kind {
            vc.setVisible(false)
        }
        feed.setVisible(true)
        current = kind
    }

    /// Re-taps and status bar taps.
    public func scrollToTop() {
        if let current { feeds[current]?.scrollToTop() }
    }

    public func setSignedIn(_ signedIn: Bool) {
        guard signedIn != isSignedIn else { return }
        isSignedIn = signedIn
        store.sessionChanged()
        for feed in feeds.values {
            Task { await feed.model.sessionChanged(signedIn: signedIn) }
        }
    }

    private func makeFeed(_ kind: FeedKind) -> FeedViewController {
        let model = FeedModel(source: kind.source, service: service, store: store, isSignedIn: isSignedIn, requestSignIn: requestSignIn,
                              category: traitCollection.preferredContentSizeCategory)
        let feed = FeedViewController(model: model, open: open, requestSignIn: requestSignIn)
        addChild(feed)
        feed.view.frame = view.bounds
        feed.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(feed.view)
        feed.didMove(toParent: self)
        feeds[kind] = feed
        return feed
    }
}
