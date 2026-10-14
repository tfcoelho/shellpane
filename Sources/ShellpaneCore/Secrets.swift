import Foundation
import Security
import SSHProcess

/// Where passwords and key passphrases live. Never the database, never a file, never a log.
public protocol SecretStore: Sendable {
    func secret(for ref: String) throws -> String?
    func setSecret(_ secret: String, for ref: String, label: String) throws
    func deleteSecret(for ref: String) throws
}

public struct KeychainError: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// The user's login keychain, as generic passwords under one service name.
/// Each favorite's item is found by its keychain_ref (a random UUID), so renaming a server never orphans it.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "app.shellpane.credentials") {
        self.service = service
    }

    private func query(_ ref: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: ref]
    }

    public func secret(for ref: String) throws -> String? {
        var q = query(ref)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ secret: String, for ref: String, label: String) throws {
        let data = Data(secret.utf8)
        let update: [String: Any] = [kSecValueData as String: data, kSecAttrLabel as String: label]
        let status = SecItemUpdate(query(ref) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(ref)
            add.merge(update) { $1 }
            add[kSecAttrDescription as String] = "Shellpane server password"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func deleteSecret(for ref: String) throws {
        let status = SecItemDelete(query(ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// For tests and previews.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]

    public init() {}

    public func secret(for ref: String) throws -> String? { lock.withLock { items[ref] } }
    public func setSecret(_ secret: String, for ref: String, label: String) throws { lock.withLock { items[ref] = secret } }
    public func deleteSecret(for ref: String) throws { lock.withLock { _ = items.removeValue(forKey: ref) } }
}

/// Decides what to tell ssh when it asks for a secret during one connection attempt.
/// The saved secret is offered once; if ssh asks again, it was wrong, so the person is asked instead.
/// A secret the person types is saved only after the connection succeeds.
public final class CredentialContext: @unchecked Sendable {
    public enum Decision: Equatable, Sendable {
        case answer(String)
        case askUser
    }

    public let keychainRef: String?
    public let label: String
    private let store: SecretStore
    private let lock = NSLock()
    private var savedOffered = false
    private var typedOnce: String?
    private var pendingSave: String?
    public private(set) var savedSecretWasRejected = false

    /// - typedSecret: a password typed into the Connect form, used for the first prompt.
    public init(keychainRef: String?, label: String, store: SecretStore, typedSecret: String? = nil) {
        self.keychainRef = keychainRef
        self.label = label
        self.store = store
        self.typedOnce = typedSecret.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func decide(_ request: AskpassRequest) -> Decision {
        guard request.kind == .secret else { return .askUser }
        return lock.withLock {
            if let typed = typedOnce {
                typedOnce = nil
                return .answer(typed)
            }
            if !savedOffered, let ref = keychainRef, let saved = try? store.secret(for: ref) {
                savedOffered = true
                return .answer(saved)
            }
            if savedOffered { savedSecretWasRejected = true }
            return .askUser
        }
    }

    /// The person typed this and asked to keep it. Saved by `connectionSucceeded()`.
    public func rememberAfterSuccess(_ secret: String) {
        lock.withLock { pendingSave = secret }
    }

    public func connectionSucceeded() throws {
        let toSave = lock.withLock { () -> String? in
            defer { pendingSave = nil }
            return pendingSave
        }
        if let toSave, let ref = keychainRef {
            try store.setSecret(toSave, for: ref, label: label)
        }
    }
}
