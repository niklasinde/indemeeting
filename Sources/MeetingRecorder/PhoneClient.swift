#if DEBUG
import CryptoKit
import Foundation
import Network

/// Debug builds only: `--phone-client <host:port> <pairing-url> <path> [--method M] [--body JSON|@file] [--header "K: V"]
/// [--device-name N] [--out FILE]` does the handshake the iPhone does and prints the response. `/v1/pair` completes a
/// pairing and prints the device's own url, which works in place of the pairing url afterwards.
enum PhoneClient {
    static func isRequested(_ arguments: [String]) -> Bool { arguments.contains("--phone-client") }

    static func run(_ arguments: [String]) -> Never {
        guard let index = arguments.firstIndex(of: "--phone-client"), index + 3 < arguments.count else {
            PhoneCommandLine.fail("usage: --phone-client <host:port> <pairing-url> <path> [--method M] [--body JSON|@file] [--header \"K: V\"] [--out FILE]")
        }
        let address = arguments[index + 1].split(separator: ":")
        guard address.count == 2, let port = NWEndpoint.Port(String(address[1])), let url = URL(string: arguments[index + 2]),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "id" })?.value, let key = items.first(where: { $0.name == "key" })?.value.flatMap(Base64.decode) else {
            PhoneCommandLine.fail("bad host:port or pairing url")
        }
        let path = arguments[index + 3]
        var method = PhoneCommandLine.value("--method", in: arguments) ?? "GET"
        var body = Data()
        if let text = PhoneCommandLine.value("--body", in: arguments) {
            body = text.hasPrefix("@") ? (try? Data(contentsOf: URL(fileURLWithPath: String(text.dropFirst())))) ?? Data() : Data(text.utf8)
            if PhoneCommandLine.value("--method", in: arguments) == nil { method = "POST" }
        } else if path == "/v1/pair" {
            method = "POST"
            body = Data(#"{"deviceName":"\#(PhoneCommandLine.value("--device-name", in: arguments) ?? "dev-client")"}"#.utf8)
        }
        var headers = [PhoneAPI.deviceHeader: id]
        for (position, argument) in arguments.enumerated() where argument == "--header" && position + 1 < arguments.count {
            let parts = arguments[position + 1].split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { headers[parts[0]] = parts[1] }
        }
        let output = PhoneCommandLine.value("--out", in: arguments)
        let target = NWEndpoint.hostPort(host: NWEndpoint.Host(String(address[0])), port: port)
        Task {
            do {
                let connection = NWConnection(to: target, using: PhoneTransport.parameters([PhoneCredential(id: id, key: key)]))
                try await connect(connection)
                var request = "\(method) \(path) HTTP/1.1\r\nHost: \(address[0])\r\n"
                for (name, value) in headers.sorted(by: { $0.key < $1.key }) { request += "\(name): \(value)\r\n" }
                if !body.isEmpty { request += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
                request += "Connection: close\r\n\r\n"
                try await send(connection, Data(request.utf8) + body)
                let response = try await read(connection, output: output.map { URL(fileURLWithPath: $0) }, started: Date())
                if path == "/v1/pair", response.status == 200, let result = try? PhoneAPI.decoder.decode(PhonePairResult.self, from: response.body) {
                    print("device-url: meetingrecorder://pair?host=\(result.host)&port=\(result.port)&id=\(result.deviceId)&key=\(Base64.urlEncode(Data(base64Encoded: result.key) ?? Data()))")
                }
                exit(0)
            } catch {
                print("connection failed: \((error as NSError).code) \(error.localizedDescription)")
                exit(2)
            }
        }
        dispatchMain()
    }

    private static func connect(_ connection: NWConnection) async throws {
        nonisolated(unsafe) var finished = false
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready: finished = true; continuation.resume()
                case .failed(let error), .waiting(let error): finished = true; continuation.resume(throwing: error)
                default: break
                }
            }
            connection.start(queue: .global())
        }
    }

    private static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static func receive(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) } else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: nil) } else { continuation.resume(returning: Data()) }
            }
        }
    }

    /// Prints the status line and headers, then the body: text as it arrives, with the time of each chunk of a stream;
    /// audio and other binary bodies as a size and a hash.
    private static func read(_ connection: NWConnection, output: URL?, started: Date) async throws -> (status: Int, body: Data) {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard let more = try await receive(connection) else { throw PhoneConnectionClosed() }
            buffer += more
        }
        let end = buffer.range(of: separator)!
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        print(head)
        print()
        var body = Data(buffer[end.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        let status = Int(lines[0].split(separator: " ").dropFirst().first ?? "") ?? 0
        let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (line[..<colon].lowercased(), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }) { $1 }
        let chunked = headers["transfer-encoding"] == "chunked"
        let textual = (headers["content-type"] ?? "").hasPrefix("application/")
        var decoded = Data()
        if chunked {
            var pending = body
            while true {
                while let line = pending.range(of: Data("\r\n".utf8)), let size = Int(String(decoding: pending[..<line.lowerBound], as: UTF8.self), radix: 16),
                      pending.count >= line.upperBound + size + 2 {
                    if size == 0 { return (status, decoded) }
                    let chunk = Data(pending[line.upperBound..<line.upperBound + size])
                    decoded += chunk
                    print(String(format: "[+%.2fs] ", Date().timeIntervalSince(started)) + String(decoding: chunk, as: UTF8.self), terminator: "")
                    pending.removeSubrange(..<(line.upperBound + size + 2))
                }
                guard let more = try await receive(connection) else { return (status, decoded) }
                pending += more
            }
        }
        let expected = headers["content-length"].flatMap(Int.init)
        while expected.map({ body.count < $0 }) ?? true {
            guard let more = try await receive(connection) else { break }
            body += more
        }
        if let output {
            try body.write(to: output)
            print("saved \(body.count) bytes to \(output.path)")
        } else if textual {
            print(String(decoding: body, as: UTF8.self))
        }
        print("body: \(body.count) bytes, sha256 \(SHA256.hash(data: body).prefix(6).map { String(format: "%02x", $0) }.joined())")
        return (status, body)
    }
}
#endif
