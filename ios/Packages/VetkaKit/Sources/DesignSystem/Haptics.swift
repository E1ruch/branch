import UIKit

/// Haptic feedback with generators created once and kept prepared: a cold
/// generator adds latency to the first tap, which is exactly the tap people
/// notice.
@MainActor
public enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    /// Warm the generators up, e.g. when a feed appears.
    public static func prepare() {
        light.prepare()
        rigid.prepare()
        selectionGenerator.prepare()
    }

    /// A vote, a subscribe, a like.
    public static func tap() {
        light.impactOccurred()
        light.prepare()
    }

    /// Something snapped into place: a pull-to-refresh threshold, a swipe action.
    public static func snap() {
        rigid.impactOccurred()
        rigid.prepare()
    }

    /// Switching between options (sort, tab).
    public static func selection() {
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    /// Signed in, saved: something completed.
    public static func success() {
        notification.notificationOccurred(.success)
    }

    /// An optimistic action was rolled back.
    public static func error() {
        notification.notificationOccurred(.error)
    }
}
