import AuthenticationServices
import DesignSystem
import SwiftUI

struct SignInView: View {
    @Bindable var model: SignInModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focus: Field?

    private enum Field { case username, password }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                VStack(spacing: Spacing.s) {
                    Text("Ветка")
                        .font(.largeTitle.bold())
                    Text("Сообщества по интересам")
                        .foregroundStyle(Color.vetkaSecondaryText)
                }
                .padding(.top, Spacing.xl)

                Picker("Режим", selection: $model.mode.animation(.vetkaSnappy)) {
                    Text("Вход").tag(SignInModel.Mode.login)
                    Text("Регистрация").tag(SignInModel.Mode.register)
                }
                .pickerStyle(.segmented)

                passwordForm

                HStack {
                    VStack { Divider() }
                    Text("или").font(.footnote).foregroundStyle(Color.vetkaSecondaryText)
                    VStack { Divider() }
                }

                SignInWithAppleButton(.signIn) { request in
                    model.prepare(request)
                } onCompletion: { result in
                    Task { await model.complete(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .disabled(model.isWorking)

                if let error = model.error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .accessibilityIdentifier("auth.error")
                }
            }
            .padding(.horizontal, Spacing.xl)
            .animation(.vetka, value: model.error)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focus = .username }
    }

    private var passwordForm: some View {
        VStack(spacing: Spacing.m) {
            TextField("Ник", text: $model.username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .username)
                .onSubmit { focus = .password }
                .fieldStyle()
                .accessibilityIdentifier("auth.username")

            SecureField("Пароль", text: $model.password)
                .textContentType(model.mode == .login ? .password : .newPassword)
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit { Task { await model.submitPassword() } }
                .fieldStyle()
                .accessibilityIdentifier("auth.password")

            if model.mode == .register {
                Text("Ник: \(UsernameRule.hint). Пароль — от \(PasswordRule.minLength) символов.")
                    .font(.footnote)
                    .foregroundStyle(Color.vetkaSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await model.submitPassword() }
            } label: {
                ZStack {
                    Text(model.mode == .login ? "Войти" : "Создать аккаунт")
                        .opacity(model.isWorking ? 0 : 1)
                    if model.isWorking {
                        ProgressView().tint(.white)
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: Radius.card))
            .disabled(!model.canSubmit)
            .accessibilityIdentifier("auth.submit")
        }
    }
}

private extension View {
    func fieldStyle() -> some View {
        padding(.horizontal, Spacing.l)
            .frame(minHeight: 50)
            .background(Color.vetkaField, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}
