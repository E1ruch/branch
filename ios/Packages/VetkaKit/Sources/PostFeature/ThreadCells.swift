import Core
import DesignSystem
import Networking
import UIKit

/// What the post at the top of the screen can ask for.
enum PostDetailAction {
    case vote(Int)
    case share
    case copyLink
    case openCommunity
    case openAuthor
    case continueStory
    /// The "⋯" button, passed along so the menu grows out of it.
    case more(UIView)
}

/// The post itself: header, title, the whole body, votes. Frames come from
/// PostDetailLayout; nothing is measured here.
final class PostDetailCell: UICollectionViewCell {
    static let reuseID = "PostDetailCell"

    private let avatar = AvatarLabel()
    private let authorButton = UIButton(type: .custom)
    private let communityButton = UIButton(type: .custom)
    private let authorLabel = UILabel()
    private let metaLabel = UILabel()
    private let moreButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let votes = VoteControl()
    private let commentsLabel = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let gapView = UIView()
    private let skeleton = ThreadSkeletonView(style: .post)
    private var layout: PostDetailLayout?

    var onAction: ((PostDetailAction) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Palette.surface
        for label in [authorLabel, metaLabel, titleLabel, bodyLabel] {
            label.backgroundColor = Palette.surface
            contentView.addSubview(label)
        }
        authorLabel.textColor = Palette.textPrimary
        metaLabel.textColor = Palette.textSecondary
        titleLabel.numberOfLines = 0
        titleLabel.textColor = Palette.textPrimary
        titleLabel.accessibilityTraits = .header
        bodyLabel.numberOfLines = 0
        bodyLabel.textColor = Palette.textPrimary
        gapView.backgroundColor = Palette.background

        // Like a feed cell: the author on top, "18 ч назад · Котики" under it.
        // The name opens the profile, the line under it the community.
        authorButton.addAction(UIAction { [weak self] _ in self?.onAction?(.openAuthor) }, for: .touchUpInside)
        communityButton.addAction(UIAction { [weak self] _ in self?.onAction?(.openCommunity) }, for: .touchUpInside)

        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = Palette.iconSecondary
        moreButton.accessibilityLabel = "Ещё"
        moreButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            onAction?(.more(moreButton))
        }, for: .touchUpInside)

        commentsLabel.tintColor = Palette.iconSecondary
        commentsLabel.isUserInteractionEnabled = false
        shareButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        shareButton.tintColor = Palette.iconSecondary
        shareButton.accessibilityLabel = "Поделиться"
        shareButton.addAction(UIAction { [weak self] _ in self?.onAction?(.share) }, for: .touchUpInside)
        votes.onVote = { [weak self] direction in self?.onAction?(.vote(direction)) }

        for view in [avatar, authorButton, communityButton, moreButton, votes, commentsLabel, shareButton, gapView, skeleton] as [UIView] {
            contentView.addSubview(view)
        }
        contentView.accessibilityElements = [titleLabel, authorButton, communityButton, bodyLabel, votes, commentsLabel, shareButton, moreButton]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// `post` nil: the post is still loading, show its outline.
    func configure(post: Post?, layout: PostDetailLayout?, fonts: ThreadFonts, animateVote: Bool) {
        self.layout = layout
        guard let post, let layout else {
            skeleton.isHidden = false
            for view in contentView.subviews where view !== skeleton { view.isHidden = true }
            return
        }
        skeleton.isHidden = true
        for view in contentView.subviews where view !== skeleton { view.isHidden = false }

        let author = post.author?.username ?? "удалённый аккаунт"
        avatar.configure(name: author)
        authorLabel.font = fonts.postAuthor
        authorLabel.text = author
        authorButton.isEnabled = post.author != nil
        authorButton.accessibilityLabel = "Автор \(author)"
        metaLabel.font = fonts.postMeta
        var meta = [RelativeAge.text(from: post.createdAt, now: Date()), post.community.title]
        if post.editedAt != nil { meta.append("изменено") }
        if post.isNsfw { meta.append("18+") }
        metaLabel.text = meta.joined(separator: " · ")
        communityButton.accessibilityLabel = "\(meta.joined(separator: ", ")). Открыть сообщество \(post.community.title)"
        titleLabel.font = fonts.postTitle
        titleLabel.text = post.title
        bodyLabel.font = fonts.postBody
        bodyLabel.text = layout.body
        bodyLabel.isHidden = layout.body.isEmpty

        var attributes = AttributeContainer()
        attributes.font = fonts.footer
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "bubble.left", withConfiguration: UIImage.SymbolConfiguration(font: fonts.footer))
        config.imagePadding = 5
        config.attributedTitle = AttributedString(post.commentCount.compactFormatted, attributes: attributes)
        config.baseForegroundColor = Palette.iconSecondary
        config.contentInsets = .zero
        commentsLabel.configuration = config
        commentsLabel.accessibilityLabel = "\(post.commentCount) \(post.commentCount.ru("комментарий", "комментария", "комментариев"))"

        votes.configure(score: post.score, myVote: post.myVote, font: fonts.footer, animated: animateVote)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        skeleton.frame = contentView.bounds
        guard let layout else { return }
        avatar.frame = layout.avatarFrame
        authorLabel.frame = layout.authorFrame
        metaLabel.frame = layout.metaFrame
        authorButton.frame = layout.avatarFrame.union(layout.authorFrame)
        communityButton.frame = layout.metaFrame.insetBy(dx: 0, dy: -4)
        moreButton.frame = layout.moreFrame
        titleLabel.frame = layout.titleFrame
        bodyLabel.frame = layout.bodyFrame
        let footer = layout.footerFrame
        votes.frame = CGRect(x: footer.minX, y: footer.minY, width: VoteControl.width, height: footer.height)
        commentsLabel.frame = CGRect(x: votes.frame.maxX + 10, y: footer.minY, width: 80, height: footer.height)
        commentsLabel.contentHorizontalAlignment = .leading
        shareButton.frame = CGRect(x: footer.maxX - 44, y: footer.minY, width: 44, height: footer.height)
        gapView.frame = CGRect(x: 0, y: layout.contentHeight, width: bounds.width, height: bounds.height - layout.contentHeight)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
    }
}

/// What a comment can ask for.
enum CommentAction {
    case vote(Int)
    case reply
}

/// One comment: thread lines for its ancestors, a header line, the text and
/// a footer with votes and «Ответить». No Auto Layout: frames come from
/// CommentLayout, the thread lines are one shape layer.
final class CommentCell: UICollectionViewCell {
    static let reuseID = "CommentCell"

    private let guides = CAShapeLayer()
    private let divider = UIView()
    private let avatar = AvatarLabel()
    private let headerLabel = UILabel()
    private let bodyLabel = UILabel()
    private let votes = VoteControl()
    private let replyButton = UIButton(type: .system)
    private var layout: CommentLayout?
    private var isCollapsed = false
    private var flashView: UIView?

    var onAction: ((CommentAction) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Palette.surface
        guides.lineWidth = 1.5
        guides.fillColor = nil
        contentView.layer.addSublayer(guides)
        divider.backgroundColor = Palette.borderSubtle
        for label in [headerLabel, bodyLabel] {
            label.backgroundColor = Palette.surface
        }
        headerLabel.lineBreakMode = .byTruncatingTail
        bodyLabel.numberOfLines = 0

        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "arrowshape.turn.up.left")
        config.imagePadding = 5
        config.baseForegroundColor = Palette.iconSecondary
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
        replyButton.configuration = config
        replyButton.addAction(UIAction { [weak self] _ in self?.onAction?(.reply) }, for: .touchUpInside)
        votes.onVote = { [weak self] direction in self?.onAction?(.vote(direction)) }

        for view in [divider, avatar, headerLabel, bodyLabel, votes, replyButton] as [UIView] {
            contentView.addSubview(view)
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.guides.strokeColor = Palette.border.resolvedColor(with: self.traitCollection).cgColor
        }
        guides.strokeColor = Palette.border.resolvedColor(with: traitCollection).cgColor
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(comment: Comment, layout: CommentLayout, fonts: ThreadFonts, isOP: Bool, isPending: Bool,
                   isCollapsed: Bool, isFirst: Bool, animateVote: Bool) {
        self.layout = layout
        self.isCollapsed = isCollapsed
        let deleted = comment.isDeleted || comment.body == nil
        let name = comment.author?.username ?? (deleted ? "удалено" : "удалённый аккаунт")
        avatar.configure(name: name)
        avatar.alpha = deleted ? 0.4 : 1

        let header = NSMutableAttributedString(string: name, attributes: [
            .font: fonts.commentAuthor,
            .foregroundColor: isOP ? Palette.accent : (deleted ? Palette.textSecondary : Palette.textPrimary),
        ])
        var meta: [String] = []
        if isOP { meta.append("автор") }
        meta.append(isPending ? "отправка…" : RelativeAge.text(from: comment.createdAt, now: Date()))
        if comment.editedAt != nil { meta.append("изменено") }
        if isCollapsed {
            meta.append(comment.score.compactFormatted)
            if comment.replyCount > 0 {
                meta.append("+\(comment.replyCount) \(comment.replyCount.ru("ответ", "ответа", "ответов"))")
            }
        }
        header.append(NSAttributedString(string: "  " + meta.joined(separator: " · "), attributes: [
            .font: fonts.commentHeader, .foregroundColor: Palette.textSecondary,
        ]))
        headerLabel.attributedText = header

        bodyLabel.font = deleted ? fonts.commentDeleted : fonts.commentBody
        bodyLabel.textColor = deleted ? Palette.textSecondary : Palette.textPrimary
        bodyLabel.text = layout.body
        bodyLabel.isHidden = isCollapsed

        let showsFooter = !deleted && !isCollapsed
        votes.isHidden = !showsFooter
        replyButton.isHidden = !showsFooter
        if showsFooter {
            votes.configure(score: comment.score, myVote: comment.myVote, font: fonts.footer, animated: animateVote)
            var config = replyButton.configuration
            var title = AttributeContainer()
            title.font = fonts.stub
            config?.attributedTitle = AttributedString("Ответить", attributes: title)
            config?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(font: fonts.stub)
            replyButton.configuration = config
        }
        divider.isHidden = layout.level != 0 || isFirst
        contentView.alpha = isPending ? 0.55 : 1
        contentView.isUserInteractionEnabled = !isPending

        // VoiceOver reads one element per comment, with actions for the rest.
        isAccessibilityElement = true
        accessibilityLabel = "\(name), \(meta.joined(separator: ", ")). \(isCollapsed ? "Свёрнуто" : layout.body)"
        accessibilityValue = deleted ? nil : "Рейтинг \(comment.score)"
        accessibilityHint = isCollapsed ? "Развернуть" : "Свернуть ветку"
        accessibilityCustomActions = showsFooter ? [
            UIAccessibilityCustomAction(name: "Ответить") { [weak self] _ in self?.onAction?(.reply); return true },
            UIAccessibilityCustomAction(name: comment.myVote == 1 ? "Убрать плюс" : "Плюс") { [weak self] _ in
                self?.onAction?(.vote(1)); return true
            },
            UIAccessibilityCustomAction(name: comment.myVote == -1 ? "Убрать минус" : "Минус") { [weak self] _ in
                self?.onAction?(.vote(-1)); return true
            },
        ] : []
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout else { return }
        guides.frame = contentView.bounds
        let path = UIBezierPath()
        for level in 0..<layout.level {
            let x = CommentLayout.guideX(level: level)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: bounds.height))
        }
        guides.path = path.cgPath
        divider.frame = CGRect(x: CommentLayout.inset, y: 0, width: bounds.width - CommentLayout.inset,
                               height: 1 / max(traitCollection.displayScale, 1))
        avatar.frame = layout.avatarFrame
        headerLabel.frame = layout.headerFrame
        bodyLabel.frame = layout.bodyFrame
        let footer = layout.footerFrame
        votes.frame = CGRect(x: footer.minX, y: footer.minY, width: VoteControl.width, height: footer.height)
        replyButton.sizeToFit()
        replyButton.frame = CGRect(x: votes.frame.maxX + 4, y: footer.minY,
                                   width: replyButton.bounds.width, height: footer.height)
    }

    override var isHighlighted: Bool {
        didSet {
            let color = isHighlighted ? Palette.surfaceHover : Palette.surface
            UIView.animate(withDuration: isHighlighted ? 0 : 0.25) {
                self.contentView.backgroundColor = color
                self.headerLabel.backgroundColor = color
                self.bodyLabel.backgroundColor = color
            }
        }
    }

    /// "К родительскому": a brief brand tint over the comment it scrolled to.
    func flash() {
        let view = UIView(frame: contentView.bounds)
        view.backgroundColor = Palette.brandLight
        view.alpha = 0
        view.isUserInteractionEnabled = false
        contentView.insertSubview(view, at: 0)
        for label in [headerLabel, bodyLabel] { label.backgroundColor = .clear }
        UIView.animate(withDuration: 0.2) { view.alpha = 1 } completion: { _ in
            UIView.animate(withDuration: 0.6, delay: 0.5) { view.alpha = 0 } completion: { _ in
                view.removeFromSuperview()
                for label in [self.headerLabel, self.bodyLabel] { label.backgroundColor = Palette.surface }
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
    }
}

/// "Ещё N ответов" (loads in place) or "Продолжить ветку" (opens a screen),
/// indented like the replies it stands for.
final class StubCell: UICollectionViewCell {
    static let reuseID = "StubCell"
    static let height: CGFloat = 40

    private let guides = CAShapeLayer()
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var level = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Palette.surface
        guides.lineWidth = 1.5
        guides.fillColor = nil
        contentView.layer.addSublayer(guides)
        label.textColor = Palette.accent
        label.backgroundColor = Palette.surface
        contentView.addSubview(label)
        contentView.addSubview(spinner)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.guides.strokeColor = Palette.border.resolvedColor(with: self.traitCollection).cgColor
        }
        guides.strokeColor = Palette.border.resolvedColor(with: traitCollection).cgColor
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ entry: Entry, baseDepth: Int, isLoading: Bool, font: UIFont) {
        let text: String
        let depth: Int
        switch entry {
        case let .more(_, d, count, _):
            depth = d
            text = "Ещё \(count) \(count.ru("ответ", "ответа", "ответов"))"
        case let .continue(_, d, count):
            depth = d
            text = "Продолжить ветку · \(count) \(count.ru("ответ", "ответа", "ответов")) ›"
        case .comment:
            return
        }
        level = CommentLayout.level(depth: depth, baseDepth: baseDepth)
        label.font = font
        label.text = isLoading ? "Загрузка…" : text
        isLoading ? spinner.startAnimating() : spinner.stopAnimating()
        accessibilityLabel = text
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guides.frame = contentView.bounds
        let path = UIBezierPath()
        for l in 0..<level {
            let x = CommentLayout.guideX(level: l)
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: bounds.height))
        }
        guides.path = path.cgPath
        let x = CommentLayout.indent(level: level)
        if spinner.isAnimating {
            spinner.frame = CGRect(x: x, y: 0, width: 20, height: bounds.height)
            label.frame = CGRect(x: x + 26, y: 0, width: bounds.width - x - 42, height: bounds.height - 6)
        } else {
            label.frame = CGRect(x: x, y: 0, width: bounds.width - x - CommentLayout.inset, height: bounds.height - 6)
        }
    }

    override var isHighlighted: Bool {
        didSet { label.alpha = isHighlighted ? 0.5 : 1 }
    }
}

/// "Комментарии 12" and the sort menu.
final class CommentsHeaderCell: UICollectionViewCell {
    static let reuseID = "CommentsHeaderCell"
    static let height: CGFloat = 48

    private let titleLabel = UILabel()
    private let sortButton = UIButton(type: .system)
    var onSort: ((API.CommentSort) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Palette.surface
        titleLabel.textColor = Palette.textPrimary
        titleLabel.backgroundColor = Palette.surface
        titleLabel.accessibilityTraits = .header
        sortButton.showsMenuAsPrimaryAction = true
        sortButton.tintColor = Palette.textSecondary
        contentView.addSubview(titleLabel)
        contentView.addSubview(sortButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(count: Int?, sort: API.CommentSort, fonts: ThreadFonts) {
        let title = NSMutableAttributedString(string: "Комментарии", attributes: [
            .font: fonts.section, .foregroundColor: Palette.textPrimary,
        ])
        if let count, count > 0 {
            title.append(NSAttributedString(string: "  \(count.compactFormatted)", attributes: [
                .font: fonts.section, .foregroundColor: Palette.textSecondary,
            ]))
        }
        titleLabel.attributedText = title

        var config = UIButton.Configuration.plain()
        var attributes = AttributeContainer()
        attributes.font = fonts.stub
        config.attributedTitle = AttributedString(sort.title, attributes: attributes)
        config.image = UIImage(systemName: "chevron.up.chevron.down",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.baseForegroundColor = Palette.textSecondary
        sortButton.configuration = config
        sortButton.accessibilityLabel = "Сортировка: \(sort.title)"
        sortButton.menu = UIMenu(title: "Сортировка", children: [API.CommentSort.best, .new].map { option in
            UIAction(title: option.title, state: option == sort ? .on : .off) { [weak self] _ in self?.onSort?(option) }
        })
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        sortButton.sizeToFit()
        let w = sortButton.bounds.width
        sortButton.frame = CGRect(x: bounds.width - w - 4, y: 0, width: w, height: bounds.height)
        titleLabel.frame = CGRect(x: 16, y: 0, width: sortButton.frame.minX - 24, height: bounds.height)
    }
}

extension API.CommentSort {
    var title: String {
        switch self {
        case .best: "Лучшие"
        case .new: "Новые"
        }
    }
}

/// A branch's links: to the whole post and one level up.
final class BranchHeaderCell: UICollectionViewCell {
    static let reuseID = "BranchHeaderCell"
    static let height: CGFloat = 56

    private let postButton = UIButton(type: .system)
    private let upButton = UIButton(type: .system)
    var onPost: (() -> Void)?
    var onUp: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Palette.surface
        postButton.addAction(UIAction { [weak self] _ in self?.onPost?() }, for: .touchUpInside)
        upButton.addAction(UIAction { [weak self] _ in self?.onUp?() }, for: .touchUpInside)
        contentView.addSubview(postButton)
        contentView.addSubview(upButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(postTitle: String?, hasParent: Bool, font: UIFont) {
        postButton.configuration = Self.pill(postTitle.map { "Весь пост: \($0)" } ?? "Весь пост", icon: "doc.text", font: font)
        upButton.configuration = Self.pill("Выше", icon: "arrow.up", font: font)
        upButton.isHidden = !hasParent
        upButton.accessibilityLabel = "Выше по ветке"
        setNeedsLayout()
    }

    private static func pill(_ title: String, icon: String, font: UIFont) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        var attributes = AttributeContainer()
        attributes.font = font
        config.attributedTitle = AttributedString(title, attributes: attributes)
        config.image = UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(font: font))
        config.imagePadding = 6
        config.cornerStyle = .capsule
        config.baseBackgroundColor = Palette.chipActiveBackground
        config.baseForegroundColor = Palette.chipActiveText
        config.titleLineBreakMode = .byTruncatingTail
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        return config
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h: CGFloat = 34
        let y = (bounds.height - h) / 2
        var right = bounds.width - 16
        if !upButton.isHidden {
            upButton.sizeToFit()
            upButton.frame = CGRect(x: right - upButton.bounds.width, y: y, width: upButton.bounds.width, height: h)
            right = upButton.frame.minX - 8
        }
        postButton.sizeToFit()
        postButton.frame = CGRect(x: 16, y: y, width: min(postButton.bounds.width, right - 16), height: h)
    }
}

/// The bottom of the thread: a skeleton while loading, an empty state, an
/// error with a retry, or a small spinner while the next page loads.
final class ThreadStatusCell: UICollectionViewCell {
    static let reuseID = "ThreadStatusCell"

    private let skeleton = ThreadSkeletonView(style: .comments)
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Palette.surface
        contentView.addSubview(skeleton)
        contentView.addSubview(spinner)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func height(for status: ThreadModel.Status) -> CGFloat {
        switch status {
        case .loading: 300
        case .empty, .failed: 200
        case .loadingMore: 56
        case .none: 0
        }
    }

    func configure(_ status: ThreadModel.Status, retry: @escaping () -> Void) {
        skeleton.isHidden = status != .loading
        status == .loadingMore ? spinner.startAnimating() : spinner.stopAnimating()
        switch status {
        case .empty:
            var c = UIContentUnavailableConfiguration.empty()
            c.image = UIImage(systemName: "bubble.left.and.bubble.right")
            c.imageProperties.tintColor = Palette.iconSecondary
            c.text = "Комментариев пока нет"
            c.secondaryText = "Начните обсуждение первым."
            contentConfiguration = c
        case .failed:
            var c = UIContentUnavailableConfiguration.empty()
            c.image = UIImage(systemName: "wifi.exclamationmark")
            c.text = "Не удалось загрузить комментарии"
            c.button = .vetkaPrimary(title: "Повторить")
            c.buttonProperties.primaryAction = UIAction { _ in retry() }
            contentConfiguration = c
        default:
            contentConfiguration = nil
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        skeleton.frame = contentView.bounds
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/// Placeholder blocks shaped like a post or like comments, with the same
/// single-gradient shimmer as the feed's skeleton.
final class ThreadSkeletonView: UIView {
    enum Style { case post, comments }

    private let style: Style
    private let shimmer = CAGradientLayer()
    private let blocks = CAShapeLayer()

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        backgroundColor = Palette.surface
        isUserInteractionEnabled = false
        layer.addSublayer(blocks)
        shimmer.colors = [UIColor.clear.cgColor, UIColor.white.withAlphaComponent(0.35).cgColor, UIColor.clear.cgColor]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.addSublayer(shimmer)
        isAccessibilityElement = true
        accessibilityLabel = "Загрузка"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath()
        let inset: CGFloat = 16
        let width = bounds.width - inset * 2
        func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            path.append(UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: h / 2.5))
        }
        switch style {
        case .post:
            path.append(UIBezierPath(ovalIn: CGRect(x: inset, y: 14, width: 38, height: 38)))
            bar(inset + 48, 18, width * 0.35, 12)
            bar(inset + 48, 36, width * 0.25, 10)
            var y: CGFloat = 66
            for (w, h, gap) in [(0.9, 20.0, 8.0), (0.55, 20.0, 16.0), (1.0, 14.0, 8.0), (0.96, 14.0, 8.0), (0.8, 14.0, 8.0), (0.6, 14.0, 20.0)] {
                bar(inset, y, width * w, h)
                y += h + gap
            }
            bar(inset, y, 110, 20)
        case .comments:
            var y: CGFloat = 12
            for (level, lines) in [(0, [0.9, 0.6]), (1, [0.8]), (0, [0.95, 0.85, 0.4])] {
                let x = CommentLayout.indent(level: level)
                let w = bounds.width - x - inset
                path.append(UIBezierPath(ovalIn: CGRect(x: x, y: y, width: 22, height: 22)))
                bar(x + 30, y + 6, w * 0.3, 10)
                y += 32
                for line in lines {
                    bar(x, y, w * line, 13)
                    y += 21
                }
                y += 26
            }
        }
        blocks.path = path.cgPath
        blocks.fillColor = Palette.surfaceTertiary.resolvedColor(with: traitCollection).cgColor
        shimmer.frame = bounds
        let mask = CAShapeLayer()
        mask.path = path.cgPath
        shimmer.mask = mask
        guard !UIAccessibility.isReduceMotionEnabled, shimmer.animation(forKey: "shimmer") == nil else { return }
        let move = CABasicAnimation(keyPath: "locations")
        move.fromValue = [-1.0, -0.5, 0.0]
        move.toValue = [1.0, 1.5, 2.0]
        move.duration = 1.2
        move.repeatCount = .infinity
        shimmer.add(move, forKey: "shimmer")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout() // a reused cell's animation is gone after leaving the window
    }
}

/// The story a post belongs to, in one quiet row:
/// ‹  История · Часть 2 из 3  ›. The arrows open the neighbouring parts
/// (dimmed when there is none, so nothing shifts), the middle opens the
/// table of contents. On the last part its author gets "+" instead of ›.
final class StoryCell: UICollectionViewCell {
    static let reuseID = "StoryCell"
    static let rowHeight: CGFloat = 48
    /// The background strip that separates the row from the comments.
    static let gap: CGFloat = 8
    static let height: CGFloat = rowHeight + gap

    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let partsButton = UIButton(type: .system)
    private let topLine = UIView()
    private let gapView = UIView()
    private var previousID: Int64?
    private var nextID: Int64?
    private var continues = false

    var onOpen: ((Int64) -> Void)?
    var onContinue: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Palette.surface
        topLine.backgroundColor = Palette.borderSubtle
        gapView.backgroundColor = Palette.background
        partsButton.showsMenuAsPrimaryAction = true
        previousButton.addAction(UIAction { [weak self] _ in
            if let id = self?.previousID { self?.onOpen?(id) }
        }, for: .touchUpInside)
        nextButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if let id = nextID { onOpen?(id) } else if continues { onContinue?() }
        }, for: .touchUpInside)
        for view in [topLine, previousButton, partsButton, nextButton, gapView] as [UIView] {
            contentView.addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(story: StoryRef, currentID: Int64, parts: [StoryPart], previous: StoryPart?, next: StoryPart?,
                   canContinue: Bool, fonts: ThreadFonts) {
        previousID = previous?.postId
        nextID = next?.postId
        continues = next == nil && story.isLast && canContinue

        let arrow = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        previousButton.setImage(UIImage(systemName: "chevron.left", withConfiguration: arrow), for: .normal)
        previousButton.isEnabled = previous != nil
        previousButton.tintColor = previous != nil ? Palette.accent : Palette.iconDisabled
        previousButton.accessibilityLabel = previous.map { "Часть \($0.part): \($0.title)" } ?? "Это первая часть"

        if continues {
            nextButton.setImage(UIImage(systemName: "plus", withConfiguration: arrow), for: .normal)
            nextButton.accessibilityLabel = "Добавить следующую часть"
        } else {
            nextButton.setImage(UIImage(systemName: "chevron.right", withConfiguration: arrow), for: .normal)
            nextButton.accessibilityLabel = next.map { "Часть \($0.part): \($0.title)" } ?? "Это последняя часть"
        }
        nextButton.isEnabled = next != nil || continues
        nextButton.tintColor = nextButton.isEnabled ? Palette.accent : Palette.iconDisabled

        var config = UIButton.Configuration.plain()
        var muted = AttributeContainer()
        muted.font = fonts.commentHeader
        muted.foregroundColor = Palette.textSecondary
        var strong = AttributeContainer()
        strong.font = fonts.stub
        strong.foregroundColor = Palette.textPrimary
        config.attributedTitle = AttributedString("История · ", attributes: muted)
            + AttributedString("Часть \(story.part) из \(story.parts)", attributes: strong)
        config.image = UIImage(systemName: "book.pages", withConfiguration: UIImage.SymbolConfiguration(font: fonts.stub))
        config.imagePadding = 6
        config.baseForegroundColor = Palette.accent
        config.titleLineBreakMode = .byTruncatingTail
        partsButton.configuration = config
        partsButton.accessibilityLabel = "История, часть \(story.part) из \(story.parts)"
        partsButton.accessibilityHint = parts.count > 1 ? "Все части" : nil
        partsButton.menu = parts.count > 1
            ? UIMenu(title: parts.first.map { "«\($0.title)»" } ?? "", children: parts.map { part in
                UIAction(title: "\(part.part). \(part.title)", state: part.postId == currentID ? .on : .off) { [weak self] _ in
                    if part.postId != currentID { self?.onOpen?(part.postId) }
                }
            })
            : nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = Self.rowHeight
        topLine.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1 / max(traitCollection.displayScale, 1))
        previousButton.frame = CGRect(x: 4, y: 0, width: 48, height: h)
        nextButton.frame = CGRect(x: bounds.width - 52, y: 0, width: 48, height: h)
        partsButton.frame = CGRect(x: previousButton.frame.maxX, y: 0,
                                   width: nextButton.frame.minX - previousButton.frame.maxX, height: h)
        gapView.frame = CGRect(x: 0, y: h, width: bounds.width, height: Self.gap)
    }
}
