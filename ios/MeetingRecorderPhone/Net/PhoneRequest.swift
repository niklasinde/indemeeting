import Foundation
import Network

struct PhoneRequest {
    var method = "GET"
    var path: String
    var query: [URLQueryItem] = []
    var headers: [String: String] = [:]
    var body: Data?

    static func get(_ path: String, _ query: [URLQueryItem] = []) -> PhoneRequest { PhoneRequest(path: path, query: query) }

    static func post(_ path: String, json: some Encodable) throws -> PhoneRequest {
        PhoneRequest(method: "POST", path: path, headers: ["Content-Type": "application/json"], body: try PhoneAPI.encoder.encode(json))
    }

    var target: String {
        var components = URLComponents()
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        return components.string ?? path
    }

    /// The bytes of the request line, headers and body. Every connection carries one request and is closed after it.
    func serialized(host: String, deviceId: String?) -> Data {
        var all = headers
        all["Host"] = host
        all["Connection"] = "close"
        all["Accept-Encoding"] = "identity"
        if let deviceId { all[PhoneAPI.deviceHeader] = deviceId }
        if let body { all["Content-Length"] = String(body.count) }
        let head = "\(method) \(target) HTTP/1.1\r\n" + all.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
        return Data(head.utf8) + (body ?? Data())
    }
}

struct PhoneResponse {
    let head: HTTPResponseHead
    let body: Data

    var status: Int { head.status }
    var isSuccess: Bool { (200..<300).contains(head.status) }

    func decoded<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        guard isSuccess else { throw PhoneNetworkError.http(status: status, error: try? PhoneAPI.decoder.decode(PhoneError.self, from: body)) }
        do { return try PhoneAPI.decoder.decode(T.self, from: body) } catch { throw PhoneNetworkError.badResponse }
    }
}

enum PhoneNetworkError: Error, Equatable {
    /// Nothing answered: the Mac is asleep, off the network or iPhone access is off.
    case unreachable
    case timeout
    /// The handshake refused the key: this device is no longer paired, or the pairing code was wrong.
    case keyRejected
    /// The Mac closed the door on this address after too many failures.
    case blocked
    case connectionLost
    case badResponse
    case http(status: Int, error: PhoneError?)
    case notPaired

    /// What an `NWError` of the connection means. The codes are in `docs/phone-api.md`.
    static func classify(_ error: NWError) -> PhoneNetworkError {
        switch error {
        case .tls(let status):
            switch status {
            case -9820, -9864, -9824, -9828, -9829: return .keyRejected
            case -9816: return .blocked
            default: return .connectionLost
            }
        case .posix(let code):
            switch code {
            case .ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN, .EHOSTDOWN, .EADDRNOTAVAIL, .ENOENT: return .unreachable
            case .ETIMEDOUT: return .timeout
            default: return .connectionLost
            }
        case .dns: return .unreachable
        default: return .connectionLost
        }
    }

    /// Worth trying the next address or once more.
    var isConnectionFailure: Bool {
        switch self {
        case .unreachable, .timeout, .connectionLost: return true
        default: return false
        }
    }

    var isRejection: Bool {
        if case .http(let status, _) = self { return status == 401 }
        return self == .keyRejected
    }

    var message: String {
        switch self {
        case .unreachable: return "Your Mac could not be reached. Check that it is awake, on the same network, and that iPhone access is on."
        case .timeout: return "Your Mac took too long to answer."
        case .keyRejected: return "This iPhone is no longer paired with the Mac."
        case .blocked: return "The Mac is blocking this device for a couple of minutes after failed attempts. Try again shortly."
        case .connectionLost: return "The connection to your Mac was interrupted."
        case .badResponse: return "The Mac sent something this app does not understand. Update the app or the Mac app."
        case .http(_, let error?): return error.message
        case .http(let status, nil): return "The Mac answered with an error (\(status))."
        case .notPaired: return "Pair with a Mac first."
        }
    }
}
