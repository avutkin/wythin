import Foundation
import CryptoKit
import Security

protocol HealthCredentialStorage: Sendable {
    func load(server: URL) throws -> HealthEnrollment?
    func save(_ enrollment: HealthEnrollment, server: URL) throws
    func remove(server: URL) throws
}

struct HealthCredentialStore: HealthCredentialStorage {
    struct StoreError: Error, LocalizedError, Sendable {
        let status: OSStatus
        var errorDescription: String? { "Health cloud credential storage is unavailable (\(status))." }
    }

    /// Canonical origin is hashed so no server or secret appears in Keychain metadata.
    static func namespace(for server: URL) throws -> String {
        let origin = try HealthServerOrigin.url(for: server).absoluteString
        return SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func load(server: URL) throws -> HealthEnrollment? {
        var query = try query(server: server)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError(status: status) }
        guard let data = result as? Data else { throw StoreError(status: errSecDecode) }
        do { return try HealthCoding.decode(HealthEnrollment.self, from: data) }
        catch { throw StoreError(status: errSecDecode) }
    }

    func save(_ enrollment: HealthEnrollment, server: URL) throws {
        let query = try query(server: server)
        let data = try HealthCoding.encode(enrollment)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw StoreError(status: added) }
        } else if status != errSecSuccess { throw StoreError(status: status) }
    }

    func remove(server: URL) throws {
        let status = SecItemDelete(try query(server: server) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError(status: status) }
    }

    private func query(server: URL) throws -> [String: Any] {
        let namespace = try Self.namespace(for: server)
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.wythin.health.\(namespace)",
            kSecAttrAccount as String: namespace,
            kSecAttrSynchronizable as String: false
        ]
    }
}
