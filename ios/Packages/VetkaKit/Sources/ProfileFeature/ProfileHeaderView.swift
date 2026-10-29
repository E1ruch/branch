import Core
import DesignSystem
import FeedUI
import UIKit

/// The top of a profile: avatar, name, @username, bio, four counters and,
/// on someone else's profile, the follow button.
///
/// The username is known before anything loads (it is the route), so the
/// avatar and "@ник" are there from the first frame; skeleton bars hold the
/// name's and the counters' places so nothing jumps when they arrive.
final class ProfileHeaderView: UIView, PagerHeader {
    var onFollow: (() -> Void)?
    /// A tap on "подписчики" or "подписки".
    var onOpenList: ((FollowList) -> Void)?

    private let avatar = AvatarLabel()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    private let bioLabel = UILabel()
    private let posts = StatView()
    private let karma = StatView()
    private let following = StatView()
    private let followers = StatView()
    private let followButton = UIButton(configuration: .filled())
    private let nameSkeleton = UIView()
    private let username: String
    private let isMe: Bool
    private var isFollowing: Bool?

    private static let avatarSize: CGFloat = 88

    init(username: String, isMe: Bool) {
        self.username = username
        self.isMe = isMe
        super.init(frame: .zero)

        avatar.configure(name: username) // by username, like the feed's author avatars
        nameLabel.font = .preferredFont(forTextStyle: .title2).bold
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = Palette.textPrimary
        nameLabel.textAlignment = .center
        nameLabel.numberOfLines = 2
        nameLabel.accessibilityTraits = .header
        handleLabel.font = .preferredFont(forTextStyle: .footnote)
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = Palette.textSecondary
        handleLabel.textAlignment = .center
        handleLabel.numberOfLines = 0
        handleLabel.text = "@" + username
        bioLabel.font = .preferredFont(forTextStyle: .subheadline)
        bioLabel.adjustsFontForContentSizeCategory = true
        bioLabel.textColor = Palette.textPrimary
        bioLabel.textAlignment = .center
        bioLabel.numberOfLines = 0

        nameSkeleton.backgroundColor = Palette.surfaceTertiary
        nameSkeleton.layer.cornerRadius = 6

        // Карма is one number with its split one tap away: posts and
        // comments earn it differently, and neither is a score of the person.
        karma.isKarma = true
        // Публикации are the list right below; people open their own screen.
        posts.isUserInteractionEnabled = false
        followers.addAction(UIAction { [weak self] _ in self?.onOpenList?(.followers) }, for: .touchUpInside)
        following.addAction(UIAction { [weak self] _ in self?.onOpenList?(.following) }, for: .touchUpInside)
        followers.accessibilityIdentifier = "profile.followers"
        following.accessibilityIdentifier = "profile.following"
        let stats = UIStackView(arrangedSubviews: [posts, karma, following, followers])
        stats.distribution = .fillEqually
        stats.alignment = .top

        followButton.addAction(UIAction { [weak self] _ in self?.onFollow?() }, for: .touchUpInside)
        followButton.isHidden = true
        followButton.accessibilityIdentifier = "profile.follow"

        let avatarRow = UIView()
        avatarRow.addSubview(avatar)
        let content = UIStackView(arrangedSubviews: [avatarRow, nameLabel, handleLabel, bioLabel, stats, followButton])
        content.axis = .vertical
        content.spacing = Spacing.m
        content.setCustomSpacing(Spacing.xs, after: nameLabel)
        content.setCustomSpacing(Spacing.l, after: stats)
        addSubview(content)
        addSubview(nameSkeleton)

        for view in [content, avatar, nameSkeleton] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.s),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.l),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.l),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.l),
            avatar.topAnchor.constraint(equalTo: avatarRow.topAnchor),
            avatar.bottomAnchor.constraint(equalTo: avatarRow.bottomAnchor),
            avatar.centerXAnchor.constraint(equalTo: avatarRow.centerXAnchor),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            nameSkeleton.centerXAnchor.constraint(equalTo: nameLabel.centerXAnchor),
            nameSkeleton.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameSkeleton.widthAnchor.constraint(equalToConstant: 150),
            nameSkeleton.heightAnchor.constraint(equalToConstant: 20),
        ])
        configure(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var titleMaxY: CGFloat {
        nameLabel.convert(nameLabel.bounds, to: self).maxY
    }

    func configure(_ profile: Profile?) {
        nameSkeleton.isHidden = profile != nil
        nameLabel.alpha = profile == nil ? 0 : 1
        guard let profile else {
            nameLabel.text = " "
            bioLabel.isHidden = true
            for stat in [posts, karma, following, followers] {
                stat.configure(nil, label: "")
            }
            return
        }
        nameLabel.text = profile.name
        handleLabel.text = "@\(profile.username) · на Ветке с " + Self.month.string(from: profile.createdAt)
        bioLabel.text = profile.bio
        bioLabel.isHidden = profile.bio?.isEmpty ?? true

        posts.configure(profile.postsCount, label: profile.postsCount.ru("публикация", "публикации", "публикаций"))
        karma.configure(profile.karma, label: "карма")
        karma.menu = UIMenu(title: "Карма", children: [
            UIAction(title: "За посты", subtitle: profile.postKarma.formatted(), image: UIImage(systemName: "text.page"),
                     attributes: .disabled) { _ in },
            UIAction(title: "За комментарии", subtitle: profile.commentKarma.formatted(),
                     image: UIImage(systemName: "bubble.left"), attributes: .disabled) { _ in },
        ])
        following.configure(profile.followingCount, label: profile.followingCount.ru("подписка", "подписки", "подписок"))
        followers.configure(profile.followersCount,
                            label: profile.followersCount.ru("подписчик", "подписчика", "подписчиков"))
        if !isMe {
            updateButton(following: profile.isFollowing)
        }
    }

    /// "октября 2026": the format form of the month is the genitive one.
    private static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private func updateButton(following: Bool) {
        let changed = isFollowing != nil && isFollowing != following
        isFollowing = following
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.buttonSize = .large
        // As on community pages: following, the button says what a tap
        // does, in grey, in the same place.
        var title = AttributedString(following ? "Отписаться" : "Подписаться")
        title.font = UIFont.preferredFont(forTextStyle: .subheadline).bold
        config.attributedTitle = title
        config.baseBackgroundColor = following ? Palette.chipInactiveBackground : Palette.buttonPrimary
        config.baseForegroundColor = following ? Palette.chipInactiveText : Palette.buttonPrimaryText
        followButton.configuration = config
        followButton.isHidden = false

        guard changed, !UIAccessibility.isReduceMotionEnabled else { return }
        followButton.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0) {
            self.followButton.transform = .identity
        }
    }
}

/// One counter: the number over its word. The karma one opens a menu with
/// the split; the people ones open their lists. A control, so the pager's
/// overlay lets its taps through.
private final class StatView: UIControl {
    var isKarma = false {
        didSet {
            isContextMenuInteractionEnabled = isKarma
            showsMenuAsPrimaryAction = isKarma
        }
    }
    var menu: UIMenu?

    private let numberLabel = UILabel()
    private let textLabel = UILabel()
    private let skeleton = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberLabel.font = .preferredFont(forTextStyle: .headline)
        numberLabel.adjustsFontForContentSizeCategory = true
        numberLabel.textColor = Palette.textPrimary
        numberLabel.textAlignment = .center
        textLabel.font = .preferredFont(forTextStyle: .caption1)
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.textColor = Palette.textSecondary
        textLabel.textAlignment = .center
        textLabel.adjustsFontSizeToFitWidth = true
        textLabel.minimumScaleFactor = 0.8
        skeleton.backgroundColor = Palette.surfaceTertiary
        skeleton.layer.cornerRadius = 5

        let stack = UIStackView(arrangedSubviews: [numberLabel, textLabel])
        stack.axis = .vertical
        stack.spacing = Spacing.xxs
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        addSubview(skeleton)
        for view in [stack, skeleton] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.xs),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.xs),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.xxs),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.xxs),
            skeleton.centerXAnchor.constraint(equalTo: centerXAnchor),
            skeleton.centerYAnchor.constraint(equalTo: stack.centerYAnchor),
            skeleton.widthAnchor.constraint(equalToConstant: 44),
            skeleton.heightAnchor.constraint(equalToConstant: 28),
        ])
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ value: Int?, label: String) {
        skeleton.isHidden = value != nil
        numberLabel.alpha = value == nil ? 0 : 1
        textLabel.alpha = numberLabel.alpha
        guard let value else {
            numberLabel.text = " "
            textLabel.text = " "
            return
        }
        let number = NSMutableAttributedString()
        if isKarma {
            let symbol = UIImage(systemName: "sparkle", withConfiguration: UIImage.SymbolConfiguration(
                font: .preferredFont(forTextStyle: .footnote), scale: .medium))?
                .withTintColor(Palette.karma, renderingMode: .alwaysOriginal)
            if let symbol {
                number.append(NSAttributedString(attachment: NSTextAttachment(image: symbol)))
                number.append(NSAttributedString(string: "\u{2009}"))
            }
        }
        number.append(NSAttributedString(string: value.compactFormatted))
        numberLabel.attributedText = number
        textLabel.text = label
        accessibilityLabel = "\(value.formatted()) \(label)"
        accessibilityTraits = isUserInteractionEnabled ? .button : .staticText
        accessibilityHint = isKarma ? "Показывает карму за посты и за комментарии" : nil
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            UIView.animate(withDuration: isHighlighted ? 0.08 : 0.2) {
                self.alpha = self.isHighlighted ? 0.5 : 1
            }
        }
    }

    override func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                         configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard isKarma, let menu else { return nil }
        return UIContextMenuConfiguration(actionProvider: { _ in menu })
    }
}

private extension UIFont {
    var bold: UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
