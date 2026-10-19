import Foundation
import Security

protocol DeviceKeyStore: Sendable {
    func key(for id: String) -> Data?
    func save(_ key: Data, for id: String) throws
    func delete(_ id: String)
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")" }
}

/// The device key in the iOS Keychain, readable after the first unlock and never copied to another device.
struct KeychainKeyStore: DeviceKeyStore {
    static let service = "com.niklasinde.MeetingRecorderPhone.device"

    var service = Self.service

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }

    func key(for id: String) -> Data? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query(id).merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result)
        return status == errSecSuccess ? result as? Data : nil
    }

    func save(_ key: Data, for id: String) throws {
        delete(id)
        let attributes = query(id).merging([kSecValueData as String: key,
                                            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete(_ id: String) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

final class MemoryKeyStore: DeviceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: Data] = [:]

    func key(for id: String) -> Data? { lock.withLock { keys[id] } }
    func save(_ key: Data, for id: String) throws { lock.withLock { keys[id] = key } }
    func delete(_ id: String) { lock.withLock { keys[id] = nil } }
}
