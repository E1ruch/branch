import Core
import DesignSystem
import FeedUI
import UIKit

/// The "Правила" tab: numbered rules on cards. A handful of labels, so a
/// stack view in a scroll view; no list machinery needed.
final class RulesViewController: UIViewController, ScrollPage {
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var shown: [CommunityRule]??

    var scrollView: UIScrollView {
        loadViewIfNeeded()
        return scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        scroll.alwaysBounceVertical = true
        scroll.accessibilityIdentifier = "community.rules"
        stack.axis = .vertical
        stack.spacing = Spacing.s
        view.addSubview(scroll)
        scroll.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = scroll.contentLayoutGuide, frame = scroll.frameLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Spacing.m),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Spacing.l),
            stack.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: Spacing.l),
            stack.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -Spacing.l),
        ])
        configure(nil)
    }

    /// nil while the community (and so its rules) is loading.
    func configure(_ rules: [CommunityRule]?) {
        loadViewIfNeeded()
        guard shown != .some(rules) else { return }
        shown = .some(rules)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        switch rules {
        case nil:
            for _ in 0..<3 {
                stack.addArrangedSubview(RuleCard(skeleton: ()))
            }
        case let rules? where rules.isEmpty:
            stack.addArrangedSubview(EmptyRules())
        case let rules?:
            for (index, rule) in rules.enumerated() {
                stack.addArrangedSubview(RuleCard(number: index + 1, rule: rule))
            }
        }
    }
}

/// "1  Без спама / Реклама — бан": the number in a green circle, the title,
/// then the explanation.
private final class RuleCard: UIView {
    private let number = UILabel()
    private let title = UILabel()
    private let body = UILabel()

    init(number index: Int, rule: CommunityRule) {
        super.init(frame: .zero)
        setUp()
        number.text = "\(index)"
        title.text = rule.title
        body.text = rule.body
        body.isHidden = rule.body.isEmpty
        isAccessibilityElement = true
        accessibilityLabel = "Правило \(index). \(rule.title). \(rule.body)"
    }

    /// A grey placeholder of the same shape.
    init(skeleton: Void) {
        super.init(frame: .zero)
        setUp()
        for label in [title, body] {
            label.text = " "
            label.backgroundColor = Palette.surfaceTertiary
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
        }
        number.text = " "
        isAccessibilityElement = true
        accessibilityLabel = "Загрузка правил"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func setUp() {
        backgroundColor = Palette.surface
        layer.cornerRadius = Radius.card
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = Palette.border.cgColor
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = Palette.border.resolvedColor(with: self.traitCollection).cgColor
        }

        number.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        number.textColor = Palette.chipActiveText
        number.textAlignment = .center
        number.backgroundColor = Palette.chipActiveBackground
        number.layer.cornerRadius = 12
        number.layer.masksToBounds = true
        title.font = .preferredFont(forTextStyle: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = Palette.textPrimary
        title.numberOfLines = 0
        body.font = .preferredFont(forTextStyle: .subheadline)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = Palette.textSecondary
        body.numberOfLines = 0

        let texts = UIStackView(arrangedSubviews: [title, body])
        texts.axis = .vertical
        texts.spacing = Spacing.xs
        for view in [number, texts] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.m),
            number.topAnchor.constraint(equalTo: texts.topAnchor),
            number.widthAnchor.constraint(equalToConstant: 24),
            number.heightAnchor.constraint(equalToConstant: 24),
            texts.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: Spacing.m),
            texts.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.l),
            texts.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            texts.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }
}

private final class EmptyRules: UIView {
    init() {
        super.init(frame: .zero)
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "list.bullet.rectangle")
        config.text = "Правил пока нет"
        config.secondaryText = "Модераторы ещё не написали правила. Будьте вежливы и не нарушайте общие правила Ветки."
        let content = UIContentUnavailableView(configuration: config)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.xl),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
