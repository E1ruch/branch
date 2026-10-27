import Core
import Foundation
import Security

/// Where tokens survive app restarts.
public protocol TokenPersistence: Sendable {
    func load() -> Tokens?
    func save(_ tokens: Tokens?)
}

/// Keychain storage: available after the first unlock (so background
/// refreshes work), never synced to iCloud or restored to another device.
public struct KeychainTokenPersistence: TokenPersistence {
    private let service: String
    private let account = "session"

    public init(service: String = "vetka.session") {
        self.service = service
    }

    public func load() -> Tokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSON.decoder().decode(Tokens.self, from: data)
    }

    public func save(_ tokens: Tokens?) {
        SecItemDelete(baseQuery as CFDictionary)
        guard let tokens, let data = try? JSON.encoder().encode(tokens) else { return }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// For tests and previews.
public final class InMemoryTokenPersistence: TokenPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: Tokens?

    public init(_ tokens: Tokens? = nil) {
        self.tokens = tokens
    }

    public func load() -> Tokens? {
        lock.withLock { tokens }
    }

    public func save(_ tokens: Tokens?) {
        lock.withLock { self.tokens = tokens }
    }
}
