import Core
import DesignSystem
import SwiftUI

/// Настройки, opened from the gear on your profile: who you are (opens
/// profile editing), how the app looks, and signing out.
public struct SettingsScreen: View {
    private let me: Me?
    private let theme: ThemeStore
    private let signOut: () async -> Void
    @State private var isSignOutConfirming = false

    public init(me: Me?, theme: ThemeStore, signOut: @escaping () async -> Void) {
        self.me = me
        self.theme = theme
        self.signOut = signOut
    }

    public var body: some View {
        List {
            if let me {
                // Who is signed in, as Telegram opens its settings: not a
                // row, the page's own header.
                VStack(spacing: Spacing.xs) {
                    AvatarView(name: me.username, size: 84)
                        .padding(.bottom, Spacing.s)
                    Text(me.displayName ?? me.username)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.vetkaTextPrimary)
                        .multilineTextAlignment(.center)
                    Text("@" + me.username)
                        .font(.subheadline)
                        .foregroundStyle(Color.vetkaSecondaryText)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityElement(children: .combine)
            }

            Section {
                NavigationLink(value: Route.editProfile) {
                    SettingsLabel(title: "Изменить профиль", systemImage: "person.fill", color: Palette.info)
                }
                .settingsRow()
                .accessibilityIdentifier("settings.editProfile")
                NavigationLink(value: Route.appearance) {
                    SettingsLabel(title: "Оформление", systemImage: "paintbrush.fill", color: Palette.reward,
                                  value: theme.theme.title)
                }
                .settingsRow()
                .accessibilityIdentifier("settings.appearance")
            }

            Section {
                Button {
                    isSignOutConfirming = true
                } label: {
                    SettingsLabel(title: "Выйти", systemImage: "rectangle.portrait.and.arrow.right",
                                  color: Palette.destructive, titleColor: .vetkaDanger)
                }
                .settingsRow()
                .accessibilityIdentifier("settings.signOut")
            } footer: {
                Text(Self.version)
                    .frame(maxWidth: .infinity)
                    .padding(.top, Spacing.xl)
            }
        }
        .settingsListStyle()
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.vetkaBackground, for: .navigationBar)
        .confirmationDialog("Выйти из аккаунта?", isPresented: $isSignOutConfirming, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) {
                Task { await signOut() }
            }
        } message: {
            Text("Черновики останутся на этом iPhone.")
        }
    }

    /// "Ветка 1.0 (12)" at the bottom, as Telegram does.
    private static let version: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Ветка \(short) (\(build))"
    }()
}
