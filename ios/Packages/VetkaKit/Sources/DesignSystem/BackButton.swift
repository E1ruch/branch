import SwiftUI
import UIKit

/// The back button on every pushed screen: a raised round button with a
/// chevron, like the search bar's ✕ (and Telegram's), with no title.
public struct BackButton: View {
    private let action: () -> Void

    /// Smaller than the search bar's ✕: it lives in the 44 pt navigation
    /// bar, which clips anything drawn past it, shadows included.
    public static let size: CGFloat = 38

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.vetkaTextPrimary)
                .offset(x: -1) // optically centred: a chevron's weight sits on its point
                .frame(width: Self.size, height: Self.size)
                .background {
                    // A short shadow that fits in the bar, and a hairline
                    // that keeps the edge when the bar is white too.
                    Circle()
                        .fill(RaisedStyle.fill)
                        .shadow(color: RaisedStyle.shadow, radius: 3, y: 1)
                        .overlay(Circle().strokeBorder(Color(uiColor: Palette.borderSubtle), lineWidth: 1))
                }
                .contentShape(Circle())
        }
        .buttonStyle(RaisedPressStyle())
        .accessibilityLabel("Назад")
        .accessibilityIdentifier("nav.back")
    }
}

public extension View {
    /// Replaces the system back button with BackButton. The system swipe
    /// from the left edge keeps working (see the UINavigationController
    /// extension below).
    func vetkaBackButton() -> some View {
        modifier(BackButtonModifier())
    }
}

private struct BackButtonModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BackButton { dismiss() }
                }
            }
    }
}

/// Raised surfaces shared by the round buttons and the active search bar:
/// white with a shadow in light mode; in dark mode a shadow does not show,
/// so a lighter surface does the lift.
enum RaisedStyle {
    static let fill = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? Palette.surfaceSecondary : Palette.surface
    })
    static let shadow = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .clear : UIColor.black.withAlphaComponent(0.09)
    })
}

/// A small press-in for round buttons.
struct RaisedPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.vetkaSnappy, value: configuration.isPressed)
    }
}

/// Hiding the system back button turns off the interactive pop gesture;
/// letting every navigation controller answer for it turns it back on, for
/// any screen above the root.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // On the root there is nothing to go back to; a swipe there would
        // leave the stack in a broken, half-transitioned state.
        gestureRecognizer !== interactivePopGestureRecognizer || viewControllers.count > 1
    }
}
