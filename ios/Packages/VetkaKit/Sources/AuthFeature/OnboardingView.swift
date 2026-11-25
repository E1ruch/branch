import Core
import DesignSystem
import SwiftUI

struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @FocusState private var usernameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var motion: Animation { reduceMotion ? .easeOut(duration: 0.15) : .vetkaSnappy }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(model.isRequired ? "Придумайте ник" : "Как вас называть?")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("onboarding.title")
                    Text("По этому нику вас смогут найти и упомянуть в «Ветке».")
                        .foregroundStyle(Color.vetkaSecondaryText)
                }
                .padding(.top, Spacing.xl)

                VStack(alignment: .leading, spacing: Spacing.s) {
                    HStack(spacing: Spacing.xs) {
                        Text("@").foregroundStyle(Color.vetkaSecondaryText)
                            .accessibilityHidden(true)
                        TextField("ник", text: $model.username)
                            .textContentType(model.isRequired ? nil : .username)
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.continue)
                            .focused($usernameFocused)
                            .onSubmit { Task { _ = await model.save() } }
                            .disabled(model.isSaving || model.isSigningOut)
                            .accessibilityIdentifier("onboarding.username")
                    }
                    .padding(.horizontal, Spacing.l)
                    .frame(minHeight: 50)
                    .background(Color.vetkaField, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))

                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Сменить ник можно раз в 30 дней.")
                            .foregroundStyle(Color.vetkaSecondaryText)
                        ZStack(alignment: .leading) {
                            Color.clear.frame(height: 20)
                            status.transition(.opacity)
                        }
                        .animation(motion, value: model.availability)
                        .accessibilityIdentifier("onboarding.status")
                    }
                    .font(.footnote)
                }

                if !model.isRequired {
                    TextField("Имя (необязательно)", text: $model.displayName)
                        .textContentType(.name)
                        .padding(.horizontal, Spacing.l)
                        .frame(minHeight: 50)
                        .background(Color.vetkaField, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .disabled(model.isSaving)
                }

                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(Color.vetkaDanger)
                        .accessibilityIdentifier("onboarding.error")
                }

                Button {
                    Task { _ = await model.save() }
                } label: {
                    ZStack {
                        Text("Продолжить").opacity(model.isSaving ? 0 : 1)
                        if model.isSaving { ProgressView() }
                    }
                    .animation(motion, value: model.isSaving)
                }
                .buttonStyle(.vetkaPrimary())
                .disabled(!model.canSave)
                .accessibilityIdentifier("onboarding.continue")
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                if model.isRequired {
                    Button("Выйти") { Task { await model.signOut() } }
                        .disabled(model.isSaving || model.isSigningOut)
                        .accessibilityIdentifier("onboarding.signOut")
                } else {
                    Button("Пропустить") { model.skip() }
                        .disabled(model.isSaving)
                }
            }
        }
        .task(id: model.username) { await model.checkAvailability() }
        .onAppear { if !model.isRequired { usernameFocused = true } }
    }

    @ViewBuilder
    private var status: some View {
        switch model.availability {
        case .current where model.isRequired:
            Text(UsernameRule.hint).foregroundStyle(Color.vetkaSecondaryText)
        case .current:
            Text("Это ваш текущий ник — можно оставить")
                .foregroundStyle(Color.vetkaSecondaryText)
        case .checking:
            Text("Проверяем ник…").foregroundStyle(Color.vetkaSecondaryText)
        case .available:
            Label("Ник свободен", systemImage: "checkmark.circle.fill").foregroundStyle(Color.vetkaSuccess)
        case .taken:
            Label("Ник занят. Попробуйте другой.", systemImage: "xmark.circle.fill").foregroundStyle(Color.vetkaDanger)
        case let .invalid(message):
            Text(message).foregroundStyle(Color.vetkaDanger)
        case .unknown:
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Не удалось проверить доступность ника")
                    .foregroundStyle(Color.vetkaSecondaryText)
                Button("Проверить ещё раз") { Task { await model.checkAvailability() } }
            }
        }
    }
}
