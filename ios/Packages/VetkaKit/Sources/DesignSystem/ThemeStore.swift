import Observation
import SwiftUI
import UIKit

/// The app's light or dark look, chosen in Оформление and kept on the device.
///
/// It is the window's `overrideUserInterfaceStyle`, not SwiftUI's
/// `preferredColorScheme`: UIKit lists, sheets and the status bar follow the
/// window at once, so the switch is one frame, under the reveal animation.
@MainActor
@Observable
public final class ThemeStore {
    public enum Theme: String, CaseIterable, Sendable {
        /// Follows the iPhone's setting.
        case system, light, dark

        public var style: UIUserInterfaceStyle {
            switch self {
            case .system: .unspecified
            case .light: .light
            case .dark: .dark
            }
        }

        public var title: String {
            switch self {
            case .system: "Как в системе"
            case .light: "Светлая"
            case .dark: "Тёмная"
            }
        }
    }

    public private(set) var theme: Theme

    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "appearance.theme"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        theme = defaults.string(forKey: Self.key).flatMap(Theme.init(rawValue:)) ?? .system
    }

    /// Picks a theme. With `revealFrom` (a point in window coordinates) the
    /// new look spreads from there in a circle, as in Telegram; without it,
    /// a short cross-fade.
    public func select(_ new: Theme, revealFrom point: CGPoint? = nil) {
        guard new != theme else { return }
        let window = Self.windows.first { $0.isKeyWindow } ?? Self.windows.first
        let before = window?.traitCollection.userInterfaceStyle
        theme = new
        defaults.set(new.rawValue, forKey: Self.key)

        guard let window, !UIAccessibility.isReduceMotionEnabled,
              let snapshot = window.snapshotView(afterScreenUpdates: false) else {
            apply()
            return
        }
        apply()
        // "Как в системе" may land on the look already shown: nothing to
        // animate. (The screen's traits are the iPhone's, under any override.)
        let after = new == .system ? window.windowScene?.screen.traitCollection.userInterfaceStyle : new.style
        guard after != before else { return }

        // The old look stays on top as a picture with a growing hole in it.
        window.addSubview(snapshot)
        guard let point else {
            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
            return
        }
        let bounds = window.bounds
        let radius = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                      CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)]
            .map { hypot($0.x - point.x, $0.y - point.y) }.max() ?? 0
        func hole(_ r: CGFloat) -> CGPath {
            let path = UIBezierPath(rect: bounds)
            path.append(UIBezierPath(arcCenter: point, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: true))
            return path.cgPath
        }
        let mask = CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.path = hole(radius)
        snapshot.layer.mask = mask

        CATransaction.begin()
        CATransaction.setCompletionBlock { snapshot.removeFromSuperview() }
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = hole(1)
        grow.toValue = hole(radius)
        grow.duration = 0.5
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        mask.add(grow, forKey: "reveal")
        CATransaction.commit()
    }

    /// Puts the saved theme on every window; the app calls it once its
    /// window exists (ThemeWindowHook does it before the first frame).
    public func apply() {
        for window in Self.windows {
            apply(to: window)
        }
    }

    func apply(to window: UIWindow) {
        if window.overrideUserInterfaceStyle != theme.style {
            window.overrideUserInterfaceStyle = theme.style
        }
    }

    private static var windows: [UIWindow] {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
    }
}

/// Put once under the root view: sets the saved theme on the window as soon
/// as the view lands in it, before the first frame is drawn, so a dark
/// choice never flashes light at launch.
public struct ThemeWindowHook: UIViewRepresentable {
    private let store: ThemeStore

    public init(store: ThemeStore) {
        self.store = store
    }

    public func makeUIView(context: Context) -> HookView {
        let view = HookView()
        view.store = store
        view.isUserInteractionEnabled = false
        return view
    }

    public func updateUIView(_ view: HookView, context: Context) {}

    public final class HookView: UIView {
        var store: ThemeStore?

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                store?.apply(to: window)
            }
        }
    }
}
