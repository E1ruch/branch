import Core
import DesignSystem
import Networking
import UIKit

/// A post with its comments, or a continued branch, in one UICollectionView:
/// the tree is already a flat list in display order, so every row is a cell
/// indented by depth. Heights come precomputed from the model, like the feed.
final class ThreadViewController: UIViewController, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    let model: ThreadModel
    private let open: (Route) -> Void
    private let requestSignIn: () -> Void
    private let continueStory: (Post) -> Void
    var onTitle: ((String) -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!
    private let composer = ComposerView()
    private let composerBackground = UIView()
    private var didStartLoading = false
    /// While the keyboard is up, a tap on the thread only puts it away (the
    /// system animation; the field follows through the keyboard guide)
    /// instead of folding a comment. Buttons in cells still work.
    private let dismissKeyboardTap = UITapGestureRecognizer()

    init(model: ThreadModel, open: @escaping (Route) -> Void, requestSignIn: @escaping () -> Void,
         continueStory: @escaping (Post) -> Void) {
        self.model = model
        self.open = open
        self.requestSignIn = requestSignIn
        self.continueStory = continueStory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.surface

        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.backgroundColor = Palette.surface
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.delegate = self
        collectionView.accessibilityIdentifier = "thread"
        for (cell, id) in [(PostDetailCell.self, PostDetailCell.reuseID), (CommentCell.self, CommentCell.reuseID),
                           (StubCell.self, StubCell.reuseID), (CommentsHeaderCell.self, CommentsHeaderCell.reuseID),
                           (BranchHeaderCell.self, BranchHeaderCell.reuseID), (ThreadStatusCell.self, ThreadStatusCell.reuseID),
                           (StoryCell.self, StoryCell.reuseID)]
            as [(UICollectionViewCell.Type, String)] {
            collectionView.register(cell, forCellWithReuseIdentifier: id)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] cv, indexPath, row in
            self?.cell(for: row, in: cv, at: indexPath) ?? UICollectionViewCell()
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

        composerBackground.backgroundColor = Palette.surface
        for v in [collectionView!, composerBackground, composer] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        // The keyboard guide follows the keyboard, interactive dismissal
        // included, and sits on the safe area when the keyboard is down.
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: composer.topAnchor),
            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            composerBackground.topAnchor.constraint(equalTo: composer.topAnchor),
            composerBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        dismissKeyboardTap.addTarget(self, action: #selector(dismissKeyboard))
        dismissKeyboardTap.delegate = self
        dismissKeyboardTap.isEnabled = false
        collectionView.addGestureRecognizer(dismissKeyboardTap)

        composer.isSignedIn = model.isSignedIn
        composer.onSignIn = requestSignIn
        composer.onEditingChanged = { [weak self] editing in self?.dismissKeyboardTap.isEnabled = editing }
        composer.onSend = { [weak self] text, replyTo in
            guard let self, let row = model.send(text, replyTo: replyTo) else { return }
            composer.clear()
            scroll(to: row, position: .centeredVertically)
        }
        model.onSendFailed = { [weak self] text, parentID, error in
            guard let self else { return }
            composer.restore(text: text, replyTo: parentID,
                             author: parentID.flatMap { self.model.comments[$0]?.author?.username },
                             error: Self.sendErrorText(error))
        }
        model.onChange = { [weak self] change in self?.apply(change) }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            Task { await self.updateWidth() }
        }
        apply(.reload)
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

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl) // votes, «Ответить», the sort menu
    }

    private func updateWidth() async {
        await model.setWidth(view.bounds.width, category: traitCollection.preferredContentSizeCategory)
    }

    func setSession(signedIn: Bool, viewer: AuthorRef?) {
        composer.isSignedIn = signedIn
        Task { await model.sessionChanged(signedIn: signedIn, viewer: viewer) }
    }

    // MARK: Cells

    private func cell(for row: Row, in cv: UICollectionView, at indexPath: IndexPath) -> UICollectionViewCell {
        switch row {
        case .post:
            let cell = cv.dequeueReusableCell(withReuseIdentifier: PostDetailCell.reuseID, for: indexPath) as! PostDetailCell
            cell.configure(post: model.post, layout: model.postLayout, fonts: model.fonts,
                           canContinue: model.canContinueStory, animateVote: false)
            cell.onAction = { [weak self] action in self?.handle(action) }
            return cell
        case .story:
            let cell = cv.dequeueReusableCell(withReuseIdentifier: StoryCell.reuseID, for: indexPath) as! StoryCell
            configure(cell)
            return cell
        case .branchHeader:
            let cell = cv.dequeueReusableCell(withReuseIdentifier: BranchHeaderCell.reuseID, for: indexPath) as! BranchHeaderCell
            configure(cell)
            return cell
        case .commentsHeader:
            let cell = cv.dequeueReusableCell(withReuseIdentifier: CommentsHeaderCell.reuseID, for: indexPath) as! CommentsHeaderCell
            cell.configure(count: model.post?.commentCount, sort: model.sort, fonts: model.fonts)
            cell.onSort = { [weak self] sort in Task { await self?.model.setSort(sort) } }
            return cell
        case let .comment(id):
            let cell = cv.dequeueReusableCell(withReuseIdentifier: CommentCell.reuseID, for: indexPath) as! CommentCell
            configure(cell, comment: id, animateVote: false)
            return cell
        case let .more(parentID), let .continue(parentID):
            let cell = cv.dequeueReusableCell(withReuseIdentifier: StubCell.reuseID, for: indexPath) as! StubCell
            if let entry = model.stub(for: parentID) {
                cell.configure(entry, baseDepth: model.baseDepth, isLoading: model.loadingStubs.contains(parentID),
                               font: model.fonts.stub)
            }
            return cell
        case .status:
            let cell = cv.dequeueReusableCell(withReuseIdentifier: ThreadStatusCell.reuseID, for: indexPath) as! ThreadStatusCell
            cell.configure(model.status) { [weak self] in Task { await self?.model.load() } }
            return cell
        }
    }

    private func configure(_ cell: CommentCell, comment id: Int64, animateVote: Bool) {
        guard let comment = model.comments[id], let layout = model.layouts[id] else { return }
        let isFirst = dataSource.indexPath(for: .comment(id)).map { indexPath in
            indexPath.item == 0 || {
                switch dataSource.itemIdentifier(for: IndexPath(item: indexPath.item - 1, section: 0)) {
                case .commentsHeader, .branchHeader, .post: true
                default: false
                }
            }()
        } ?? false
        cell.configure(comment: comment, layout: layout, fonts: model.fonts, isOP: model.isOP(comment),
                       isPending: model.pending.contains(id), isCollapsed: model.collapsed.contains(id),
                       isFirst: isFirst, animateVote: animateVote)
        cell.onAction = { [weak self] action in
            switch action {
            case let .vote(direction): self?.model.tapCommentVote(id, direction: direction)
            case .reply: self?.reply(to: id)
            }
        }
    }

    private func configure(_ cell: StoryCell) {
        guard let post = model.post, let story = post.story else { return }
        let (previous, next) = model.neighbourParts
        cell.configure(story: story, currentID: post.id, parts: model.storyParts, previous: previous, next: next,
                       canContinue: model.canContinueStory, fonts: model.fonts)
        cell.onOpen = { [weak self] id in
            Haptics.selection()
            self?.open(.post(id: id))
        }
        cell.onContinue = { [weak self] in
            guard let self, let post = model.post else { return }
            continueStory(post)
        }
    }

    private func configure(_ cell: BranchHeaderCell) {
        cell.configure(postTitle: model.post?.title, hasParent: model.root?.parentId != nil, font: model.fonts.stub)
        cell.onPost = { [weak self] in
            guard let self, let postID = model.postID else { return }
            open(.post(id: postID))
        }
        cell.onUp = { [weak self] in
            guard let self, let parent = model.root?.parentId else { return }
            open(.commentThread(commentID: parent))
        }
    }

    // MARK: Model changes

    private func apply(_ change: ThreadModel.Change) {
        switch change {
        case .reload:
            applySnapshot(animated: false, reconfigure: nil)
            onTitle?(model.title)
        case let .rows(animated, reconfigure):
            applySnapshot(animated: animated && !UIAccessibility.isReduceMotionEnabled, reconfigure: reconfigure)
        case let .inPlace(rows):
            // The same cells with new values: no reload flash, votes animate.
            for row in rows {
                guard let indexPath = dataSource.indexPath(for: row),
                      let cell = collectionView.cellForItem(at: indexPath) else { continue }
                switch (row, cell) {
                case let (.post, cell as PostDetailCell):
                    cell.configure(post: model.post, layout: model.postLayout, fonts: model.fonts,
                                   canContinue: model.canContinueStory, animateVote: true)
                case let (.story, cell as StoryCell):
                    configure(cell)
                case let (.comment(id), cell as CommentCell):
                    configure(cell, comment: id, animateVote: true)
                case let (.commentsHeader, cell as CommentsHeaderCell):
                    cell.configure(count: model.post?.commentCount, sort: model.sort, fonts: model.fonts)
                case let (.branchHeader, cell as BranchHeaderCell):
                    configure(cell)
                case let (.more(parentID), cell as StubCell):
                    if let entry = model.stub(for: parentID) {
                        cell.configure(entry, baseDepth: model.baseDepth, isLoading: model.loadingStubs.contains(parentID),
                                       font: model.fonts.stub)
                    }
                default:
                    break
                }
            }
            onTitle?(model.title)
        }
        updateStates()
    }

    /// `reconfigure` nil: every row that stayed (a reload with new layouts).
    private func applySnapshot(animated: Bool, reconfigure: [Row]?) {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems(model.rows)
        let kept = Set(dataSource.snapshot().itemIdentifiers).intersection(model.rows)
        snapshot.reconfigureItems(reconfigure.map { Array(kept.intersection($0)) } ?? Array(kept))
        // Heights are the delegate's: ask again before the update animates.
        let context = UICollectionViewFlowLayoutInvalidationContext()
        context.invalidateFlowLayoutDelegateMetrics = true
        collectionView.collectionViewLayout.invalidateLayout(with: context)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func updateStates() {
        let failure: APIError? = switch (model.mode, model.postPhase, model.commentsPhase) {
        case let (.post, .failed(error), _) where model.post == nil: error
        case let (.branch, _, .failed(error)) where model.root == nil: error
        default: nil
        }
        guard let failure else {
            contentUnavailableConfiguration = nil
            collectionView.isHidden = false
            return
        }
        var c = UIContentUnavailableConfiguration.empty()
        if failure.code == "not_found" {
            c.image = UIImage(systemName: "doc.questionmark")
            c.text = model.isPostMode ? "Пост не найден" : "Комментарий не найден"
            c.secondaryText = "Возможно, его удалили."
        } else {
            c.image = UIImage(systemName: "wifi.exclamationmark")
            c.text = "Не удалось загрузить"
            c.secondaryText = "Проверьте соединение и попробуйте ещё раз."
            c.button = .vetkaPrimary(title: "Повторить")
            c.buttonProperties.primaryAction = UIAction { [weak self] _ in Task { await self?.model.load() } }
        }
        contentUnavailableConfiguration = c
        collectionView.isHidden = true
    }

    // MARK: Actions

    private func handle(_ action: PostDetailAction) {
        guard let post = model.post else { return }
        switch action {
        case let .vote(direction):
            model.tapPostVote(direction: direction)
        case .share:
            let share = UIActivityViewController(activityItems: [post.title, Route.shareURL(postID: post.id)],
                                                 applicationActivities: nil)
            share.popoverPresentationController?.sourceView = collectionView
            present(share, animated: true)
        case .copyLink:
            UIPasteboard.general.url = Route.shareURL(postID: post.id)
            Haptics.success()
        case .openCommunity:
            open(.community(slug: post.community.slug))
        case .openAuthor:
            if let author = post.author { open(.user(username: author.username)) }
        case .continueStory:
            continueStory(post)
        }
    }

    private func reply(to id: Int64) {
        guard model.isSignedIn else {
            requestSignIn()
            return
        }
        guard let comment = model.comments[id] else { return }
        composer.beginReply(to: id, author: comment.author?.username ?? "комментарий")
        // Once the keyboard is up, keep the comment in sight above the field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.scroll(to: .comment(id), position: .bottom)
        }
    }

    /// "К родительскому": scroll to it and tint it for a moment, or open
    /// the branch above when it is not on this screen.
    private func goToParent(of id: Int64) {
        guard let parent = model.comments[id]?.parentId else { return }
        guard model.comments[parent] != nil else {
            open(.commentThread(commentID: parent))
            return
        }
        model.reveal(parent)
        scroll(to: .comment(parent), position: .top)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let indexPath = dataSource.indexPath(for: .comment(parent)) else { return }
            (collectionView.cellForItem(at: indexPath) as? CommentCell)?.flash()
        }
    }

    /// A fold near the end shrinks the list under the finger: keep the
    /// folded comment on screen instead of letting it slide away.
    private func toggleCollapse(_ id: Int64) {
        model.toggleCollapse(id)
        collectionView.layoutIfNeeded()
        guard let indexPath = dataSource.indexPath(for: .comment(id)),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        collectionView.scrollRectToVisible(frame, animated: true)
    }

    private func scroll(to row: Row, position: UICollectionView.ScrollPosition) {
        guard let indexPath = dataSource.indexPath(for: row) else { return }
        collectionView.layoutIfNeeded()
        collectionView.scrollToItem(at: indexPath, at: position, animated: true)
    }

    static func sendErrorText(_ error: APIError) -> String {
        switch error.code {
        case "rate_limited": return "Слишком часто. Попробуйте через пару минут."
        case "validation_failed": return "Комментарий слишком длинный."
        case "parent_not_found": return "Комментарий, на который вы отвечаете, удалён."
        case "not_found": return "Пост удалён."
        default: break
        }
        if case .transport = error { return "Нет соединения — комментарий не отправлен." }
        return "Не удалось отправить комментарий."
    }

    // MARK: UICollectionViewDelegateFlowLayout

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = collectionView.bounds.width
        let height: CGFloat = switch dataSource.itemIdentifier(for: indexPath) {
        case .post:
            // A story row continues the post: no gap strip between them.
            model.postLayout.map { model.post?.story != nil ? $0.contentHeight : $0.height }
                ?? PostDetailLayout.placeholderHeight
        case .story: StoryCell.height
        case .branchHeader: BranchHeaderCell.height
        case .commentsHeader: CommentsHeaderCell.height
        case let .comment(id):
            model.layouts[id].map { model.collapsed.contains(id) ? $0.collapsedHeight : $0.height } ?? 60
        case .more, .continue: StubCell.height
        case .status: ThreadStatusCell.height(for: model.status)
        case nil: 0
        }
        return CGSize(width: width, height: height)
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        Task { await model.loadMoreIfNeeded(displaying: indexPath.item) }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .comment, .more, .continue: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case let .comment(id):
            toggleCollapse(id)
        case let .more(parentID):
            Task { await model.expandStub(parentID: parentID) }
        case let .continue(parentID):
            open(.commentThread(commentID: parentID))
        default:
            break
        }
    }

    /// Long press on a comment: reply, votes, parent, copy, author.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, case let .comment(id) = dataSource.itemIdentifier(for: indexPath),
              let comment = model.comments[id], !model.pending.contains(id) else { return nil }
        let deleted = comment.isDeleted || comment.body == nil
        return UIContextMenuConfiguration(identifier: id as NSNumber, previewProvider: nil) { [weak self] _ in
            var children: [UIMenuElement] = []
            if !deleted {
                children.append(UIMenu(options: .displayInline, children: [
                    UIAction(title: "Ответить", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in self?.reply(to: id) },
                    UIAction(title: "Плюс", image: UIImage(systemName: "arrowshape.up"), state: comment.myVote == 1 ? .on : .off) { _ in
                        self?.model.tapCommentVote(id, direction: 1)
                    },
                    UIAction(title: "Минус", image: UIImage(systemName: "arrowshape.down"), state: comment.myVote == -1 ? .on : .off) { _ in
                        self?.model.tapCommentVote(id, direction: -1)
                    },
                ]))
            }
            if comment.parentId != nil {
                children.append(UIAction(title: "К родительскому", image: UIImage(systemName: "arrow.up.to.line")) { _ in
                    self?.goToParent(of: id)
                })
            }
            children.append(UIAction(title: self?.model.collapsed.contains(id) == true ? "Развернуть" : "Свернуть ветку",
                                     image: UIImage(systemName: "rectangle.compress.vertical")) { _ in
                self?.toggleCollapse(id)
            })
            if let body = comment.body, !deleted {
                children.append(UIAction(title: "Скопировать текст", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = body
                    Haptics.success()
                })
            }
            if let author = comment.author {
                children.append(UIAction(title: "Профиль автора", image: UIImage(systemName: "person")) { _ in
                    self?.open(.user(username: author.username))
                })
            }
            return UIMenu(children: children)
        }
    }
}
