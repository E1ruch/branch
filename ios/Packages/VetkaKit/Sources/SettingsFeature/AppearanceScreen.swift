import DesignSystem
import SwiftUI
import UIKit

/// Оформление: the two themes as small pictures of the app itself, and
/// "Как в системе". A tap spreads the new theme from the finger.
public struct AppearanceScreen: View {
    private let theme: ThemeStore
    /// The look on screen now: the theme picked, or the iPhone's while
    /// following the system (no override on the window then).
    @Environment(\.colorScheme) private var colorScheme

    public init(theme: ThemeStore) {
        self.theme = theme
    }

    public var body: some View {
        List {
            Section {
                HStack(spacing: Spacing.l) {
                    card(.light)
                    card(.dark)
                }
                .padding(.vertical, Spacing.m)
                .settingsRow()
            } header: {
                Text("Тема")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { theme.theme == .system },
                    set: { follow in
                        Haptics.selection()
                        // Leaving the system keeps the look on screen.
                        theme.select(follow ? .system : (colorScheme == .dark ? .dark : .light))
                    })) {
                    SettingsLabel(title: "Как в системе", systemImage: "iphone", color: Palette.info)
                }
                .tint(.vetkaBrand)
                .settingsRow()
                .accessibilityIdentifier("appearance.system")
            } footer: {
                Text("Тема будет меняться вместе с настройкой iPhone — например, тёмная вечером.")
            }
        }
        .settingsListStyle()
        .navigationTitle("Оформление")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.vetkaBackground, for: .navigationBar)
    }

    private func card(_ option: ThemeStore.Theme) -> some View {
        let style: UIUserInterfaceStyle = option == .dark ? .dark : .light
        let isOn = (colorScheme == .dark) == (option == .dark)
        return ThemeCard(style: style, title: option.title, isSelected: isOn)
            .onTapGesture(coordinateSpace: .global) { location in
                guard theme.theme != option else { return }
                Haptics.selection()
                theme.select(option, revealFrom: location)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(option.title + " тема")
            .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { theme.select(option) }
            .accessibilityIdentifier("appearance.\(option.rawValue)")
    }
}

/// A theme's picture with its name and a radio mark under it.
private struct ThemeCard: View {
    let style: UIUserInterfaceStyle
    let title: String
    let isSelected: Bool

    var body: some View {
        VStack(spacing: Spacing.m) {
            ThemePreview(style: style)
                .aspectRatio(0.62, contentMode: .fit)
                .padding(4)
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(isSelected ? Color.vetkaBrand : Color(uiColor: Palette.border),
                                      lineWidth: isSelected ? 2.5 : 1)
                }
                .scaleEffect(isSelected ? 1 : 0.97)
            HStack(spacing: Spacing.s) {
                ZStack {
                    Circle()
                        .strokeBorder(Color(uiColor: Palette.iconDisabled), lineWidth: 1.5)
                        .opacity(isSelected ? 0 : 1)
                    Circle()
                        .fill(Color.vetkaBrand)
                        .overlay {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color(uiColor: Palette.buttonPrimaryText))
                        }
                        .scaleEffect(isSelected ? 1 : 0.2)
                        .opacity(isSelected ? 1 : 0)
                }
                .frame(width: 22, height: 22)
                Text(title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(Color.vetkaTextPrimary)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .animation(.vetka, value: isSelected)
    }
}

/// The app in miniature, drawn in one theme's colors whatever the screen
/// shows: the feed header with its pills, two posts as skeleton bars, the
/// tab bar with the green "+".
struct ThemePreview: View {
    let style: UIUserInterfaceStyle

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 5) {
                post(avatar: "dev", lines: [1, 0.85, 0.6])
                post(avatar: "kotiki", lines: [0.9])
                post(avatar: "live", lines: [1, 0.7])
            }
            .padding(.vertical, 5)
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
            tabBar
        }
        .background(color(Palette.background))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Circle().fill(color(Palette.brandPrimary)).frame(width: 9, height: 9)
                bar(Palette.textPrimary, width: 26, height: 5)
                Spacer(minLength: 0)
                Circle().fill(color(Palette.iconSecondary)).frame(width: 6, height: 6)
                Circle().fill(color(Palette.reward)).frame(width: 10, height: 10)
            }
            HStack(spacing: 3) {
                Capsule().fill(color(Palette.chipActiveBackground)).frame(width: 22, height: 8)
                Capsule().fill(color(Palette.chipInactiveBackground)).frame(width: 18, height: 8)
                Capsule().fill(color(Palette.chipInactiveBackground)).frame(width: 20, height: 8)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .background(color(Palette.surface))
    }

    private func post(avatar: String, lines: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle().fill(color(Palette.avatarColor(for: avatar))).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    bar(Palette.textSecondary, width: 24, height: 3)
                    bar(Palette.textTertiary, width: 16, height: 2.5)
                }
            }
            GeometryReader { proxy in
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, part in
                        bar(index == 0 ? Palette.textPrimary : Palette.textTertiary,
                            width: proxy.size.width * part, height: index == 0 ? 4.5 : 3)
                    }
                }
            }
            .frame(height: CGFloat(lines.count) * 6)
            HStack(spacing: 4) {
                bar(Palette.voteUp, width: 10, height: 3.5)
                bar(Palette.iconDisabled, width: 8, height: 3.5)
                bar(Palette.iconDisabled, width: 8, height: 3.5)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(Palette.surface))
    }

    private var tabBar: some View {
        HStack {
            ForEach(0..<5) { index in
                if index == 2 {
                    Circle().fill(color(Palette.buttonPrimary)).frame(width: 12, height: 12)
                } else {
                    Circle().fill(color(index == 0 ? Palette.accent : Palette.iconDisabled)).frame(width: 7, height: 7)
                }
                if index < 4 { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color(Palette.surface))
        .overlay(alignment: .top) {
            Rectangle().fill(color(Palette.border)).frame(height: 0.5)
        }
    }

    private func bar(_ ui: UIColor, width: CGFloat, height: CGFloat) -> some View {
        Capsule().fill(color(ui)).frame(width: width, height: height)
    }

    private func color(_ ui: UIColor) -> Color {
        Color(uiColor: ui.resolvedColor(with: UITraitCollection(userInterfaceStyle: style)))
    }
}
