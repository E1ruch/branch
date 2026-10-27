import SwiftUI
import UIKit

/// Color tokens from docs/design-system.md (the design handoff). Every
/// color is dynamic: it resolves itself for light and dark appearance, so
/// screens never branch on the color scheme.
///
/// Where a handoff pair fell short of WCAG contrast, the nearest darker
/// shade of the same hue is used; each such case says so below.
public enum Palette {
    // MARK: Brand

    /// brand-primary: the bright turquoise-green for fills that carry no
    /// text (logo, large decorative areas).
    public static let brandPrimary = UIColor(light: 0x20C997, dark: 0x35D6A5)
    /// The interactive green: tint, active tab, green text and icons on
    /// surfaces. #20C997 reaches only 2.1:1 on white, so light uses
    /// brand-dark #119B82 (3.5:1).
    public static let accent = UIColor(light: 0x119B82, dark: 0x35D6A5)
    /// surface-brand / brand-light: soft brand backgrounds.
    public static let brandLight = UIColor(light: 0xE5F8F1, dark: 0x193D34)
    public static let logoGradient = (start: UIColor(hex: 0x36D399), end: UIColor(hex: 0x0B8F91))

    // MARK: Surfaces

    public static let background = UIColor(light: 0xF7F9FC, dark: 0x101418)
    public static let surface = UIColor(light: 0xFFFFFF, dark: 0x191F25)
    public static let surfaceSecondary = UIColor(light: 0xF3F6F9, dark: 0x222A32)
    /// Placeholders and skeletons.
    public static let surfaceTertiary = UIColor(light: 0xEAF0F5, dark: 0x2B3540)
    /// A pressed or highlighted row.
    public static let surfaceHover = UIColor(light: 0xF0F5F7, dark: 0x222A32)

    // MARK: Text and icons

    public static let textPrimary = UIColor(light: 0x17212F, dark: 0xF2F5F7)
    public static let textSecondary = UIColor(light: 0x68778A, dark: 0xA3AFBC)
    /// Decoration only: 2.5:1 on white is too faint for information, so
    /// times and metadata use textSecondary.
    public static let textTertiary = UIColor(light: 0x98A5B5, dark: 0x7E8B99)
    public static let link = UIColor(light: 0x168BCE, dark: 0x5AB4F0)
    public static let iconPrimary = UIColor(light: 0x344256, dark: 0xD5DDE5)
    /// Inactive action icons (vote arrows, share, more). The handoff's
    /// #8B98A8 gives 2.9:1 on white, under the 3:1 a control needs.
    public static let iconSecondary = UIColor(light: 0x68778A, dark: 0x8D9AA8)
    public static let iconDisabled = UIColor(light: 0xC4CDD6, dark: 0x4A5561)

    // MARK: Buttons and chips

    /// Primary buttons: white on brand-dark in light (3.5:1, bold labels),
    /// dark text on brand-primary in dark (7.1:1), as the handoff's dark
    /// theme does.
    public static let buttonPrimary = UIColor(light: 0x119B82, dark: 0x20C997)
    public static let buttonPrimaryPressed = UIColor(light: 0x0E856F, dark: 0x119B82)
    public static let buttonPrimaryDisabled = UIColor(light: 0xC5EBDD, dark: 0x1F4A3F)
    public static let buttonPrimaryText = UIColor(light: 0xFFFFFF, dark: 0x092B23)
    public static let buttonSecondary = UIColor(light: 0xEFF4F7, dark: 0x222A32)
    public static let destructive = UIColor(light: 0xE5484D, dark: 0xFF7379)

    public static let chipActiveBackground = UIColor(light: 0xDDF7EE, dark: 0x193D34)
    /// #087F68 → #077D66: the same green, nudged to 4.5:1 on its chip.
    public static let chipActiveText = UIColor(light: 0x077D66, dark: 0x35D6A5)
    public static let chipInactiveBackground = UIColor(light: 0xF1F4F7, dark: 0x222A32)
    public static let chipInactiveText = UIColor(light: 0x627185, dark: 0xA3AFBC)

    // MARK: Borders

    public static let border = UIColor(light: 0xE6EBF0, dark: 0x303943)
    public static let borderSubtle = UIColor(light: 0xF0F3F6, dark: 0x252D35)

    // MARK: Votes and semantics

    /// Vote colors mark the chosen state only; untouched arrows are
    /// iconSecondary. The score is text, so light uses shades of vote-up
    /// #18A878 and vote-down #E45B63 that reach 4.5:1.
    public static let voteUp = UIColor(light: 0x138660, dark: 0x35D6A5)
    public static let voteUpSoft = UIColor(light: 0xE4F8EF, dark: 0x173A2E)
    public static let voteDown = UIColor(light: 0xC64F56, dark: 0xFF7379)
    public static let voteDownSoft = UIColor(light: 0xFCEAEC, dark: 0x3F2226)
    public static let karma = UIColor(light: 0xF2B544, dark: 0xF5C462)
    public static let info = UIColor(light: 0x3989E8, dark: 0x5AA0F0)
    public static let reward = UIColor(light: 0x9367D9, dark: 0xA884E3)

    /// Initial-letter avatars until there are photos: a color per name,
    /// the same on every launch and every device.
    public static func avatarColor(for seed: String) -> UIColor {
        avatarColors[Int(stableHash(seed) % UInt64(avatarColors.count))]
    }

    private static let avatarColors: [UIColor] = [
        UIColor(light: 0x1FA463, dark: 0x2FB872), // green
        UIColor(light: 0x2F80ED, dark: 0x4C93F2), // blue
        UIColor(light: 0xF2994A, dark: 0xF5A963), // orange
        UIColor(light: 0x9B51E0, dark: 0xAD6BE8), // purple
        UIColor(light: 0xEB5757, dark: 0xF06C6C), // red
        UIColor(light: 0x14A3A3, dark: 0x2DB8B8), // teal
        UIColor(light: 0xD9488F, dark: 0xE364A2), // pink
    ]

    /// FNV-1a: String.hashValue is seeded per launch, so it would recolor
    /// every avatar each time the app starts.
    static func stableHash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100_0000_01b3
        }
        return h
    }
}

public extension UIColor {
    convenience init(light: UInt32, dark: UInt32) {
        self.init { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        }
    }

    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

public extension Color {
    /// The interactive green (Palette.accent).
    static let vetkaBrand = Color(uiColor: Palette.accent)
    static let vetkaBrandLight = Color(uiColor: Palette.brandLight)
    static let vetkaTextPrimary = Color(uiColor: Palette.textPrimary)
    static let vetkaSurface = Color(uiColor: Palette.surface)
}

// MARK: - Avatars

/// The first letter of a name on its color. SwiftUI version.
public struct AvatarView: View {
    private let name: String
    private let size: CGFloat

    public init(name: String, size: CGFloat = 40) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(Color(uiColor: Palette.avatarColor(for: name)))
            .frame(width: size, height: size)
            .overlay {
                Text(Avatar.initial(of: name))
                    .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// UIKit version for feed cells. A label with a rounded layer background:
/// no masksToBounds, so no offscreen rendering pass while scrolling.
public final class AvatarLabel: UILabel {
    public override init(frame: CGRect) {
        super.init(frame: frame)
        textAlignment = .center
        textColor = .white
        isAccessibilityElement = false
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.backgroundColor = Palette.avatarColor(for: self.name).resolvedColor(with: self.traitCollection).cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func configure(name: String) {
        text = Avatar.initial(of: name)
        layer.backgroundColor = Palette.avatarColor(for: name).resolvedColor(with: traitCollection).cgColor
        accessibilityLabel = name
        self.name = name
    }

    private var name = ""

    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        font = .systemFont(ofSize: bounds.height * 0.42, weight: .semibold).rounded
    }

}

enum Avatar {
    static func initial(of name: String) -> String {
        let trimmed = name.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }
}

extension UIFont {
    var rounded: UIFont {
        guard let descriptor = fontDescriptor.withDesign(.rounded) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

// MARK: - Logo

/// The leaf and the wordmark from the top-left of the feed.
public struct LogoView: View {
    public init() {}

    public var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(colors: [Color(uiColor: Palette.logoGradient.start), Color(uiColor: Palette.logoGradient.end)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                .rotationEffect(.degrees(-12))
            Text("Ветка")
                .font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundStyle(Color.vetkaTextPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ветка")
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Pills

/// The pill switcher under the feed header: Горячее · Новое · Подписки.
/// The selected pill slides between options instead of jumping.
public struct PillPicker<Value: Hashable>: View {
    private let options: [(value: Value, title: String)]
    @Binding private var selection: Value
    @Namespace private var namespace

    public init(_ options: [(value: Value, title: String)], selection: Binding<Value>) {
        self.options = options
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    guard !selected else { return }
                    Haptics.selection()
                    withAnimation(.vetkaSnappy) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(uiColor: selected ? Palette.chipActiveText : Palette.chipInactiveText))
                        .padding(.horizontal, Spacing.l)
                        .padding(.vertical, 7)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color(uiColor: Palette.chipActiveBackground))
                                    .matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(Spacing.xs)
        .background(Capsule().fill(Color(uiColor: Palette.chipInactiveBackground)))
    }
}

/// A small capsule button: filled green for an action ("Подписаться"),
/// soft for the done state ("Вы подписаны").
public struct PillButtonStyle: ButtonStyle {
    let filled: Bool

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(uiColor: filled ? Palette.buttonPrimaryText : Palette.chipActiveText))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color(uiColor: filled ? Palette.buttonPrimary : Palette.chipActiveBackground)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.vetkaSnappy, value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == PillButtonStyle {
    static func pill(filled: Bool = true) -> PillButtonStyle {
        PillButtonStyle(filled: filled)
    }
}

// MARK: - Primary button

/// The main action of a screen: full width, 50 pt, token colors for every
/// state (normal, pressed, disabled). Replaces `.borderedProminent`, whose
/// white label on the light dark-theme green would read at 1.9:1.
public struct PrimaryButtonStyle: ButtonStyle {
    let fullWidth: Bool

    public func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, fullWidth: fullWidth)
    }

    private struct PrimaryButtonBody: View {
        let configuration: Configuration
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.headline)
                .foregroundStyle(Color(uiColor: Palette.buttonPrimaryText))
                .tint(Color(uiColor: Palette.buttonPrimaryText)) // a ProgressView inside the label
                .padding(.horizontal, Spacing.xl)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: fullWidth ? 50 : 40)
                .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(background))
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.vetkaSnappy, value: configuration.isPressed)
        }

        private var background: Color {
            let color = !isEnabled ? Palette.buttonPrimaryDisabled
                : configuration.isPressed ? Palette.buttonPrimaryPressed : Palette.buttonPrimary
            return Color(uiColor: color)
        }
    }
}

public extension ButtonStyle where Self == PrimaryButtonStyle {
    /// `fullWidth: false` for buttons inside empty states and banners.
    static func vetkaPrimary(fullWidth: Bool = true) -> PrimaryButtonStyle {
        PrimaryButtonStyle(fullWidth: fullWidth)
    }
}

public extension UIButton.Configuration {
    /// UIKit twin of PrimaryButtonStyle, for UIContentUnavailableConfiguration.
    static func vetkaPrimary(title: String) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = Palette.buttonPrimary
        config.baseForegroundColor = Palette.buttonPrimaryText
        config.cornerStyle = .large
        config.buttonSize = .large
        return config
    }
}

public extension Color {
    static let vetkaSuccess = Color(uiColor: Palette.voteUp)
    static let vetkaDanger = Color(uiColor: Palette.destructive)
}
