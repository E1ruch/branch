import Core
import DesignSystem
import Networking
import SwiftUI

/// Конфиденциальность. For now one thing: deleting the account, which the
/// App Store requires an app with accounts to offer. It asks first and says
/// plainly what happens.
public struct PrivacyScreen: View {
    private let username: String?
    private let deleteAccount: () async throws(APIError) -> Void
    @State private var isConfirming = false
    @State private var isDeleting = false
    @State private var failure: String?

    public init(username: String?, deleteAccount: @escaping () async throws(APIError) -> Void) {
        self.username = username
        self.deleteAccount = deleteAccount
    }

    public var body: some View {
        List {
            Section {
                Button {
                    Haptics.tap()
                    isConfirming = true
                } label: {
                    HStack {
                        SettingsLabel(title: "Удалить аккаунт", systemImage: "trash.fill",
                                      color: Palette.destructive, titleColor: .vetkaDanger)
                        if isDeleting {
                            ProgressView()
                        }
                    }
                }
                .disabled(isDeleting)
                .groupedRow()
                .accessibilityIdentifier("privacy.deleteAccount")
            } header: {
                Text("Удаление аккаунта")
            } footer: {
                Text("Ваши посты и комментарии останутся, но без автора. Ник освободится, вход на всех устройствах завершится. Восстановить аккаунт будет нельзя.")
            }
        }
        .groupedListStyle()
        .navigationTitle("Конфиденциальность")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.vetkaBackground, for: .navigationBar)
        .alert("Удалить аккаунт\(username.map { " @\($0)" } ?? "")?", isPresented: $isConfirming) {
            Button("Удалить", role: .destructive) {
                Task { await delete() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Это действие нельзя отменить.")
        }
        .alert("Не удалось удалить аккаунт", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func delete() async {
        isDeleting = true
        defer { isDeleting = false }
        do throws(APIError) {
            try await deleteAccount()
            Haptics.success()
        } catch {
            Haptics.error()
            failure = if case .transport = error {
                "Нет соединения с сервером. Попробуйте ещё раз."
            } else {
                "Попробуйте ещё раз чуть позже."
            }
        }
    }
}
