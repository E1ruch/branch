import DesignSystem
import SwiftUI
import UIKit

/// The colored rounded square in front of a settings row, as in Telegram:
/// the color tells rows apart before the words are read.
struct SettingsIcon: View {
    let systemImage: String
    let color: UIColor

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(uiColor: color))
            .frame(width: 30, height: 30)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Icon, title and, on the right, the current value ("Светлая").
struct SettingsLabel: View {
    let title: String
    let systemImage: String
    let color: UIColor
    var value: String?
    var titleColor: Color = .vetkaTextPrimary

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(systemImage: systemImage, color: color)
            Text(title)
                .foregroundStyle(titleColor)
            Spacer(minLength: Spacing.s)
            if let value {
                Text(value)
                    .foregroundStyle(Color.vetkaSecondaryText)
                    .contentTransition(.opacity)
            }
        }
        .frame(minHeight: 34)
    }
}
