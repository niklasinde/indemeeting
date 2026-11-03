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

/// The secrets in a file only the user can read, moved there from the Keychain on first read. The app is signed without a
/// Team ID, so the Keychain ties each item to one build and asks for the login password again after every update.
struct AppSecretStore: PhoneSecretStore {
    let file: FileSecretStore
    let keychain: KeychainSecretStore

    init(service: String = KeychainSecretStore.service, folder: URL = AppPaths.secrets) {
        file = FileSecretStore(folder: folder, name: service)
        keychain = KeychainSecretStore(service: service)
    }

    func key(for id: String) -> Data? {
        if let key = file.key(for: id) { return key }
        guard let key = keychain.key(for: id), (try? file.save(key, for: id)) != nil else { return nil }
        keychain.delete(id)
        return key
    }

    func save(_ key: Data, for id: String) throws { try file.save(key, for: id) }

    func delete(_ id: String) {
        file.delete(id)
        keychain.delete(id)
    }
}

/// The secrets in a file, also for `--serve` against a copy of the data so the real ones are left alone.
final class FileSecretStore: PhoneSecretStore, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    init(folder: URL, name: String = "phone-secrets") { url = folder.appendingPathComponent("\(name).json") }

    private func load() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    private func store(_ values: [String: String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
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
