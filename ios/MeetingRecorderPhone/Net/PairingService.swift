import Foundation
import Network

enum PairingError: Error, Equatable {
    case network(PhoneNetworkError)
    case macTooNew
    case badKey
    case saveFailed(String)

    var message: String {
        switch self {
        case .network(.keyRejected): return "The Mac did not accept the code. Check it and try again."
        case .network(.unreachable), .network(.timeout):
            return "The pairing could not be reached. Check the address and the network, and make sure the pairing is still open on the Mac (it closes after five minutes)."
        case .network(.http(403, _)): return "This pairing has already been used or has expired. Open a new one on the Mac."
        case .network(let error): return error.message
        case .macTooNew: return "The Mac app is newer than this app understands. Update the iPhone app."
        case .badKey: return "The Mac sent a key this app cannot use."
        case .saveFailed(let reason): return "The key could not be saved: \(reason)"
        }
    }
}

enum PairingService {
    /// Trades the one-time pairing key for the device's own key and stores it in the Keychain.
    /// `keepAddress` remembers the typed address as the one to try first, for a Mac whose own name does not resolve here.
    static func pair(_ pairing: PhonePairing, deviceName: String, keys: DeviceKeyStore, keepAddress: Bool = false) async throws -> PairedMac {
        guard let target = MacLocator.hostPort(.init(host: pairing.host, port: pairing.port)) else { throw PairingError.network(.unreachable) }
        let client = PhoneHTTPClient(credential: PhoneCredential(id: pairing.id, key: pairing.key), identifiesDevice: false) { [target] }
        let result: PhonePairResult
        do {
            let request = try PhoneRequest.post("/v1/pair", json: PhonePairRequest(deviceName: String(deviceName.prefix(64))))
            result = try await client.json(request)
        } catch let error as PhoneNetworkError {
            throw PairingError.network(error)
        }
        guard result.apiVersion <= PhoneAPI.version else { throw PairingError.macTooNew }
        guard let key = Data(base64Encoded: result.key), key.count == 32 else { throw PairingError.badKey }
        do { try keys.save(key, for: result.deviceId) } catch { throw PairingError.saveFailed(error.localizedDescription) }
        return PairedMac(deviceId: result.deviceId, serverName: result.serverName, host: result.host, port: result.port,
                         override: keepAddress ? .init(host: pairing.host, port: result.port) : nil, pairedAt: Date())
    }
}
