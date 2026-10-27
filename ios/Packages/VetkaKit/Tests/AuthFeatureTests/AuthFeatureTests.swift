import Networking
import Testing
@testable import AuthFeature

@Suite struct NonceTests {
    @Test func sha256MatchesKnownVector() {
        // FIPS 180-2 test vector.
        #expect(Nonce.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func randomNonceIsURLSafeAndUnique() {
        let a = Nonce.random(), b = Nonce.random()
        #expect(a != b)
        #expect(a.count == 43) // 32 bytes, base64 without padding
        #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }
}

@Suite struct UsernameRuleTests {
    @Test(arguments: ["ivan", "Ivan_2", "abc", String(repeating: "a", count: 24)])
    func valid(_ name: String) {
        #expect(UsernameRule.isValid(name))
    }

    @Test(arguments: ["ab", "иван", "ivan petrov", "ivan!", "", String(repeating: "a", count: 25)])
    func invalid(_ name: String) {
        #expect(!UsernameRule.isValid(name))
    }
}

@Suite struct AuthErrorTextTests {
    @Test func wrongPasswordAndUnknownUserReadTheSame() {
        let error = APIError.server(status: 401, code: "invalid_credentials", message: "", field: nil)
        #expect(AuthErrorText.message(for: error, signingIn: true) == "Неверный ник или пароль")
    }

    @Test func fieldErrorsNameTheField() {
        let password = APIError.server(status: 422, code: "validation_failed", message: "", field: "password")
        #expect(AuthErrorText.message(for: password, signingIn: false).hasPrefix("Пароль"))
        let taken = APIError.server(status: 409, code: "username_taken", message: "", field: "username")
        #expect(AuthErrorText.message(for: taken, signingIn: false) == "Этот ник уже занят")
    }

    @Test func offlineIsNotBlamedOnTheUser() {
        #expect(AuthErrorText.message(for: .transport(.notConnectedToInternet), signingIn: true) == "Нет соединения с сервером")
    }
}
