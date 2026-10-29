import Core
import DesignSystem
import UIKit

/// What a post cell can ask its feed to do.
enum PostAction {
    case vote(Int)
    case share
    case copyLink
    case openCommunity
    case openAuthor
    /// The "⋯" button: the screen opens its menu.
    case more
}

/// A feed post. No Auto Layout and no measuring: `layoutSubviews` assigns
/// frames precomputed in PostLayout. Labels are opaque on the cell's
/// background so the GPU does not blend them while scrolling.
///
/// Swiping the post right votes for it, left votes against, like the
/// design's gesture card; the arrows still work for one-handed taps.
final class PostCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    static let reuseID = "PostCell"

    private let avatar = AvatarLabel()
    private let authorLabel = UILabel()
    private let metaLabel = UILabel()
    private let moreButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let votes = VoteControl()
    private let commentsButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let gapView = UIView()
    private let swipeIcon = UIImageView()
    private var layout: PostLayout?
    private var myVote = 0

    var onAction: ((PostAction) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundView = UIView()
        backgroundView?.backgroundColor = Palette.background
        backgroundView?.addSubview(swipeIcon)
        swipeIcon.contentMode = .center

        contentView.backgroundColor = Palette.surface
        for label in [authorLabel, metaLabel, titleLabel, bodyLabel] {
            label.backgroundColor = Palette.surface
            contentView.addSubview(label)
        }
        authorLabel.textColor = Palette.textPrimary
        metaLabel.textColor = Palette.textSecondary
        titleLabel.numberOfLines = 0
        titleLabel.textColor = Palette.textPrimary
        bodyLabel.textColor = Palette.textPrimary
        bodyLabel.lineBreakMode = .byTruncatingTail
        gapView.backgroundColor = Palette.background

        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = Palette.iconSecondary
        moreButton.accessibilityLabel = "Ещё"
        moreButton.addAction(UIAction { [weak self] _ in self?.onAction?(.more) }, for: .touchUpInside)

        commentsButton.tintColor = Palette.iconSecondary
        commentsButton.isUserInteractionEnabled = false // the whole cell opens the post
        shareButton.setImage(UIImage(systemName: "square.and.arrow.up"), for: .normal)
        shareButton.tintColor = Palette.iconSecondary
        shareButton.accessibilityLabel = "Поделиться"
        shareButton.addAction(UIAction { [weak self] _ in self?.onAction?(.share) }, for: .touchUpInside)
        votes.onVote = { [weak self] direction in self?.onAction?(.vote(direction)) }

        for view in [avatar, moreButton, votes, commentsButton, shareButton, gapView] as [UIView] {
            contentView.addSubview(view)
        }

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSwipe))
        pan.delegate = self
        contentView.addGestureRecognizer(pan)

        isAccessibilityElement = false
        contentView.accessibilityElements = [titleLabel, authorLabel, metaLabel, bodyLabel, votes, commentsButton, shareButton, moreButton]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(post: Post, layout: PostLayout, fonts: FeedFonts, animateVote: Bool) {
        self.layout = layout
        myVote = post.myVote
        avatar.configure(name: layout.author)
        authorLabel.font = fonts.author
        authorLabel.text = layout.author
        if let story = layout.storyLabel {
            let text = NSMutableAttributedString(string: story, attributes: [
                .font: fonts.storyBadge, .foregroundColor: Palette.accent,
            ])
            text.append(NSAttributedString(string: " · " + layout.meta, attributes: [
                .font: fonts.meta, .foregroundColor: Palette.textSecondary,
            ]))
            metaLabel.attributedText = text
        } else {
            metaLabel.font = fonts.meta
            metaLabel.textColor = Palette.textSecondary
            metaLabel.text = layout.meta
        }
        titleLabel.font = fonts.title
        titleLabel.text = post.title
        bodyLabel.font = fonts.body
        bodyLabel.text = layout.bodyText
        bodyLabel.numberOfLines = layout.bodyLines
        bodyLabel.isHidden = layout.bodyText.isEmpty

        var comments = AttributeContainer()
        comments.font = fonts.footer
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "bubble.left", withConfiguration: UIImage.SymbolConfiguration(font: fonts.footer))
        config.imagePadding = 5
        config.attributedTitle = AttributedString(post.commentCount.compactFormatted, attributes: comments)
        config.baseForegroundColor = Palette.iconSecondary
        config.contentInsets = .zero
        commentsButton.configuration = config
        commentsButton.accessibilityLabel = "\(post.commentCount) \(post.commentCount.ru("комментарий", "комментария", "комментариев"))"

        votes.configure(score: post.score, myVote: post.myVote, font: fonts.footer, animated: animateVote)
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: post.myVote == 1 ? "Убрать плюс" : "Плюс") { [weak self] _ in
                self?.onAction?(.vote(1)); return true
            },
            UIAccessibilityCustomAction(name: post.myVote == -1 ? "Убрать минус" : "Минус") { [weak self] _ in
                self?.onAction?(.vote(-1)); return true
            },
        ]
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout else { return }
        avatar.frame = layout.avatarFrame
        authorLabel.frame = layout.authorFrame
        metaLabel.frame = layout.metaFrame
        moreButton.frame = layout.moreFrame
        titleLabel.frame = layout.titleFrame
        bodyLabel.frame = layout.bodyFrame
        let footer = layout.footerFrame
        votes.frame = CGRect(x: footer.minX, y: footer.minY, width: VoteControl.width, height: footer.height)
        commentsButton.frame = CGRect(x: votes.frame.maxX + 10, y: footer.minY, width: 80, height: footer.height)
        commentsButton.contentHorizontalAlignment = .leading
        shareButton.frame = CGRect(x: footer.maxX - 44, y: footer.minY, width: 44, height: footer.height)
        gapView.frame = CGRect(x: 0, y: layout.contentHeight, width: bounds.width, height: bounds.height - layout.contentHeight)
    }

    override var isHighlighted: Bool {
        didSet {
            let color = isHighlighted ? Palette.surfaceHover : Palette.surface
            UIView.animate(withDuration: isHighlighted ? 0 : 0.25) {
                self.contentView.backgroundColor = color
                for label in [self.authorLabel, self.metaLabel, self.titleLabel, self.bodyLabel] {
                    label.backgroundColor = color
                }
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
        contentView.transform = .identity
    }

    // MARK: Swipe to vote

    private var swipeArmed = false

    /// Only clearly horizontal drags: vertical ones belong to the scroll.
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: contentView)
        return abs(v.x) > abs(v.y) * 1.5
    }

    @objc private func handleSwipe(_ pan: UIPanGestureRecognizer) {
        let dx = pan.translation(in: contentView).x
        switch pan.state {
        case .began, .changed:
            let offset = SwipeVote.offset(for: dx)
            contentView.transform = CGAffineTransform(translationX: offset, y: 0)
            gapView.transform = CGAffineTransform(translationX: -offset, y: 0) // the gap stays put
            let direction = SwipeVote.direction(for: dx)
            let armed = direction != nil
            if armed != swipeArmed {
                swipeArmed = armed
                Haptics.snap()
            }
            updateSwipeIcon(dx: dx, armed: armed)
        case .ended, .cancelled, .failed:
            let direction = pan.state == .ended ? SwipeVote.direction(for: dx) : nil
            swipeArmed = false
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.contentView.transform = .identity
                self.gapView.transform = .identity
                self.swipeIcon.alpha = 0
            }
            if let direction {
                onAction?(.vote(direction))
            }
        default:
            break
        }
    }

    private func updateSwipeIcon(dx: CGFloat, armed: Bool) {
        let up = dx > 0
        let active = up ? myVote == 1 : myVote == -1 // swiping the same way again clears the vote
        let name = up ? "arrowshape.up.fill" : "arrowshape.down.fill"
        swipeIcon.image = UIImage(systemName: active ? "xmark" : name,
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold))
        swipeIcon.tintColor = armed ? (up ? Palette.voteUp : Palette.voteDown) : Palette.textTertiary
        let height = layout?.contentHeight ?? bounds.height
        swipeIcon.frame = up
            ? CGRect(x: 0, y: 0, width: SwipeVote.threshold, height: height)
            : CGRect(x: bounds.width - SwipeVote.threshold, y: 0, width: SwipeVote.threshold, height: height)
        swipeIcon.alpha = min(1, abs(dx) / SwipeVote.threshold)
        swipeIcon.transform = armed ? CGAffineTransform(scaleX: 1.2, y: 1.2) : .identity
    }
}

/// The swipe-to-vote rules, kept pure so they are testable.
enum SwipeVote {
    /// How far to drag before letting go votes.
    static let threshold: CGFloat = 72

    /// Past the threshold the post follows the finger at a third of the
    /// speed: it feels like a stop without being a wall.
    static func offset(for dx: CGFloat) -> CGFloat {
        let distance = abs(dx)
        let resisted = distance <= threshold ? distance : threshold + (distance - threshold) / 3
        return dx < 0 ? -resisted : resisted
    }

    /// Right is for (+1), left is against (-1), short drags are nothing.
    static func direction(for dx: CGFloat) -> Int? {
        guard abs(dx) >= threshold else { return nil }
        return dx > 0 ? 1 : -1
    }
}
