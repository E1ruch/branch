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
    static let vetkaBackground = Color(uiColor: .systemBackground)
    static let vetkaGroupedBackground = Color(uiColor: .systemGroupedBackground)
    static let vetkaSecondaryText = Color(uiColor: .secondaryLabel)
    static let vetkaSkeleton = Color(uiColor: .tertiarySystemFill)
    /// Text field background.
    static let vetkaField = Color(uiColor: .tertiarySystemFill)
    static let vetkaUpvote = Color.orange
    static let vetkaDownvote = Color.indigo
}

public extension Int {
    /// "1,2 тыс." / "3,4 млн" in the user's locale: counters stay short.
    var compactFormatted: String {
        formatted(.number.notation(.compactName))
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
