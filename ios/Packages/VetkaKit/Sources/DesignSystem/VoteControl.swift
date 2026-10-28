import Foundation
import UIKit

/// ▲ score ▼. The arrows are 44 pt wide: thumbs miss smaller targets.
public final class VoteControl: UIView {
    public static let width: CGFloat = 132

    private let up = UIButton(type: .system)
    private let down = UIButton(type: .system)
    private let scoreLabel = UILabel()
    private var myVote = 0
    public var onVote: ((Int) -> Void)?

    public override init(frame: CGRect) {
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

    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func configure(score: Int, myVote: Int, font: UIFont, animated: Bool) {
        let changed = myVote != self.myVote
        self.myVote = myVote
        let config = UIImage.SymbolConfiguration(font: font)
        up.setImage(UIImage(systemName: myVote == 1 ? "arrowshape.up.fill" : "arrowshape.up", withConfiguration: config), for: .normal)
        down.setImage(UIImage(systemName: myVote == -1 ? "arrowshape.down.fill" : "arrowshape.down", withConfiguration: config), for: .normal)
        up.tintColor = myVote == 1 ? Palette.voteUp : Palette.iconSecondary
        down.tintColor = myVote == -1 ? Palette.voteDown : Palette.iconSecondary
        up.accessibilityTraits = myVote == 1 ? [.button, .selected] : .button
        down.accessibilityTraits = myVote == -1 ? [.button, .selected] : .button

        scoreLabel.font = font
        scoreLabel.text = score.compactFormatted
        scoreLabel.textColor = switch myVote {
        case 1: Palette.voteUp
        case -1: Palette.voteDown
        default: Palette.textPrimary
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

    public override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        up.frame = CGRect(x: 0, y: 0, width: 44, height: h)
        scoreLabel.frame = CGRect(x: 44, y: 0, width: 44, height: h)
        down.frame = CGRect(x: 88, y: 0, width: 44, height: h)
    }
}

public enum RelativeAge {
    /// "только что", "5 мин назад", "2 ч назад", "3 д назад", then a date.
    public static func text(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "только что"
        case ..<3600: return "\(seconds / 60) мин назад"
        case ..<86400: return "\(seconds / 3600) ч назад"
        case ..<(86400 * 30): return "\(seconds / 86400) д назад"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
