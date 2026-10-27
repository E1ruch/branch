import SwiftUI

/// Spacing on a 4-point grid. Screens use these, never raw numbers.
public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
}

public enum Radius {
    public static let small: CGFloat = 6
    public static let card: CGFloat = 14
}

public extension Animation {
    /// The default motion: a short spring with a hint of bounce.
    static let vetka = Animation.spring(duration: 0.35, bounce: 0.12)
    /// For small state flips (a vote, a toggle) that must feel instant.
    static let vetkaSnappy = Animation.snappy(duration: 0.22)
}

public extension Color {
    static let vetkaBackground = Color(uiColor: Palette.background)
    static let vetkaGroupedBackground = Color(uiColor: Palette.background)
    static let vetkaSecondaryText = Color(uiColor: Palette.textSecondary)
    static let vetkaSkeleton = Color(uiColor: Palette.surfaceTertiary)
    /// Text field background.
    static let vetkaField = Color(uiColor: Palette.surfaceSecondary)
    static let vetkaUpvote = Color(uiColor: Palette.voteUp)
    static let vetkaDownvote = Color(uiColor: Palette.voteDown)
}

public extension Int {
    /// 950 → "950", 12 400 → "12,4k", 156 000 → "156k", 3 450 000 → "3,4M": short enough for
    /// the vote row, with the locale's decimal separator.
    var compactFormatted: String {
        let value = Double(abs(self))
        let sign = self < 0 ? "−" : ""
        let (scaled, suffix): (Double, String) = switch value {
        case ..<1000: (value, "")
        case ..<1_000_000: (value / 1000, "k")
        default: (value / 1_000_000, "M")
        }
        guard !suffix.isEmpty else { return sign + String(Int(value)) }
        let digits = scaled < 100 ? 1 : 0
        let number = (scaled * pow(10, Double(digits))).rounded(.down) / pow(10, Double(digits))
        return sign + number.formatted(.number.precision(.fractionLength(0...digits))) + suffix
    }
}

public extension Int {
    /// Russian plural agreement: 1 подписчик, 2 подписчика, 5 подписчиков.
    /// Compact numbers ("1,2 тыс.") take the genitive plural.
    func ru(_ one: String, _ few: String, _ many: String) -> String {
        if self >= 1000 { return many }
        let mod10 = self % 10, mod100 = self % 100
        if mod10 == 1 && mod100 != 11 { return one }
        if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
        return many
    }
}
