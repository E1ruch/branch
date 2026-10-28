import DesignSystem
import UIKit

/// Placeholder posts shown while the first page loads, shaped like the real
/// cells so nothing jumps when they arrive. The shimmer is a single gradient
/// animated by Core Animation, off the main thread's work.
final class SkeletonFeedView: UIView {
    private let shimmer = CAGradientLayer()
    private let blocks = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Palette.surface
        isUserInteractionEnabled = false
        layer.addSublayer(blocks)
        shimmer.colors = [UIColor.clear.cgColor, UIColor.white.withAlphaComponent(0.35).cgColor, UIColor.clear.cgColor]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.locations = [0, 0.5, 1]
        layer.addSublayer(shimmer)
        isAccessibilityElement = true
        accessibilityLabel = "Загрузка ленты"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath()
        let inset: CGFloat = 16
        let width = bounds.width - inset * 2
        var y: CGFloat = 14
        // One placeholder per post, shaped like PostCell: avatar and two
        // lines, title, body, footer, then the gap.
        while y < bounds.height {
            path.append(UIBezierPath(ovalIn: CGRect(x: inset, y: y, width: 36, height: 36)))
            path.append(UIBezierPath(roundedRect: CGRect(x: inset + 46, y: y + 4, width: width * 0.32, height: 12), cornerRadius: 6))
            path.append(UIBezierPath(roundedRect: CGRect(x: inset + 46, y: y + 22, width: width * 0.22, height: 10), cornerRadius: 5))
            y += 48
            for (w, h, gap) in [(0.92, 18.0, 6.0), (0.6, 18.0, 12.0), (1.0, 13.0, 6.0), (0.95, 13.0, 6.0), (0.7, 13.0, 16.0)] {
                path.append(UIBezierPath(roundedRect: CGRect(x: inset, y: y, width: width * w, height: h), cornerRadius: 6))
                y += h + gap
            }
            path.append(UIBezierPath(roundedRect: CGRect(x: inset, y: y, width: 96, height: 18), cornerRadius: 6))
            y += 18 + 34
        }
        blocks.path = path.cgPath
        blocks.fillColor = Palette.surfaceTertiary.resolvedColor(with: traitCollection).cgColor

        shimmer.frame = bounds
        shimmer.mask = {
            let mask = CAShapeLayer()
            mask.path = path.cgPath
            return mask
        }()
        startShimmer()
    }

    private func startShimmer() {
        guard !UIAccessibility.isReduceMotionEnabled, shimmer.animation(forKey: "shimmer") == nil else { return }
        let move = CABasicAnimation(keyPath: "locations")
        move.fromValue = [-1.0, -0.5, 0.0]
        move.toValue = [1.0, 1.5, 2.0]
        move.duration = 1.2
        move.repeatCount = .infinity
        shimmer.add(move, forKey: "shimmer")
    }
}
