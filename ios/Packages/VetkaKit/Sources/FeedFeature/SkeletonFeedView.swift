import UIKit

/// Placeholder posts shown while the first page loads, shaped like the real
/// cells so nothing jumps when they arrive. The shimmer is a single gradient
/// animated by Core Animation, off the main thread's work.
final class SkeletonFeedView: UIView {
    private let shimmer = CAGradientLayer()
    private let blocks = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
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
        var y: CGFloat = 16
        let width = bounds.width - inset * 2
        while y < bounds.height {
            for (w, h, gap) in [(0.45, 12.0, 10.0), (0.9, 18.0, 8.0), (0.7, 18.0, 12.0), (1.0, 14.0, 6.0), (0.85, 14.0, 16.0), (0.3, 16.0, 26.0)] {
                path.append(UIBezierPath(roundedRect: CGRect(x: inset, y: y, width: width * w, height: h), cornerRadius: 6))
                y += h + gap
            }
        }
        blocks.path = path.cgPath
        blocks.fillColor = UIColor.tertiarySystemFill.resolvedColor(with: traitCollection).cgColor

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
