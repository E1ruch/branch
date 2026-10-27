import DesignSystem
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @FocusState private var usernameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text("Как вас называть?")
                        .font(.largeTitle.bold())
                    Text("Ник виден всем: по нему вас находят и упоминают. Сменить его потом можно раз в 30 дней.")
                        .foregroundStyle(Color.vetkaSecondaryText)
                }
                .padding(.top, Spacing.xl)

                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(spacing: Spacing.xs) {
                        Text("@").foregroundStyle(Color.vetkaSecondaryText)
                        TextField("ник", text: $model.username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($usernameFocused)
                            .accessibilityIdentifier("onboarding.username")
                    }
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: 50)
                    .background(Color.vetkaField, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))

                    status
                        .font(.footnote)
                        .frame(minHeight: 18, alignment: .leading)
                        .animation(.vetkaSnappy, value: model.availability)
                }

                TextField("Имя (необязательно)", text: $model.displayName)
                    .textContentType(.name)
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: 50)
                    .background(Color.vetkaField, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))

                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(Color.vetkaDanger)
                }

                Button {
                    Task { _ = await model.save() }
                } label: {
                    ZStack {
                        Text("Продолжить").opacity(model.isSaving ? 0 : 1)
                        if model.isSaving { ProgressView() }
                    }
                }
                .buttonStyle(.vetkaPrimary())
                .disabled(!model.canSave)
                .accessibilityIdentifier("onboarding.continue")
            }
            .padding(.horizontal, Spacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Пропустить") { model.skip() }
            }
        }
        .task(id: model.username) { await model.checkAvailability() }
        .onAppear { usernameFocused = true }
    }

    @ViewBuilder
    private var status: some View {
        switch model.availability {
        case .current:
            Text("Это ваш текущий ник — можно оставить")
                .foregroundStyle(Color.vetkaSecondaryText)
        case .checking:
            Text("Проверяем…").foregroundStyle(Color.vetkaSecondaryText)
        case .available:
            Label("Свободен", systemImage: "checkmark.circle.fill").foregroundStyle(Color.vetkaSuccess)
        case .taken:
            Label("Занят", systemImage: "xmark.circle.fill").foregroundStyle(Color.vetkaDanger)
        case let .invalid(message):
            Text(message).foregroundStyle(Color.vetkaDanger)
        case .unknown:
            Text("Не удалось проверить — проверим при сохранении")
                .foregroundStyle(Color.vetkaSecondaryText)
        }
    }
}
