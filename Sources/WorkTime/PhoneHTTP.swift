import Foundation

struct HTTPRequest: Equatable {
    let method: String
    let path: String
    let query: [String: String]
    /// Names in lower case.
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

enum HTTPParseResult: Equatable {
    case incomplete
    case request(HTTPRequest, consumed: Int)
    case failure(Int)
}

enum PhoneHTTP {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 256 * 1024
    static let maxHeaders = 100
    static let maxTargetLength = 2048

    /// Parses the first request in `buffer`. Anything unusual is refused rather than guessed at.
    static func parse(_ buffer: Data) -> HTTPParseResult {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: terminator) else {
            return buffer.count > maxHeaderBytes ? .failure(431) : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes else { return .failure(431) }
        guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return .failure(400) }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, !requestLine[0].isEmpty, requestLine[0].allSatisfy({ $0.isASCII && $0.isUppercase }) else {
            return .failure(400)
        }
        guard requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else { return .failure(505) }
        let target = String(requestLine[1])
        guard target.count <= maxTargetLength else { return .failure(414) }
        guard target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 32 } ?? false }),
              let components = URLComponents(string: target), components.fragment == nil else { return .failure(400) }
        guard lines.count <= maxHeaders else { return .failure(431) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex, !line.first!.isWhitespace else { return .failure(400) }
            let name = line[..<colon].lowercased()
            guard !name.contains(where: { $0.isWhitespace }) else { return .failure(400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let existing = headers[name] {
                guard name != "content-length" || existing == value else { return .failure(400) }
                headers[name] = name == "content-length" ? value : existing + ", " + value
            } else {
                headers[name] = value
            }
        }
        guard headers["transfer-encoding"] == nil else { return .failure(501) }

        var length = 0
        if let text = headers["content-length"] {
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text) else { return .failure(400) }
            guard value <= maxBodyBytes else { return .failure(413) }
            length = value
        }
        let bodyStart = end.upperBound
        guard buffer.count - bodyStart >= length else { return .incomplete }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let request = HTTPRequest(method: String(requestLine[0]), path: components.path, query: query, headers: headers,
                                  body: Data(buffer[bodyStart..<bodyStart + length]))
        return .request(request, consumed: bodyStart + length)
    }

    enum RangeResult: Equatable {
        case whole
        case partial(ClosedRange<Int64>)
        case unsatisfiable
    }

    /// The bytes a `Range` header asks for. A header that is not a single `bytes` range is ignored, as the standard allows.
    static func range(_ header: String?, size: Int64) -> RangeResult {
        guard let header, header.hasPrefix("bytes=") else { return .whole }
        let spec = header.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !spec.contains(","), parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return .whole }
        switch (Int64(parts[0]), Int64(parts[1])) {
        case let (first?, last?):
            guard first <= last else { return .whole }
            return first < size ? .partial(first...min(last, size - 1)) : .unsatisfiable
        case let (first?, nil):
            guard parts[1].isEmpty else { return .whole }
            return first < size ? .partial(first...(size - 1)) : .unsatisfiable
        case let (nil, suffix?):
            guard parts[0].isEmpty, suffix > 0 else { return suffix == 0 ? .unsatisfiable : .whole }
            return size > 0 ? .partial(max(size - suffix, 0)...(size - 1)) : .unsatisfiable
        default:
            return .whole
        }
    }

    static func reason(_ status: Int) -> String {
        [200: "OK", 206: "Partial Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
         405: "Method Not Allowed", 409: "Conflict", 410: "Gone", 413: "Content Too Large", 414: "URI Too Long",
         416: "Range Not Satisfiable", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
         500: "Internal Server Error", 501: "Not Implemented", 503: "Service Unavailable",
         505: "HTTP Version Not Supported"][status] ?? "Status"
    }

    static func head(status: Int, headers: [String: String]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        return Data((text + "\r\n").utf8)
    }

    static func chunk(_ data: Data) -> Data {
        Data(String(data.count, radix: 16).utf8) + Data("\r\n".utf8) + data + Data("\r\n".utf8)
    }

    static let lastChunk = Data("0\r\n\r\n".utf8)

    static func contentType(forAudio file: String) -> String {
        switch (file as NSString).pathExtension.lowercased() {
        case "m4a": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "aac": return "audio/aac"
        default: return "application/octet-stream"
        }
    }
}
