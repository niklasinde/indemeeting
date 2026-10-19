import Foundation
import Security

/// The device keys in the macOS Keychain, one generic password per device.
struct KeychainSecretStore: PhoneSecretStore {
    static let service = "com.niklasinde.MeetingRecorder.pairing"

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
        let status = SecItemAdd(query(id).merging([kSecValueData as String: key,
                                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 } as CFDictionary, nil)
        guard status == errSecSuccess else { throw SQLiteError(message: "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")") }
    }

    func delete(_ id: String) {
        SecItemDelete(query(id) as CFDictionary)
    }
}

/// The device keys in a file in the data folder, for `--serve` against a copy of the data so the real Keychain is left alone.
final class FileSecretStore: PhoneSecretStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(folder: URL) { url = folder.appendingPathComponent("phone-secrets.json") }

    private func load() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    private func store(_ values: [String: String]) throws {
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func key(for id: String) -> Data? { lock.withLock { load()[id].flatMap { Data(base64Encoded: $0) } } }

    func save(_ key: Data, for id: String) throws {
        try lock.withLock {
            var values = load()
            values[id] = key.base64EncodedString()
            try store(values)
        }
    }

    func delete(_ id: String) {
        lock.withLock {
            var values = load()
            values[id] = nil
            try? store(values)
        }
    }
}
