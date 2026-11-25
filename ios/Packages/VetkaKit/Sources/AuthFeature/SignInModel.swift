import AuthenticationServices
import Core
import DesignSystem
import Foundation
import Networking
import Observation
import Session

@MainActor
@Observable
public final class SignInModel {
    public enum Mode: Hashable {
        case login, register
    }

    public var mode: Mode = .login {
        didSet { error = nil }
    }
    public var email = "" {
        didSet { error = nil }
    }
    public var password = "" {
        didSet { error = nil }
    }
    public private(set) var isWorking = false
    public private(set) var error: String?

    private var appleNonce: String?
    private let client: APIClient
    private let session: SessionStore

    public init(client: APIClient, session: SessionStore) {
        self.client = client
        self.session = session
    }

    var canSubmit: Bool {
        guard !isWorking, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return mode == .login ? !password.isEmpty : password.unicodeScalars.count >= PasswordRule.minLength
    }

    func submitPassword() async {
        guard canSubmit else { return }
        let device = currentDeviceName()
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoint = mode == .login
            ? API.login(email: email, password: password, deviceName: device)
            : API.register(email: email, password: password, deviceName: device)
        await signIn(with: endpoint, signingIn: mode == .login)
    }

    // MARK: Sign in with Apple

    func prepare(_ request: ASAuthorizationAppleIDRequest) {
        let raw = Nonce.random()
        appleNonce = raw
        request.requestedScopes = [.fullName]
        request.nonce = Nonce.sha256(raw)
    }

    func complete(_ result: Result<ASAuthorization, any Error>) async {
        switch result {
        case let .failure(error as ASAuthorizationError) where error.code == .canceled:
            return // the user closed the sheet: not an error
        case .failure:
            self.error = "Не удалось войти через Apple. Попробуйте ещё раз."
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let token = String(data: tokenData, encoding: .utf8),
                  let nonce = appleNonce else {
                error = "Не удалось войти через Apple. Попробуйте ещё раз."
                return
            }
            let body = API.AppleSignIn(identityToken: token, nonce: nonce,
                                       givenName: credential.fullName?.givenName,
                                       familyName: credential.fullName?.familyName,
                                       deviceName: currentDeviceName())
            await signIn(with: API.signInWithApple(body), signingIn: false)
        }
    }

    private func signIn(with endpoint: Endpoint<AuthSession>, signingIn: Bool) async {
        isWorking = true
        error = nil
        defer { isWorking = false }
        do {
            let result = try await client.send(endpoint)
            Haptics.success()
            await session.didSignIn(result)
            password = ""
        } catch .cancelled {
            // The sheet went away mid-request.
        } catch {
            Haptics.error()
            self.error = AuthErrorText.message(for: error, signingIn: signingIn)
        }
    }
}
