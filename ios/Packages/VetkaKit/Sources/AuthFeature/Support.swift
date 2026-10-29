import Core
import CryptoKit
import Foundation
import Networking
import UIKit

/// The Sign in with Apple nonce: the app keeps the raw value, Apple gets its
/// SHA-256 and embeds it in the identity token, the server checks they match.
/// A token intercepted elsewhere is useless without the raw value.
enum Nonce {
    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum PasswordRule {
    static let minLength = 8
}

/// Shown in "Активные сеансы" later; also helps tell sessions apart in logs.
@MainActor
func currentDeviceName() -> String {
    "\(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)"
}

/// Turns API errors into Russian text. The server's message is for
/// developers; the stable code decides what the user reads.
enum AuthErrorText {
    static func message(for error: APIError, signingIn: Bool) -> String {
        switch error {
        case .server(_, "invalid_credentials", _, _):
            signingIn ? "Неверный ник или пароль" : "Не удалось подтвердить вход. Попробуйте ещё раз."
        case .server(_, "username_taken", _, _):
            "Этот ник уже занят"
        case .server(_, "validation_failed", _, "username"):
            "Ник: \(UsernameRule.hint)"
        case .server(_, "validation_failed", _, "password"):
            "Пароль — от \(PasswordRule.minLength) символов и не совпадает с ником"
        case .server(_, "rate_limited", _, _):
            "Слишком много попыток. Попробуйте через несколько минут."
        case .server(_, "provider_unavailable", _, _):
            "Сервис входа недоступен. Попробуйте позже."
        case .transport:
            "Нет соединения с сервером"
        default:
            "Что-то пошло не так. Попробуйте ещё раз."
        }
    }
}
