import UIKit

/// UIKit twin of PillPicker, for screens whose tabs live over UIKit lists:
/// the same track, pills and colors, and the selected pill slides between
/// options. Sizes itself (`sizeThatFits`); frames are set by hand.
public final class PillTabs: UIControl {
    public private(set) var selectedIndex: Int
    /// A tap on another pill, after the pill has moved.
    public var onSelect: ((Int) -> Void)?

    private let thumb = UIView()
    private let buttons: [UIButton]
    private static let padding: CGFloat = Spacing.xs
    private static let pillInsets = UIEdgeInsets(top: 7, left: Spacing.l, bottom: 7, right: Spacing.l)

    public init(titles: [String], selectedIndex: Int = 0) {
        self.selectedIndex = selectedIndex
        buttons = titles.map { title in
            let button = UIButton(type: .custom)
            button.setTitle(title, for: .normal)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            return button
        }
        super.init(frame: .zero)
        backgroundColor = Palette.chipInactiveBackground
        thumb.backgroundColor = Palette.chipActiveBackground
        thumb.isUserInteractionEnabled = false
        addSubview(thumb)
        for (index, button) in buttons.enumerated() {
            button.addAction(UIAction { [weak self] _ in self?.tap(index) }, for: .touchUpInside)
            addSubview(button)
        }
        updateFonts()
        updateColors()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _) in
            self.updateFonts()
            self.superview?.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func select(_ index: Int, animated: Bool) {
        guard index != selectedIndex, buttons.indices.contains(index) else { return }
        selectedIndex = index
        updateColors()
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            setNeedsLayout()
            return
        }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
            self.layoutThumb()
        }
    }

    private func tap(_ index: Int) {
        guard index != selectedIndex else { return }
        Haptics.selection()
        select(index, animated: true)
        onSelect?(index)
    }

    private func updateFonts() {
        let size = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traitCollection).pointSize
        for button in buttons {
            button.titleLabel?.font = .systemFont(ofSize: size, weight: .semibold)
        }
    }

    private func updateColors() {
        for (index, button) in buttons.enumerated() {
            let selected = index == selectedIndex
            button.setTitleColor(selected ? Palette.chipActiveText : Palette.chipInactiveText, for: .normal)
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
    }

    private func pillSize(_ button: UIButton) -> CGSize {
        let text = button.titleLabel?.intrinsicContentSize ?? .zero
        let insets = Self.pillInsets
        return CGSize(width: ceil(text.width) + insets.left + insets.right,
                      height: ceil(text.height) + insets.top + insets.bottom)
    }

    public override func sizeThatFits(_ size: CGSize) -> CGSize {
        let pills = buttons.map(pillSize)
        let width = pills.reduce(0) { $0 + $1.width } + CGFloat(max(pills.count - 1, 0)) * Spacing.xs
        let height = pills.map(\.height).max() ?? 0
        return CGSize(width: width + 2 * Self.padding, height: height + 2 * Self.padding)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        var x = Self.padding
        for button in buttons {
            let size = pillSize(button)
            button.frame = CGRect(x: x, y: Self.padding, width: size.width, height: bounds.height - 2 * Self.padding)
            x += size.width + Spacing.xs
        }
        layoutThumb()
    }

    private func layoutThumb() {
        guard buttons.indices.contains(selectedIndex) else { return }
        thumb.frame = buttons[selectedIndex].frame
        thumb.layer.cornerRadius = thumb.bounds.height / 2
    }
}
