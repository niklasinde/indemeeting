import Foundation

struct HTTPResponseHead: Equatable {
    let status: Int
    let reason: String
    /// Names in lower case.
    let headers: [String: String]

    func header(_ name: String) -> String? { headers[name.lowercased()] }
    var contentLength: Int? { header("content-length").flatMap { Int($0) } }
}

enum HTTPResponseEvent: Equatable {
    case head(HTTPResponseHead)
    case body(Data)
    case end
}

enum HTTPParseError: Error, Equatable {
    case malformedHead
    case malformedChunk
    case headTooLarge
    case truncated
}

/// An incremental HTTP/1.1 response parser: feed it what arrives and get the head and the decoded body pieces back.
/// Handles `Content-Length`, `Transfer-Encoding: chunked` and bodies that end when the connection closes.
struct HTTPResponseParser {
    static let maxHeadBytes = 64 * 1024
    private static let crlf = Data("\r\n".utf8)
    private static let blankLine = Data("\r\n\r\n".utf8)

    private enum State: Equatable {
        case head
        case fixed(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkTerminator
        case trailers
        case untilClose
        case done
    }

    private var state = State.head
    private var buffer = Data()

    var isComplete: Bool { state == .done }

    mutating func feed(_ data: Data) throws -> [HTTPResponseEvent] {
        buffer.append(data)
        var events: [HTTPResponseEvent] = []
        while try step(&events) {}
        return events
    }

    /// The connection closed: fine for a body that runs to the end, an error in the middle of anything else.
    mutating func connectionClosed() throws -> [HTTPResponseEvent] {
        switch state {
        case .done: return []
        case .untilClose:
            state = .done
            return [.end]
        default: throw HTTPParseError.truncated
        }
    }

    private mutating func step(_ events: inout [HTTPResponseEvent]) throws -> Bool {
        switch state {
        case .head:
            guard let end = buffer.range(of: Self.blankLine) else {
                if buffer.count > Self.maxHeadBytes { throw HTTPParseError.headTooLarge }
                return false
            }
            let head = try Self.parseHead(buffer[..<end.lowerBound])
            drop(end.upperBound)
            if (100..<200).contains(head.status) && head.status != 101 { return true }
            events.append(.head(head))
            if head.status == 204 || head.status == 304 || head.status == 101 {
                state = .done
                events.append(.end)
            } else if head.header("transfer-encoding")?.lowercased().contains("chunked") == true {
                state = .chunkSize
            } else if let length = head.header("content-length") {
                guard let value = Int(length), value >= 0 else { throw HTTPParseError.malformedHead }
                state = value == 0 ? .done : .fixed(remaining: value)
                if value == 0 { events.append(.end) }
            } else {
                state = .untilClose
            }
            return true
        case .fixed(let remaining):
            guard !buffer.isEmpty else { return false }
            let piece = take(min(remaining, buffer.count))
            events.append(.body(piece))
            if piece.count == remaining {
                state = .done
                events.append(.end)
            } else {
                state = .fixed(remaining: remaining - piece.count)
            }
            return true
        case .chunkSize:
            guard let line = buffer.range(of: Self.crlf) else {
                if buffer.count > 1024 { throw HTTPParseError.malformedChunk }
                return false
            }
            let text = String(decoding: buffer[..<line.lowerBound], as: UTF8.self)
            let sizeText = text.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { throw HTTPParseError.malformedChunk }
            drop(line.upperBound)
            state = size == 0 ? .trailers : .chunkData(remaining: size)
            return true
        case .chunkData(let remaining):
            guard !buffer.isEmpty else { return false }
            let piece = take(min(remaining, buffer.count))
            events.append(.body(piece))
            state = piece.count == remaining ? .chunkTerminator : .chunkData(remaining: remaining - piece.count)
            return true
        case .chunkTerminator:
            guard buffer.count >= 2 else { return false }
            guard take(2) == Self.crlf else { throw HTTPParseError.malformedChunk }
            state = .chunkSize
            return true
        case .trailers:
            guard let line = buffer.range(of: Self.crlf) else { return false }
            let isBlank = line.lowerBound == buffer.startIndex
            drop(line.upperBound)
            if isBlank {
                state = .done
                events.append(.end)
            }
            return true
        case .untilClose:
            guard !buffer.isEmpty else { return false }
            events.append(.body(take(buffer.count)))
            return true
        case .done:
            buffer.removeAll()
            return false
        }
    }

    private mutating func take(_ count: Int) -> Data {
        let piece = Data(buffer.prefix(count))
        drop(buffer.startIndex + count)
        return piece
    }

    private mutating func drop(_ index: Int) {
        buffer = index >= buffer.endIndex ? Data() : Data(buffer[index...])
    }

    private static func parseHead(_ data: Data) throws -> HTTPResponseHead {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw HTTPParseError.malformedHead }
        var lines = text.components(separatedBy: "\r\n")
        let status = lines.removeFirst().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard status.count >= 2, status[0].hasPrefix("HTTP/1."), let code = Int(status[1]), (100...599).contains(code) else {
            throw HTTPParseError.malformedHead
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw HTTPParseError.malformedHead }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        return HTTPResponseHead(status: code, reason: status.count > 2 ? String(status[2]) : "", headers: headers)
    }
}

/// Splits a stream of newline-delimited JSON into lines as the bytes arrive.
struct NDJSONLineBuffer {
    private var buffer = Data()

    mutating func feed(_ data: Data) -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer = Data(buffer[(newline + 1)...])
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    /// What is left when the stream ends without a final newline.
    mutating func flush() -> Data? {
        defer { buffer = Data() }
        return buffer.isEmpty ? nil : buffer
    }
}
