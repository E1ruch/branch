import Core
import DesignSystem
import UIKit

/// A feed post. No Auto Layout and no measuring: `layoutSubviews` assigns
/// frames precomputed in PostLayout. Labels are opaque on the cell's
/// background so the GPU does not blend them while scrolling.
final class PostCell: UICollectionViewCell {
    static let reuseID = "PostCell"

    private let headerLabel = UILabel()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let votes = VoteControl()
    private let comments = UILabel()
    private let separator = UIView()
    private var layout: PostLayout?

    var onVote: ((Int) -> Void)? {
        get { votes.onVote }
        set { votes.onVote = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .systemBackground
        for label in [headerLabel, titleLabel, bodyLabel, comments] {
            label.backgroundColor = .systemBackground
            contentView.addSubview(label)
        }
        headerLabel.textColor = .secondaryLabel
        titleLabel.numberOfLines = 0
        titleLabel.textColor = .label
        bodyLabel.textColor = .label
        bodyLabel.lineBreakMode = .byTruncatingTail
        comments.textColor = .secondaryLabel
        separator.backgroundColor = .separator
        contentView.addSubview(votes)
        contentView.addSubview(separator)

        isAccessibilityElement = false
        contentView.accessibilityElements = [titleLabel, headerLabel, bodyLabel, votes, comments]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(post: Post, layout: PostLayout, fonts: FeedFonts, animateVote: Bool) {
        self.layout = layout
        headerLabel.font = fonts.header
        headerLabel.text = layout.header
        titleLabel.font = fonts.title
        titleLabel.text = post.title
        bodyLabel.font = fonts.body
        bodyLabel.text = layout.bodyText
        bodyLabel.numberOfLines = layout.bodyLines
        bodyLabel.isHidden = layout.bodyText.isEmpty
        comments.font = fonts.footer
        comments.attributedText = Self.commentsText(post.commentCount, font: fonts.footer)
        comments.accessibilityLabel = "\(post.commentCount) \(post.commentCount.ru("комментарий", "комментария", "комментариев"))"
        votes.configure(score: post.score, myVote: post.myVote, font: fonts.footer, animated: animateVote)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout else { return }
        headerLabel.frame = layout.headerFrame
        titleLabel.frame = layout.titleFrame
        bodyLabel.frame = layout.bodyFrame
        let footer = layout.footerFrame
        votes.frame = CGRect(x: footer.minX, y: footer.minY, width: VoteControl.width, height: footer.height)
        comments.frame = CGRect(x: votes.frame.maxX + 12, y: footer.minY, width: 100, height: footer.height)
        let scale = traitCollection.displayScale
        separator.frame = CGRect(x: 0, y: bounds.height - 1 / scale, width: bounds.width, height: 1 / scale)
    }

    override var isHighlighted: Bool {
        didSet {
            let color: UIColor = isHighlighted ? .secondarySystemBackground : .systemBackground
            UIView.animate(withDuration: isHighlighted ? 0 : 0.25) {
                self.contentView.backgroundColor = color
                for label in [self.headerLabel, self.titleLabel, self.bodyLabel, self.comments] {
                    label.backgroundColor = color
                }
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onVote = nil
    }

    private static func commentsText(_ count: Int, font: UIFont) -> NSAttributedString {
        let icon = NSTextAttachment(image: UIImage(systemName: "bubble.left",
                                                   withConfiguration: UIImage.SymbolConfiguration(font: font))!
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal))
        let text = NSMutableAttributedString(attachment: icon)
        text.append(NSAttributedString(string: " \(count.compactFormatted)", attributes: [.font: font]))
        return text
    }
}

/// ▲ score ▼. The arrows are 44 pt wide: thumbs miss smaller targets.
final class VoteControl: UIView {
    static let width: CGFloat = 132

    private let up = UIButton(type: .system)
    private let down = UIButton(type: .system)
    private let scoreLabel = UILabel()
    private var myVote = 0
    var onVote: ((Int) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scoreLabel.textAlignment = .center
        scoreLabel.backgroundColor = .clear
        up.accessibilityLabel = "Плюс"
        down.accessibilityLabel = "Минус"
        up.addAction(UIAction { [weak self] _ in self?.onVote?(1) }, for: .touchUpInside)
        down.addAction(UIAction { [weak self] _ in self?.onVote?(-1) }, for: .touchUpInside)
        addSubview(up)
        addSubview(scoreLabel)
        addSubview(down)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(score: Int, myVote: Int, font: UIFont, animated: Bool) {
        let changed = myVote != self.myVote
        self.myVote = myVote
        let config = UIImage.SymbolConfiguration(font: font)
        up.setImage(UIImage(systemName: myVote == 1 ? "arrowshape.up.fill" : "arrowshape.up", withConfiguration: config), for: .normal)
        down.setImage(UIImage(systemName: myVote == -1 ? "arrowshape.down.fill" : "arrowshape.down", withConfiguration: config), for: .normal)
        up.tintColor = myVote == 1 ? .systemOrange : .secondaryLabel
        down.tintColor = myVote == -1 ? .systemIndigo : .secondaryLabel
        up.accessibilityTraits = myVote == 1 ? [.button, .selected] : .button
        down.accessibilityTraits = myVote == -1 ? [.button, .selected] : .button

        scoreLabel.font = font
        scoreLabel.text = score.compactFormatted
        scoreLabel.textColor = switch myVote {
        case 1: .systemOrange
        case -1: .systemIndigo
        default: .label
        }
        scoreLabel.accessibilityLabel = "Рейтинг \(score)"

        if animated && changed && !UIAccessibility.isReduceMotionEnabled {
            let target = myVote == 0 ? scoreLabel : (myVote == 1 ? up : down)
            target.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.45, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                target.transform = .identity
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        up.frame = CGRect(x: 0, y: 0, width: 44, height: h)
        scoreLabel.frame = CGRect(x: 44, y: 0, width: 44, height: h)
        down.frame = CGRect(x: 88, y: 0, width: 44, height: h)
    }
}
