import Foundation
import Testing
@testable import MeetingRecorderPhone

@Suite struct HTTPParserTests {
    private func run(_ chunks: [Data], close: Bool = false) throws -> (head: HTTPResponseHead?, body: Data, ended: Bool) {
        var parser = HTTPResponseParser()
        var head: HTTPResponseHead?
        var body = Data()
        var ended = false
        var events: [HTTPResponseEvent] = []
        for chunk in chunks { events += try parser.feed(chunk) }
        if close { events += try parser.connectionClosed() }
        for event in events {
            switch event {
            case .head(let value): head = value
            case .body(let data): body.append(data)
            case .end: ended = true
            }
        }
        return (head, body, ended)
    }

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    @Test func contentLengthInOnePiece() throws {
        let result = try run([bytes("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello")])
        #expect(result.head?.status == 200)
        #expect(result.head?.header("content-type") == "text/plain")
        #expect(result.body == bytes("hello"))
        #expect(result.ended)
    }

    @Test func contentLengthSplitAtEveryByte() throws {
        let text = "HTTP/1.1 206 Partial Content\r\nContent-Length: 4\r\nContent-Range: bytes 0-3/10\r\n\r\nabcd"
        let result = try run(text.utf8.map { Data([$0]) })
        #expect(result.head?.status == 206)
        #expect(result.head?.header("Content-Range") == "bytes 0-3/10")
        #expect(result.body == bytes("abcd"))
        #expect(result.ended)
    }

    @Test func chunkedBodyAcrossArbitrarySplits() throws {
        let text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nX-Trailer: 1\r\n\r\n"
        for size in [1, 2, 3, 7, 1000] {
            let data = Data(text.utf8)
            let pieces = stride(from: 0, to: data.count, by: size).map { Data(data[$0..<min($0 + size, data.count)]) }
            let result = try run(pieces)
            #expect(result.body == bytes("hello world"), "size \(size)")
            #expect(result.ended, "size \(size)")
        }
    }

    @Test func bodyThatRunsToTheEndOfTheConnection() throws {
        let result = try run([bytes("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nabc"), bytes("def")], close: true)
        #expect(result.body == bytes("abcdef"))
        #expect(result.ended)
    }

    @Test func noBodyStatuses() throws {
        let result = try run([bytes("HTTP/1.1 204 No Content\r\n\r\n")])
        #expect(result.head?.status == 204)
        #expect(result.ended)
    }

    @Test func zeroLengthBodyEnds() throws {
        let result = try run([bytes("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")])
        #expect(result.ended)
        #expect(result.body.isEmpty)
    }

    @Test func skipsInformationalResponse() throws {
        let result = try run([bytes("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nx")])
        #expect(result.head?.status == 200)
        #expect(result.body == bytes("x"))
    }

    @Test func rejectsMalformedHeads() {
        #expect(throws: HTTPParseError.malformedHead) { try run([bytes("garbage\r\n\r\n")]) }
        #expect(throws: HTTPParseError.malformedHead) { try run([bytes("HTTP/1.1 200 OK\r\nno colon here\r\n\r\n")]) }
        #expect(throws: HTTPParseError.malformedHead) { try run([bytes("HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\n")]) }
        #expect(throws: HTTPParseError.headTooLarge) { try run([Data(repeating: 65, count: HTTPResponseParser.maxHeadBytes + 1)]) }
    }

    @Test func rejectsBadChunks() {
        #expect(throws: HTTPParseError.malformedChunk) { try run([bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n")]) }
        #expect(throws: HTTPParseError.malformedChunk) { try run([bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nabXX")]) }
    }

    @Test func truncatedBodyIsAnErrorOnClose() {
        #expect(throws: HTTPParseError.truncated) { try run([bytes("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc")], close: true) }
        #expect(throws: HTTPParseError.truncated) { try run([bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhe")], close: true) }
    }

    @Test func ndjsonLines() {
        var buffer = NDJSONLineBuffer()
        #expect(buffer.feed(bytes("{\"a\":1}\n{\"b\"")) == [bytes("{\"a\":1}")])
        #expect(buffer.feed(bytes(":2}\n\n")) == [bytes("{\"b\":2}")])
        #expect(buffer.feed(bytes("{\"c\":3}")).isEmpty)
        #expect(buffer.flush() == bytes("{\"c\":3}"))
        #expect(buffer.flush() == nil)
    }

    @Test func requestSerialization() {
        let request = PhoneRequest.get("/v1/meetings", [URLQueryItem(name: "query", value: "a b&c"), URLQueryItem(name: "limit", value: "5")])
        let text = String(decoding: request.serialized(host: "mac.local", deviceId: "6edabb92"), as: UTF8.self)
        #expect(text.hasPrefix("GET /v1/meetings?query=a%20b%26c&limit=5 HTTP/1.1\r\n"))
        #expect(text.contains("Host: mac.local\r\n"))
        #expect(text.contains("X-Device-Id: 6edabb92\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func postCarriesContentLength() throws {
        let request = try PhoneRequest.post("/v1/pair", json: PhonePairRequest(deviceName: "Phone"))
        let data = request.serialized(host: "h", deviceId: nil)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("Content-Length: 22\r\n"))
        #expect(!text.contains("X-Device-Id"))
        #expect(text.hasSuffix("{\"deviceName\":\"Phone\"}"))
    }
}
