import UIKit

/// One line of an ActionMenu: title on the left, icon on the right.
public struct ActionMenuItem {
    public let title: String
    public let systemImage: String
    public let isDestructive: Bool
    public let handler: () -> Void

    public init(_ title: String, systemImage: String, isDestructive: Bool = false, handler: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isDestructive = isDestructive
        self.handler = handler
    }
}

/// The capsule above the lifted item: ↑ score ↓, where Telegram puts its
/// reactions. A vote closes the menu, as a reaction does.
public struct ActionMenuVotes {
    public let score: Int
    public let myVote: Int
    public let onVote: (Int) -> Void

    public init(score: Int, myVote: Int, onVote: @escaping (Int) -> Void) {
        self.score = score
        self.myVote = myVote
        self.onVote = onVote
    }
}

/// The long-press menu, after Telegram's: the screen blurs, the pressed
/// item lifts out of it as is (not squeezed into a preview), the votes sit
/// above it and the actions in a card below; when the item is low, it
/// slides up so both fit. A tap outside puts everything back.
///
/// The finger that opened it can slide straight to an action and let go,
/// as in Telegram: the host forwards its long press to `track` and `release`.
@MainActor
public final class ActionMenu {
    private let votes: ActionMenuVotes?
    private let groups: [[ActionMenuItem]]
    private var overlay: ActionMenuOverlay?

    public init(votes: ActionMenuVotes?, groups: [[ActionMenuItem]]) {
        self.votes = votes
        self.groups = groups.filter { !$0.isEmpty }
    }

    /// Lifts `source` and opens the menu around it. `height` lifts only
    /// its top part (a feed cell without the gap under it). Returns false
    /// when there is no window to show it in.
    @discardableResult
    public func present(from source: UIView, height: CGFloat? = nil) -> Bool {
        present(source, lifts: true, height: height)
    }

    /// Opens the card out of a button ("⋯"), nothing lifted: for an item
    /// too big to lift, like a whole post on its own screen.
    @discardableResult
    public func present(fromButton button: UIView) -> Bool {
        present(button, lifts: false, height: nil)
    }

    private func present(_ source: UIView, lifts: Bool, height: CGFloat?) -> Bool {
        guard overlay == nil, let window = source.window else { return false }
        window.endEditing(true) // the keyboard lives above the app's window
        let overlay = ActionMenuOverlay(source: source, lifts: lifts, height: height, votes: lifts ? votes : nil,
                                        groups: groups)
        overlay.onClosed = { [weak self] in self?.overlay = nil }
        self.overlay = overlay
        overlay.show(in: window)
        return true
    }

    /// The opening finger moved (window coordinates): highlight what is under it.
    public func track(_ point: CGPoint) {
        overlay?.track(point)
    }

    /// The opening finger lifted: run what is under it, or leave the menu open.
    public func release(_ point: CGPoint) {
        overlay?.release(point)
    }

    public func dismiss() {
        overlay?.close(then: nil)
    }
}

// MARK: - Overlay

private final class ActionMenuOverlay: UIView {
    var onClosed: (() -> Void)?

    private weak var source: UIView?
    private let lifts: Bool
    private let height: CGFloat?
    private let votes: ActionMenuVotes?
    private let groups: [[ActionMenuItem]]
    private let blur = UIVisualEffectView(effect: nil)
    private let dim = UIView()
    private let lifted = UIView()
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let capsule = UIView()
    private var rows: [MenuRow] = []
    private var voteButtons: [UIButton] = []
    private var sourceFrame: CGRect = .zero
    private var isClosing = false
    private var tracked: UIControl?
    /// The opening finger has moved off where it started: a release over
    /// an action runs it. Before that, letting go only leaves the menu open.
    private var fingerMoved = false
    private var startPoint: CGPoint?

    private static let cardWidth: CGFloat = 250
    private static let rowHeight: CGFloat = 46
    private static let groupGap: CGFloat = 8
    private static let capsuleHeight: CGFloat = 46
    private static let spacing: CGFloat = 8
    private static let margin: CGFloat = 16

    init(source: UIView, lifts: Bool, height: CGFloat?, votes: ActionMenuVotes?, groups: [[ActionMenuItem]]) {
        self.source = source
        self.lifts = lifts
        self.height = height
        self.votes = votes
        self.groups = groups
        super.init(frame: .zero)
        accessibilityViewIsModal = true
        dim.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor.black.withAlphaComponent(0.45) : UIColor.black.withAlphaComponent(0.18) }
        dim.alpha = 0
        addSubview(blur)
        addSubview(dim)
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        dim.addGestureRecognizer(tap)

        lifted.layer.cornerRadius = 16
        lifted.layer.cornerCurve = .continuous
        lifted.clipsToBounds = true
        lifted.isUserInteractionEnabled = false
        addSubview(lifted)

        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        addSubview(card)
        buildCard()
        if votes != nil {
            buildCapsule()
            addSubview(capsule)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Building

    private func buildCard() {
        var y: CGFloat = 0
        for (index, group) in groups.enumerated() {
            if index > 0 {
                let gap = UIView(frame: CGRect(x: 0, y: y, width: Self.cardWidth, height: Self.groupGap))
                gap.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
                    ? UIColor.black.withAlphaComponent(0.35) : UIColor.black.withAlphaComponent(0.07) }
                card.contentView.addSubview(gap)
                y += Self.groupGap
            }
            for (i, item) in group.enumerated() {
                let row = MenuRow(item: item, showsSeparator: i < group.count - 1)
                row.frame = CGRect(x: 0, y: y, width: Self.cardWidth, height: Self.rowHeight)
                row.addAction(UIAction { [weak self] _ in self?.close(then: item.handler) }, for: .touchUpInside)
                card.contentView.addSubview(row)
                rows.append(row)
                y += Self.rowHeight
            }
        }
        card.bounds.size = CGSize(width: Self.cardWidth, height: y)
    }

    private func buildCapsule() {
        guard let votes else { return }
        capsule.backgroundColor = Palette.surface
        capsule.layer.cornerRadius = Self.capsuleHeight / 2
        capsule.layer.shadowColor = UIColor.black.cgColor
        capsule.layer.shadowOpacity = 0.12
        capsule.layer.shadowRadius = 12
        capsule.layer.shadowOffset = CGSize(width: 0, height: 4)

        let symbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        func button(_ direction: Int) -> UIButton {
            let on = votes.myVote == direction
            let name = direction > 0 ? "arrowshape.up" : "arrowshape.down"
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: on ? name + ".fill" : name, withConfiguration: symbol), for: .normal)
            button.tintColor = on ? (direction > 0 ? Palette.voteUp : Palette.voteDown) : Palette.iconSecondary
            button.accessibilityLabel = direction > 0 ? "Плюс" : "Минус"
            button.accessibilityTraits.insert(on ? .selected : [])
            button.addAction(UIAction { [weak self] _ in
                self?.close { votes.onVote(direction) }
            }, for: .touchUpInside)
            return button
        }
        let up = button(1), down = button(-1)
        voteButtons = [up, down]
        let score = UILabel()
        score.text = votes.score.compactFormatted
        score.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        score.textColor = votes.myVote > 0 ? Palette.voteUp : votes.myVote < 0 ? Palette.voteDown : Palette.textPrimary
        score.textAlignment = .center
        score.isAccessibilityElement = false
        score.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true

        let stack = UIStackView(arrangedSubviews: [up, score, down])
        stack.alignment = .center
        stack.spacing = 4
        stack.frame = CGRect(x: 8, y: 0, width: 132, height: Self.capsuleHeight)
        up.widthAnchor.constraint(equalToConstant: 44).isActive = true
        down.widthAnchor.constraint(equalToConstant: 44).isActive = true
        capsule.addSubview(stack)
        capsule.bounds.size = CGSize(width: 148, height: Self.capsuleHeight)
    }

    // MARK: Showing

    func show(in window: UIWindow) {
        guard let source else { return }
        frame = window.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blur.frame = bounds
        dim.frame = bounds
        window.addSubview(self)

        sourceFrame = source.convert(source.bounds, to: self)
        if let height {
            sourceFrame.size.height = min(sourceFrame.height, height)
        }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        guard lifts else {
            showFromButton(reduceMotion: reduceMotion)
            return
        }
        // After updates: a highlight the host just took off must not be in the picture.
        if let snapshot = source.snapshotView(afterScreenUpdates: true) {
            snapshot.frame = CGRect(origin: .zero, size: source.bounds.size) // clipped, never squeezed
            lifted.addSubview(snapshot)
        }
        lifted.backgroundColor = source.backgroundColor ?? Palette.surface
        lifted.layer.cornerRadius = 0
        lifted.bounds = CGRect(origin: .zero, size: sourceFrame.size)
        lifted.center = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
        source.alpha = 0

        let target = layoutTargets()
        card.frame = target.card
        capsule.frame = target.capsule
        for view in [card, capsule] as [UIView] {
            view.alpha = 0
            if !reduceMotion {
                view.transform = Self.grow(from: CGPoint(x: 0, y: view === capsule ? 1 : 0), size: view.bounds.size)
            }
        }
        Haptics.snap()

        UIView.animate(withDuration: 0.25) {
            self.blur.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            self.dim.alpha = 1
        }
        UIView.animate(withDuration: reduceMotion ? 0.2 : 0.45, delay: 0, usingSpringWithDamping: 0.82,
                       initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.lifted.bounds.size = target.liftedSize
            self.lifted.center = target.liftedCenter
            self.lifted.transform = CGAffineTransform(scaleX: target.liftedScale, y: target.liftedScale)
            self.lifted.layer.cornerRadius = 16 / target.liftedScale
        }
        UIView.animate(withDuration: reduceMotion ? 0.2 : 0.42, delay: 0.03, usingSpringWithDamping: 0.72,
                       initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            for view in [self.card, self.capsule] as [UIView] {
                view.alpha = 1
                view.transform = .identity
            }
        }
        UIAccessibility.post(notification: .screenChanged, argument: votes != nil ? voteButtons.first : rows.first)
    }

    /// Where everything goes: the item keeps its place if the capsule and
    /// card fit around it, else it slides (up, usually) just enough; an item
    /// taller than the room left shows its top part. A full-width item
    /// shrinks a touch off the screen edges, like a lifted bubble.
    private func layoutTargets() -> (liftedSize: CGSize, liftedCenter: CGPoint, liftedScale: CGFloat,
                                     capsule: CGRect, card: CGRect) {
        let safe = bounds.inset(by: safeAreaInsets).insetBy(dx: 0, dy: Self.spacing)
        let scale = sourceFrame.width > bounds.width - 2 * Self.margin
            ? (sourceFrame.width - Self.margin) / sourceFrame.width : 1
        let above = votes == nil ? 0 : Self.capsuleHeight + Self.spacing
        let below = Self.spacing + card.bounds.height
        let maxShown = max(Self.rowHeight * 2, safe.height - above - below)
        let size = CGSize(width: sourceFrame.width, height: min(sourceFrame.height, maxShown / scale))
        let shown = CGSize(width: size.width * scale, height: size.height * scale)
        // The shrunk item stays centred on where the original was.
        var top = sourceFrame.midY - sourceFrame.height * scale / 2 - above
        top = min(top, safe.maxY - (above + shown.height + below)) // room for the card below
        top = max(top, safe.minY)                                   // never under the status bar
        let item = CGRect(x: sourceFrame.midX - shown.width / 2, y: top + above, width: shown.width, height: shown.height)
        let left = item.minX + Self.margin / 2
        let capsule = CGRect(x: left, y: item.minY - above, width: self.capsule.bounds.width, height: Self.capsuleHeight)
        let card = CGRect(x: left, y: item.maxY + Self.spacing, width: self.card.bounds.width, height: self.card.bounds.height)
        return (size, CGPoint(x: item.midX, y: item.midY), scale, capsule, card)
    }

    /// The card under the button, its right edge on the button's (above
    /// it when there is no room below), growing out of that corner.
    private func showFromButton(reduceMotion: Bool) {
        let safe = bounds.inset(by: safeAreaInsets).insetBy(dx: Self.margin, dy: Self.spacing)
        let size = card.bounds.size
        let x = min(max(sourceFrame.maxX - size.width, safe.minX), safe.maxX - size.width)
        let below = sourceFrame.maxY + 4 + size.height <= safe.maxY
        let y = below ? sourceFrame.maxY + 4 : max(safe.minY, sourceFrame.minY - 4 - size.height)
        card.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        card.alpha = 0
        capsule.isHidden = true
        if !reduceMotion {
            card.transform = Self.grow(from: CGPoint(x: 1, y: below ? 0 : 1), size: size)
        }
        Haptics.tap()
        UIView.animate(withDuration: 0.25) {
            self.blur.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            self.dim.alpha = 1
        }
        UIView.animate(withDuration: reduceMotion ? 0.2 : 0.42, delay: 0, usingSpringWithDamping: 0.75,
                       initialSpringVelocity: 0, options: [.allowUserInteraction]) {
            self.card.alpha = 1
            self.card.transform = .identity
        }
        UIAccessibility.post(notification: .screenChanged, argument: rows.first)
    }

    /// A half-size copy pinned at `anchor` (unit coordinates of the view:
    /// (0, 0) top left): the card grows down out of the item, the capsule up.
    private static func grow(from anchor: CGPoint, size: CGSize) -> CGAffineTransform {
        let scale: CGFloat = 0.5
        let dx = (anchor.x - 0.5) * size.width * (1 - scale)
        let dy = (anchor.y - 0.5) * size.height * (1 - scale)
        return CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    }

    // MARK: Closing

    @objc private func backgroundTapped() {
        close(then: nil)
    }

    override func accessibilityPerformEscape() -> Bool {
        close(then: nil)
        return true
    }

    /// Puts the item back and runs `action` once the menu is gone, so
    /// what it opens (a sheet, the keyboard) does not fight the animation.
    func close(then action: (() -> Void)?) {
        guard !isClosing else { return }
        isClosing = true
        isUserInteractionEnabled = false
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn]) {
            for view in [self.card, self.capsule] as [UIView] {
                view.alpha = 0
                if !reduceMotion {
                    view.transform = CGAffineTransform(scaleX: 0.85, y: 0.85)
                }
            }
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
            self.blur.effect = nil
            self.dim.alpha = 0
        }
        UIView.animate(withDuration: reduceMotion || !lifts ? 0.22 : 0.38, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0, options: []) {
            guard self.lifts else {
                self.lifted.alpha = 0 // something to animate, so completion waits for the fade
                return
            }
            self.lifted.transform = .identity
            self.lifted.bounds.size = self.sourceFrame.size
            self.lifted.center = CGPoint(x: self.sourceFrame.midX, y: self.sourceFrame.midY)
            self.lifted.layer.cornerRadius = 0
        } completion: { _ in
            self.source?.alpha = 1
            self.removeFromSuperview()
            self.onClosed?()
            action?()
        }
    }

    // MARK: Sliding the opening finger

    private var controls: [UIControl] { voteButtons + rows }

    func track(_ point: CGPoint) {
        guard !isClosing else { return }
        if let start = startPoint {
            if hypot(point.x - start.x, point.y - start.y) > 10 { fingerMoved = true }
        } else {
            startPoint = point
        }
        let hit = controls.first { $0.convert($0.bounds, to: self).contains(point) }
        guard hit !== tracked else { return }
        tracked?.isHighlighted = false
        tracked = hit
        hit?.isHighlighted = true
        if hit != nil { Haptics.selection() }
    }

    func release(_ point: CGPoint) {
        track(point)
        let hit = tracked
        tracked?.isHighlighted = false
        tracked = nil
        guard fingerMoved, let hit else { return }
        hit.sendActions(for: .touchUpInside)
    }
}

// MARK: - Row

private final class MenuRow: UIControl {
    private let titleLabel = UILabel()
    private let icon = UIImageView()
    private let separator = UIView()
    private let highlight = UIView()

    init(item: ActionMenuItem, showsSeparator: Bool) {
        super.init(frame: .zero)
        let color = item.isDestructive ? Palette.destructive : Palette.textPrimary
        highlight.backgroundColor = UIColor { $0.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.12) : UIColor.black.withAlphaComponent(0.08) }
        highlight.alpha = 0
        titleLabel.text = item.title
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8
        titleLabel.textColor = color
        icon.image = UIImage(systemName: item.systemImage,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        icon.tintColor = color
        icon.contentMode = .center
        separator.backgroundColor = Palette.border
        separator.isHidden = !showsSeparator
        for view in [highlight, titleLabel, icon, separator] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        isAccessibilityElement = true
        accessibilityLabel = item.title
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 16
        highlight.frame = bounds
        icon.frame = CGRect(x: bounds.width - inset - 24, y: 0, width: 24, height: bounds.height)
        titleLabel.frame = CGRect(x: inset, y: 0, width: icon.frame.minX - inset - 8, height: bounds.height)
        let pixel = 1 / max(traitCollection.displayScale, 1)
        separator.frame = CGRect(x: inset, y: bounds.height - pixel, width: bounds.width - inset, height: pixel)
    }

    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue else { return }
            UIView.animate(withDuration: isHighlighted ? 0.05 : 0.2) {
                self.highlight.alpha = self.isHighlighted ? 1 : 0
            }
        }
    }
}
