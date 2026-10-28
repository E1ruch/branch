import Core
import DesignSystem
import FeedUI
import UIKit

/// The top of a community page: avatar, title, subscribe button,
/// description and counters. Until the community loads, skeleton bars hold
/// the title's place so nothing jumps when it arrives.
final class CommunityHeaderView: UIView, PagerHeader {
    var onSubscribe: (() -> Void)?

    private let avatar = AvatarLabel()
    private let titleLabel = UILabel()
    private let slugLabel = UILabel()
    private let subscribeButton = UIButton(configuration: .filled())
    private let descriptionLabel = UILabel()
    private let statsLabel = UILabel()
    private let avatarSkeleton = UIView()
    private let titleSkeleton = UIView()
    private let slugSkeleton = UIView()
    private var subscribed: Bool?

    private static let avatarSize: CGFloat = 56

    init(slug: String) {
        super.init(frame: .zero)

        titleLabel.font = .preferredFont(forTextStyle: .title3).bold
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Palette.textPrimary
        titleLabel.numberOfLines = 2
        titleLabel.accessibilityTraits = .header
        slugLabel.font = .preferredFont(forTextStyle: .footnote)
        slugLabel.adjustsFontForContentSizeCategory = true
        slugLabel.textColor = Palette.textSecondary
        slugLabel.text = "c/\(slug)"

        descriptionLabel.font = .preferredFont(forTextStyle: .subheadline)
        descriptionLabel.adjustsFontForContentSizeCategory = true
        descriptionLabel.textColor = Palette.textPrimary
        descriptionLabel.numberOfLines = 0
        statsLabel.font = .preferredFont(forTextStyle: .footnote)
        statsLabel.adjustsFontForContentSizeCategory = true
        statsLabel.textColor = Palette.textSecondary
        statsLabel.numberOfLines = 0

        for bar in [titleSkeleton, slugSkeleton, avatarSkeleton] {
            bar.backgroundColor = Palette.surfaceTertiary
            bar.layer.cornerRadius = 6
        }
        avatarSkeleton.layer.cornerRadius = Self.avatarSize / 2

        subscribeButton.addAction(UIAction { [weak self] _ in self?.onSubscribe?() }, for: .touchUpInside)
        subscribeButton.isHidden = true
        subscribeButton.accessibilityIdentifier = "community.subscribe"
        subscribeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        subscribeButton.setContentHuggingPriority(.required, for: .horizontal)

        let names = UIStackView(arrangedSubviews: [titleLabel, slugLabel])
        names.axis = .vertical
        names.spacing = Spacing.xxs
        let top = UIStackView(arrangedSubviews: [avatar, names, subscribeButton])
        top.alignment = .center
        top.spacing = Spacing.m
        let content = UIStackView(arrangedSubviews: [top, descriptionLabel, statsLabel])
        content.axis = .vertical
        content.spacing = Spacing.m
        content.setCustomSpacing(Spacing.s, after: descriptionLabel)
        addSubview(content)
        addSubview(avatarSkeleton)
        addSubview(titleSkeleton)
        addSubview(slugSkeleton)

        for view in [content, avatar, avatarSkeleton, titleSkeleton, slugSkeleton] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.m),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.l),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.l),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.m),
            avatar.widthAnchor.constraint(equalToConstant: Self.avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: Self.avatarSize),
            avatarSkeleton.leadingAnchor.constraint(equalTo: avatar.leadingAnchor),
            avatarSkeleton.topAnchor.constraint(equalTo: avatar.topAnchor),
            avatarSkeleton.widthAnchor.constraint(equalTo: avatar.widthAnchor),
            avatarSkeleton.heightAnchor.constraint(equalTo: avatar.heightAnchor),
            titleSkeleton.leadingAnchor.constraint(equalTo: names.leadingAnchor),
            titleSkeleton.centerYAnchor.constraint(equalTo: avatar.centerYAnchor, constant: -10),
            titleSkeleton.widthAnchor.constraint(equalToConstant: 160),
            titleSkeleton.heightAnchor.constraint(equalToConstant: 18),
            slugSkeleton.leadingAnchor.constraint(equalTo: names.leadingAnchor),
            slugSkeleton.topAnchor.constraint(equalTo: titleSkeleton.bottomAnchor, constant: Spacing.s),
            slugSkeleton.widthAnchor.constraint(equalToConstant: 90),
            slugSkeleton.heightAnchor.constraint(equalToConstant: 12),
        ])
        configure(nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var titleMaxY: CGFloat {
        titleLabel.convert(titleLabel.bounds, to: self).maxY
    }

    func configure(_ community: Community?) {
        let loaded = community != nil
        titleSkeleton.isHidden = loaded
        slugSkeleton.isHidden = loaded
        avatarSkeleton.isHidden = loaded
        avatar.alpha = loaded ? 1 : 0
        titleLabel.alpha = loaded ? 1 : 0
        slugLabel.alpha = loaded ? 1 : 0
        guard let community else {
            titleLabel.text = " "
            descriptionLabel.isHidden = true
            statsLabel.isHidden = true
            return
        }
        titleLabel.text = community.title
        // By title, like the lists: the same letter and color everywhere.
        avatar.configure(name: community.title)
        descriptionLabel.text = community.description
        descriptionLabel.isHidden = community.description.isEmpty
        statsLabel.attributedText = stats(community)
        statsLabel.isHidden = false
        updateButton(subscribed: community.isSubscribed)
    }

    /// "**12** подписчиков · с октября 2025 · вы модератор".
    private func stats(_ community: Community) -> NSAttributedString {
        let count = community.subscribersCount
        let text = NSMutableAttributedString(
            string: count.compactFormatted,
            attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote).bold, .foregroundColor: Palette.textPrimary])
        var rest = " " + count.ru("подписчик", "подписчика", "подписчиков")
        rest += " · с " + Self.month.string(from: community.createdAt)
        switch community.viewerRole {
        case "owner": rest += " · вы владелец"
        case "moderator": rest += " · вы модератор"
        default: break
        }
        if community.isNsfw {
            rest += " · 18+"
        }
        text.append(NSAttributedString(string: rest))
        return text
    }

    /// "октября 2025": the format form of the month is the genitive one.
    private static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private func updateButton(subscribed: Bool) {
        let changed = self.subscribed != nil && self.subscribed != subscribed
        self.subscribed = subscribed
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.buttonSize = .medium
        // Subscribed, the button says what a tap does, in grey: the same
        // place and nearly the same width, so nothing jumps.
        var title = AttributedString(subscribed ? "Отписаться" : "Подписаться")
        title.font = UIFont.preferredFont(forTextStyle: .subheadline).bold
        config.attributedTitle = title
        config.baseBackgroundColor = subscribed ? Palette.chipInactiveBackground : Palette.buttonPrimary
        config.baseForegroundColor = subscribed ? Palette.chipInactiveText : Palette.buttonPrimaryText
        subscribeButton.isHidden = false

        guard changed, !UIAccessibility.isReduceMotionEnabled else {
            subscribeButton.configuration = config
            return
        }
        // The button changes width: let the title row follow with a spring,
        // and give the press a small bounce.
        subscribeButton.configuration = config
        subscribeButton.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0) {
            self.subscribeButton.transform = .identity
            self.layoutIfNeeded()
        }
    }
}

private extension UIFont {
    var bold: UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
