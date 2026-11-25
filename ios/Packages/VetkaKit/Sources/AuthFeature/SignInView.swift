import AuthenticationServices
import DesignSystem
import SwiftUI

struct SignInView: View {
    @Bindable var model: SignInModel
    let showsSignInWithApple: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    private var motion: Animation? { reduceMotion ? nil : .vetkaSnappy }

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

                Picker("Режим", selection: $model.mode) {
                    Text("Вход").tag(SignInModel.Mode.login)
                    Text("Регистрация").tag(SignInModel.Mode.register)
                }
                .pickerStyle(.segmented)
                .disabled(model.isWorking)

                passwordForm

                if showsSignInWithApple {
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
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { focus = .email }
    }

    private var passwordForm: some View {
        VStack(spacing: Spacing.m) {
            TextField("Email", text: $model.email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .email)
                .onSubmit { focus = .password }
                .fieldStyle()
                .disabled(model.isWorking)
                .accessibilityIdentifier("auth.email")

            SecureField("Пароль", text: $model.password)
                .textContentType(model.mode == .login ? .password : .newPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit { Task { await model.submitPassword() } }
                .fieldStyle()
                .disabled(model.isWorking)
                .accessibilityIdentifier("auth.password")

            ZStack(alignment: .leading) {
                Color.clear.frame(height: 20)
                if let error = model.error {
                    Text(error)
                        .foregroundStyle(Color.vetkaDanger)
                        .accessibilityIdentifier("auth.error")
                } else if model.mode == .register {
                    Text("Пароль — от \(PasswordRule.minLength) символов.")
                        .foregroundStyle(Color.vetkaSecondaryText)
                }
            }
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(motion, value: model.error)
            .animation(motion, value: model.mode)

            Button {
                Task { await model.submitPassword() }
            } label: {
                ZStack {
                    Text(model.mode == .login ? "Войти" : "Создать аккаунт")
                        .contentTransition(.opacity)
                        .opacity(model.isWorking ? 0 : 1)
                    if model.isWorking {
                        ProgressView()
                    }
                }
                .animation(motion, value: model.mode)
                .animation(motion, value: model.isWorking)
            }
            .buttonStyle(.vetkaPrimary())
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
