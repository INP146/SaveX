import Foundation
import Security

protocol SecureStringStoring: Sendable {
    func read() throws -> String?
    func write(_ value: String) throws
    func delete() throws
}

enum KeychainStringStoreError: Error {
    case unexpectedData
    case unhandledStatus(OSStatus)
}

struct KeychainStringStore: SecureStringStoring {
    let service: String
    let account: String
    var accessGroup: String?

    init(service: String, account: String, accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    func read() throws -> String? {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw KeychainStringStoreError.unexpectedData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStringStoreError.unhandledStatus(status)
        }
    }

    func write(_ value: String) throws {
        let data = Data(value.utf8)
        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess {
            return
        }
        guard status == errSecDuplicateItem else {
            throw KeychainStringStoreError.unhandledStatus(status)
        }

        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw KeychainStringStoreError.unhandledStatus(updateStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStringStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
