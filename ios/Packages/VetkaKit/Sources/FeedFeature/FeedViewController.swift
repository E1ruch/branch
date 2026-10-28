import Core
import DesignSystem
import Stores
import UIKit

/// One feed in a UICollectionView. Flow layout with precomputed heights:
/// the layout asks for sizes, the model already has them, nothing is
/// measured while scrolling.
final class FeedViewController: UIViewController, UICollectionViewDelegateFlowLayout {
    let model: FeedModel
    private let open: (Route) -> Void
    private let requestSignIn: () -> Void
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Int64>!
    private let skeleton = SkeletonFeedView()
    private var didStartLoading = false

    init(model: FeedModel, open: @escaping (Route) -> Void, requestSignIn: @escaping () -> Void) {
        self.model = model
        self.open = open
        self.requestSignIn = requestSignIn
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = Palette.background
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.register(PostCell.self, forCellWithReuseIdentifier: PostCell.reuseID)
        collectionView.accessibilityIdentifier = "feed.\(model.kind.rawValue)"
        view.addSubview(collectionView)

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] cv, indexPath, id in
            let cell = cv.dequeueReusableCell(withReuseIdentifier: PostCell.reuseID, for: indexPath) as! PostCell
            guard let self, let post = model.posts[id], let layout = model.layouts[id] else { return cell }
            cell.configure(post: post, layout: layout, fonts: model.fonts, animateVote: false)
            cell.onAction = { [weak self] action in self?.handle(action, post: id) }
            return cell
        }

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in
            Haptics.snap()
            Task { [weak self] in
                await self?.model.load()
                self?.collectionView.refreshControl?.endRefreshing()
            }
        }, for: .valueChanged)
        collectionView.refreshControl = refresh

        skeleton.frame = view.bounds
        skeleton.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(skeleton)

        model.onChange = { [weak self] change in self?.apply(change) }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            Task { await self.updateWidth() }
        }
        updateStates()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        Haptics.prepare()
        Task {
            await updateWidth()
            if !didStartLoading {
                didStartLoading = true
                await model.load()
            }
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            Task { await self?.updateWidth() }
        }
    }

    private func updateWidth() async {
        await model.setWidth(view.bounds.width, category: traitCollection.preferredContentSizeCategory)
    }

    func scrollToTop() {
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
    }

    /// Only the visible feed answers the status bar tap.
    func setVisible(_ visible: Bool) {
        view.isHidden = !visible
        collectionView?.scrollsToTop = visible
    }

    // MARK: Model changes

    private func apply(_ change: FeedModel.Change) {
        switch change {
        case .list:
            var snapshot = NSDiffableDataSourceSnapshot<Int, Int64>()
            snapshot.appendSections([0])
            snapshot.appendItems(model.ids)
            // Posts that stayed may have new text or counters after a refresh.
            let kept = Set(dataSource.snapshot().itemIdentifiers).intersection(model.ids)
            snapshot.reconfigureItems(Array(kept))
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.collectionViewLayout.invalidateLayout()
        case let .posts(ids):
            // Reconfigure in place: the same cell, new counters, no reload
            // flash. Done directly so the vote can animate.
            for id in ids {
                guard let indexPath = dataSource.indexPath(for: id),
                      let cell = collectionView.cellForItem(at: indexPath) as? PostCell,
                      let post = model.posts[id], let layout = model.layouts[id] else { continue }
                cell.configure(post: post, layout: layout, fonts: model.fonts, animateVote: true)
            }
        case .phase:
            break
        }
        updateStates()
    }

    private func updateStates() {
        let loading = model.phase == .loading && model.ids.isEmpty
        if skeleton.isHidden == loading {
            UIView.transition(with: view, duration: 0.2, options: .transitionCrossDissolve) {
                self.skeleton.isHidden = !loading
            }
        }

        var config: UIContentUnavailableConfiguration?
        switch model.phase {
        case .signInRequired:
            var c = UIContentUnavailableConfiguration.empty()
            c.image = UIImage(systemName: "person.crop.circle.badge.plus")
            c.text = "Ваши подписки"
            c.secondaryText = "Войдите, чтобы видеть посты сообществ, на которые вы подписаны."
            c.button = .vetkaPrimary(title: "Войти")
            c.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.requestSignIn() }
            config = c
        case .failed:
            var c = UIContentUnavailableConfiguration.empty()
            c.image = UIImage(systemName: "wifi.exclamationmark")
            c.text = "Не удалось загрузить"
            c.secondaryText = "Проверьте соединение и попробуйте ещё раз."
            c.button = .vetkaPrimary(title: "Повторить")
            c.buttonProperties.primaryAction = UIAction { [weak self] _ in Task { await self?.model.load() } }
            config = c
        case .loaded where model.ids.isEmpty:
            var c = UIContentUnavailableConfiguration.empty()
            c.image = UIImage(systemName: model.kind == .subscriptions ? "square.grid.2x2" : "leaf")
            c.text = model.kind == .subscriptions ? "Пока пусто" : "Постов ещё нет"
            c.secondaryText = model.kind == .subscriptions
                ? "Подпишитесь на сообщества — их посты появятся здесь."
                : "Станьте первым, кто что-нибудь опубликует."
            config = c
        default:
            config = nil
        }
        contentUnavailableConfiguration = config
    }

    // MARK: UICollectionViewDelegateFlowLayout

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let id = dataSource.itemIdentifier(for: indexPath)
        let height = id.flatMap { model.layouts[$0]?.height } ?? 120
        return CGSize(width: collectionView.bounds.width, height: height)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        Task { await model.loadMoreIfNeeded(displaying: indexPath.item) }
    }

    /// Long press: the same actions as the "⋯" menu plus the votes, with
    /// the system's lifted preview and haptic.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let id = dataSource.itemIdentifier(for: indexPath),
              let post = model.posts[id] else { return nil }
        return UIContextMenuConfiguration(identifier: id as NSNumber, previewProvider: nil) { [weak self] _ in
            let act: (PostAction) -> UIActionHandler = { action in { _ in self?.handle(action, post: id) } }
            let votes = UIMenu(options: .displayInline, children: [
                UIAction(title: "Плюс", image: UIImage(systemName: "arrowshape.up"),
                         state: post.myVote == 1 ? .on : .off, handler: act(.vote(1))),
                UIAction(title: "Минус", image: UIImage(systemName: "arrowshape.down"),
                         state: post.myVote == -1 ? .on : .off, handler: act(.vote(-1))),
            ])
            return UIMenu(children: [
                votes,
                UIAction(title: "Поделиться", image: UIImage(systemName: "square.and.arrow.up"), handler: act(.share)),
                UIAction(title: "Скопировать ссылку", image: UIImage(systemName: "link"), handler: act(.copyLink)),
                UIAction(title: post.community.title, image: UIImage(systemName: "square.grid.2x2"), handler: act(.openCommunity)),
                UIAction(title: "Профиль автора", image: UIImage(systemName: "person"),
                         attributes: post.author == nil ? .disabled : [], handler: act(.openAuthor)),
            ])
        }
    }

    private func handle(_ action: PostAction, post id: Int64) {
        guard let post = model.posts[id] else { return }
        switch action {
        case let .vote(direction):
            model.tapVote(id, direction: direction)
        case .share:
            let share = UIActivityViewController(activityItems: [post.title, Route.shareURL(postID: id)], applicationActivities: nil)
            if let cell = dataSource.indexPath(for: id).flatMap({ collectionView.cellForItem(at: $0) }) {
                share.popoverPresentationController?.sourceView = cell
            }
            present(share, animated: true)
        case .copyLink:
            UIPasteboard.general.url = Route.shareURL(postID: id)
            Haptics.success()
        case .openCommunity:
            open(.community(slug: post.community.slug))
        case .openAuthor:
            if let author = post.author {
                open(.user(username: author.username))
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if let id = dataSource.itemIdentifier(for: indexPath) {
            open(.post(id: id))
        }
    }
}

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
        let model = FeedModel(kind: kind, service: service, store: store, isSignedIn: isSignedIn, requestSignIn: requestSignIn,
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
