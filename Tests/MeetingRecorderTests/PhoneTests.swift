import Foundation
#if canImport(MeetingRecorder)
@testable import MeetingRecorder
#endif

private func request(_ text: String) -> HTTPParseResult { PhoneHTTP.parse(Data(text.utf8)) }

private func parsed(_ text: String) -> HTTPRequest? {
    if case .request(let request, _) = PhoneHTTP.parse(Data(text.utf8)) { return request }
    return nil
}

private func tempFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("phone-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// Runs an async body to completion from a synchronous test.
private func await_<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    Task.detached {
        result = await body()
        semaphore.signal()
    }
    semaphore.wait()
    return result!
}

private struct Scratch {
    let folder: URL
    let store: MeetingStore
    let recordings: URL
    var githubEnabled = true

    var endpoints: PhoneEndpoints {
        var endpoints = PhoneEndpoints(store: store, audioFolder: recordings, appVersion: "9.9", serverName: "test.local",
                                       now: { Date(timeIntervalSince1970: 1_792_300_000) })
        let enabled = githubEnabled
        endpoints.features = { PhoneFeatures(githubEnabled: enabled, activityEnabled: true, chatAvailable: false) }
        return endpoints
    }

    func get(_ target: String, method: String = "GET", body: Data = Data(), headers: [String: String] = [:]) -> PhoneResponse {
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        var query: [String: String] = [:]
        for item in URLComponents(string: "x://x?" + (parts.count > 1 ? parts[1] : ""))?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let request = HTTPRequest(method: method, path: parts[0], query: query, headers: headers, body: body)
        let endpoints = self.endpoints
        guard case .response(let response) = await_({ await endpoints.handle(request) }) else { return PhoneResponse.error(0, "chat", "") }
        return response
    }

    func decode<T: Decodable>(_ type: T.Type, _ response: PhoneResponse) -> T? {
        guard case .data(let data) = response.body else { return nil }
        return try? PhoneAPI.decoder.decode(type, from: data)
    }
}

private func withScratch(_ body: (Scratch) throws -> Void) throws {
    let folder = try tempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let recordings = folder.appendingPathComponent("recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    try body(Scratch(folder: folder, store: try MeetingStore.open(at: folder.appendingPathComponent("db/meetings.sqlite")), recordings: recordings))
}

private let t0 = Date(timeIntervalSince1970: 1_792_300_000)

private func activityBlock(_ id: Int64, _ offset: TimeInterval, app: String = "Xcode", title: String? = nil, redaction: ActivityRedaction? = nil,
                           idle: Bool = false, prompt: String? = nil) -> ActivityBlock {
    ActivityBlock(id: id, start: t0.addingTimeInterval(offset), end: t0.addingTimeInterval(offset + 60),
                  key: ActivityKey(appBundle: "com.\(app)", appName: app, windowTitle: title, url: nil, repo: "api", branch: "QDLY-1-fix",
                                   ticket: nil, claude: [], idle: idle, redaction: redaction),
                  category: .coding, aiDescription: "Fixing a bug", claudePrompt: prompt)
}

private func segment(_ start: TimeInterval, _ text: String, _ speaker: Speaker? = nil) -> TranscriptSegment {
    TranscriptSegment(start: start, text: text, speaker: speaker)
}

let phoneTests: [(name: String, run: () throws -> Void)] = [
    // MARK: HTTP parsing

    ("a GET request is parsed into method, path, query and lower-cased headers", {
        let request = parsed("GET /v1/meetings?query=a%20b&limit=5 HTTP/1.1\r\nHost: mac\r\nX-Device-Id: ab12cd34\r\n\r\n")
        check(request?.method == "GET" && request?.path == "/v1/meetings", "line")
        check(request?.query == ["query": "a b", "limit": "5"], "query decoded")
        check(request?.header("x-device-id") == "ab12cd34" && request?.header("HOST") == "mac", "headers")
        check(request?.body.isEmpty == true, "no body")
    }),

    ("a POST waits for its whole body and leaves the next pipelined request alone", {
        let head = "POST /v1/chat HTTP/1.1\r\nContent-Length: 5\r\n\r\n"
        check(request(head + "abc") == .incomplete, "body incomplete")
        check(request("POST /v1/chat HTTP/1.1\r\nContent-Le") == .incomplete, "headers incomplete")
        let two = head + "hello" + "GET /v1/status HTTP/1.1\r\n\r\n"
        guard case .request(let first, let consumed) = request(two) else { return check(false, "first parsed") }
        check(first.body == Data("hello".utf8) && consumed == head.utf8.count + 5, "first request and its size")
        check(parsed(String(decoding: Data(two.utf8).dropFirst(consumed), as: UTF8.self))?.path == "/v1/status", "the rest is the next request")
    }),

    ("malformed requests are refused with a status instead of guessed at", {
        check(request("GARBAGE\r\n\r\n") == .failure(400), "request line")
        check(request("get /v1/status HTTP/1.1\r\n\r\n") == .failure(400), "lower-case method")
        check(request("GET /v1/status HTTP/2\r\n\r\n") == .failure(505), "version")
        check(request("GET v1/status HTTP/1.1\r\n\r\n") == .failure(400), "target without a slash")
        check(request("GET //evil.example/x HTTP/1.1\r\n\r\n") == .failure(400), "scheme-relative target")
        check(request("GET /a b HTTP/1.1\r\n\r\n") == .failure(400), "space in target")
        check(request("GET /v1/status HTTP/1.1\r\nBroken header\r\n\r\n") == .failure(400), "header without colon")
        check(request("GET /v1/status HTTP/1.1\r\n folded: x\r\n\r\n") == .failure(400), "folded header")
        check(request("GET /v1/status HTTP/1.1\r\nBad Name: x\r\n\r\n") == .failure(400), "space in header name")
        check(request("POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n") == .failure(400), "content length not a number")
        check(request("POST /x HTTP/1.1\r\nContent-Length: -1\r\n\r\n") == .failure(400), "negative content length")
        check(request("POST /x HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab") == .failure(400), "conflicting lengths")
        check(request("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") == .failure(501), "chunked request body")
        check(request("GET /v1/status HTTP/1.1\r\nX: \u{00FF}\u{0080}\r\n\r\n") != .incomplete, "non-ascii header does not hang")
    }),

    ("oversized requests are refused before they are read", {
        check(request("GET /\(String(repeating: "a", count: 3000)) HTTP/1.1\r\n\r\n") == .failure(414), "long target")
        check(request("GET /x HTTP/1.1\r\nX: \(String(repeating: "a", count: PhoneHTTP.maxHeaderBytes))\r\n\r\n") == .failure(431), "long headers")
        check(PhoneHTTP.parse(Data(repeating: 65, count: PhoneHTTP.maxHeaderBytes + 1)) == .failure(431), "headers that never end")
        let many = (0..<(PhoneHTTP.maxHeaders + 1)).map { "H\($0): x" }.joined(separator: "\r\n")
        check(request("GET /x HTTP/1.1\r\n\(many)\r\n\r\n") == .failure(431), "too many headers")
        check(request("POST /x HTTP/1.1\r\nContent-Length: \(PhoneHTTP.maxBodyBytes + 1)\r\n\r\n") == .failure(413), "large body")
    }),

    // MARK: Range

    ("a Range header gives the bytes asked for, clipped to the file", {
        check(PhoneHTTP.range(nil, size: 1000) == .whole, "no header")
        check(PhoneHTTP.range("bytes=0-99", size: 1000) == .partial(0...99), "first bytes")
        check(PhoneHTTP.range("bytes=900-", size: 1000) == .partial(900...999), "open ended")
        check(PhoneHTTP.range("bytes=-100", size: 1000) == .partial(900...999), "suffix")
        check(PhoneHTTP.range("bytes=-5000", size: 1000) == .partial(0...999), "suffix longer than the file")
        check(PhoneHTTP.range("bytes=990-5000", size: 1000) == .partial(990...999), "end clipped")
        check(PhoneHTTP.range("bytes=0-0", size: 1000) == .partial(0...0), "one byte")
    }),

    ("a Range outside the file is unsatisfiable and one that makes no sense is ignored", {
        check(PhoneHTTP.range("bytes=1000-", size: 1000) == .unsatisfiable, "start at the end")
        check(PhoneHTTP.range("bytes=2000-3000", size: 1000) == .unsatisfiable, "beyond")
        check(PhoneHTTP.range("bytes=-0", size: 1000) == .unsatisfiable, "empty suffix")
        check(PhoneHTTP.range("bytes=0-5", size: 0) == .unsatisfiable, "empty file")
        check(PhoneHTTP.range("bytes=5-1", size: 1000) == .whole, "backwards")
        check(PhoneHTTP.range("bytes=0-1,5-6", size: 1000) == .whole, "several ranges")
        check(PhoneHTTP.range("items=0-1", size: 1000) == .whole, "other unit")
        check(PhoneHTTP.range("bytes=a-b", size: 1000) == .whole, "letters")
        check(PhoneHTTP.range("bytes=-", size: 1000) == .whole, "nothing")
    }),

    ("a chunk carries its size in hex and the stream ends with an empty one", {
        check(PhoneHTTP.chunk(Data("hello world!!!!!".utf8)) == Data("10\r\nhello world!!!!!\r\n".utf8), "chunk")
        check(PhoneHTTP.lastChunk == Data("0\r\n\r\n".utf8), "last chunk")
        let head = String(decoding: PhoneHTTP.head(status: 206, headers: ["B": "2", "A": "1"]), as: UTF8.self)
        check(head == "HTTP/1.1 206 Partial Content\r\nA: 1\r\nB: 2\r\n\r\n", "head")
        check(PhoneHTTP.contentType(forAudio: "x.m4a") == "audio/mp4" && PhoneHTTP.contentType(forAudio: "x.MP3") == "audio/mpeg", "audio types")
    }),

    // MARK: Pairing

    ("a pairing url carries host, port, id and key and survives a round trip", {
        let key = Data((0..<16).map { UInt8($0 * 16 + 1) })
        let pairing = PhonePairing(host: "Niklass-Mac.local", port: 47821, id: "0a1b2c3d", key: key)
        check(pairing.url.absoluteString.hasPrefix("meetingrecorder://pair?host=Niklass-Mac.local&port=47821&id=0a1b2c3d&key="), "shape \(pairing.url)")
        check(PhonePairing(url: pairing.url) == pairing, "round trip")
        check(PhonePairing(url: URL(string: "meetingrecorder://pair?host=h&port=1&id=0A1B2C3D&key=\(key.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)")!)?.key == key,
              "standard base64 is accepted and the id is lower-cased")
    }),

    ("a pairing url that is wrong in any part is rejected", {
        let key = Base64.urlEncode(Data(repeating: 7, count: 16))
        func make(_ query: String, scheme: String = "meetingrecorder", host: String = "pair") -> PhonePairing? {
            URL(string: "\(scheme)://\(host)?\(query)").flatMap(PhonePairing.init(url:))
        }
        check(make("host=h&port=1&id=0a1b2c3d&key=\(key)") != nil, "baseline")
        check(make("host=h&port=1&id=0a1b2c3d&key=\(key)", scheme: "https") == nil, "scheme")
        check(make("host=h&port=1&id=0a1b2c3d&key=\(key)", host: "other") == nil, "action")
        check(make("port=1&id=0a1b2c3d&key=\(key)") == nil, "no host")
        check(make("host=h&port=0&id=0a1b2c3d&key=\(key)") == nil, "port 0")
        check(make("host=h&port=70000&id=0a1b2c3d&key=\(key)") == nil, "port too large")
        check(make("host=h&port=x&id=0a1b2c3d&key=\(key)") == nil, "port not a number")
        check(make("host=h&port=1&id=0a1b2c&key=\(key)") == nil, "short id")
        check(make("host=h&port=1&id=zzzzzzzz&key=\(key)") == nil, "id not hex")
        check(make("host=h&port=1&id=0a1b2c3d&key=\(Base64.urlEncode(Data(repeating: 7, count: 15)))") == nil, "short key")
        check(make("host=h&port=1&id=0a1b2c3d") == nil, "no key")
    }),

    ("the typed code is the id and key in groups of four and works in lower case with spaces", {
        let pairing = PhonePairing(host: "h", port: 9, id: "0a1b2c3d", key: Data((0..<16).map { UInt8(255 - $0 * 7) }))
        let code = pairing.manualCode
        check(code.count == 39 && code.split(separator: "-").allSatisfy { $0.count == 4 } && code.split(separator: "-").count == 8, "eight groups of four: \(code)")
        check(PhonePairing(manualCode: code, host: "h", port: 9) == pairing, "decodes")
        check(PhonePairing(manualCode: code.lowercased().replacingOccurrences(of: "-", with: " "), host: "h", port: 9) == pairing, "tolerant")
        check(PhonePairing(manualCode: String(code.dropLast(2)), host: "h", port: 9) == nil, "short code")
        check(PhonePairing(manualCode: code + "AAAA", host: "h", port: 9) == nil, "long code")
        check(PhonePairing(manualCode: "0000-1111-" + code.dropFirst(10), host: "h", port: 9) == nil, "0 and 1 are not in the alphabet")
        for length in 0...40 {
            let bytes = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
            check(Base32.decode(Base32.encode(bytes)) == bytes, "base32 round trip \(length)")
            check(Base64.decode(Base64.urlEncode(bytes)) == bytes, "base64 round trip \(length)")
        }
    }),

    ("a pairing is valid for five minutes and for one use", {
        var pairings = PhonePairings()
        let now = Date(timeIntervalSince1970: 1000)
        let pairing = pairings.begin(now: now)
        check(pairing.expires == now.addingTimeInterval(300) && pairing.key.count == 16 && PhonePairing.isValid(id: pairing.id), "lifetime and shape")
        check(pairings.consume(now: now.addingTimeInterval(299)) == .success(pairing), "valid inside the time")
        check(pairings.consume(now: now.addingTimeInterval(299)) == .failure(.unknown), "spent after one use")
        check(pairings.pending == nil, "nothing open")

        _ = pairings.begin(now: now)
        check(pairings.consume(now: now.addingTimeInterval(300)) == .failure(.expired), "expired at five minutes")
        check(pairings.consume(now: now) == .failure(.unknown), "an expired pairing is gone")

        _ = pairings.begin(now: now)
        check(pairings.expire(now: now.addingTimeInterval(10)) == false && pairings.pending != nil, "not yet expired")
        check(pairings.expire(now: now.addingTimeInterval(301)) && pairings.pending == nil, "expire drops it")

        let first = pairings.begin(now: now)
        let second = pairings.begin(now: now)
        check(first.id != second.id && first.key != second.key && pairings.pending == second, "a new pairing replaces the open one")
        pairings.cancel()
        check(pairings.consume(now: now) == .failure(.unknown), "cancelled")
    }),

    ("keys and ids are random and the right size", {
        check(PhoneSecrets.newKey().count == 32 && PhoneSecrets.newKey(16).count == 16, "sizes")
        check(Set((0..<50).map { _ in PhoneSecrets.newKey() }).count == 50, "keys differ")
        check(Set((0..<50).map { _ in PhoneSecrets.newID() }).count > 45, "ids differ")
        check((0..<20).allSatisfy { _ in PhonePairing.isValid(id: PhoneSecrets.newID()) }, "ids are valid")
    }),

    // MARK: Auth

    ("a request is allowed only for a device that is still paired", {
        let paired: Set<String> = ["0a1b2c3d", "ffffffff"]
        check(PhoneAuth.decide(claimed: "0a1b2c3d", paired: paired) == .allowed(deviceID: "0a1b2c3d"), "paired")
        check(PhoneAuth.decide(claimed: "0A1B2C3D", paired: paired) == .allowed(deviceID: "0a1b2c3d"), "case does not matter")
        check(PhoneAuth.decide(claimed: "11111111", paired: paired) == .denied(.unknownDevice), "unknown")
        check(PhoneAuth.decide(claimed: nil, paired: paired) == .denied(.missingDevice), "missing")
        check(PhoneAuth.decide(claimed: "", paired: paired) == .denied(.missingDevice), "empty")
        check(PhoneAuth.decide(claimed: "0a1b2c3d", paired: []) == .denied(.unknownDevice), "after the last device is revoked")
    }),

    ("a peer that fails too often is blocked for a while and others are not", {
        var limiter = FailureLimiter(maxFailures: 3, window: 10, lockout: 60)
        let now = Date(timeIntervalSince1970: 1000)
        limiter.record("a", now: now)
        limiter.record("a", now: now.addingTimeInterval(1))
        check(!limiter.isBlocked("a", now: now.addingTimeInterval(2)), "two failures are fine")
        limiter.record("a", now: now.addingTimeInterval(2))
        check(limiter.isBlocked("a", now: now.addingTimeInterval(3)), "three block")
        check(!limiter.isBlocked("b", now: now.addingTimeInterval(3)), "another peer is not blocked")
        check(limiter.isBlocked("a", now: now.addingTimeInterval(61)), "still blocked inside the lockout")
        check(!limiter.isBlocked("a", now: now.addingTimeInterval(63)), "released after the lockout")
        limiter.record("c", now: now)
        limiter.record("c", now: now.addingTimeInterval(5))
        limiter.record("c", now: now.addingTimeInterval(12))
        check(!limiter.isBlocked("c", now: now.addingTimeInterval(13)), "old failures fall out of the window")
    }),

    ("paired devices are stored, touched and deleted, and the secret stores keep keys apart", {
        try withScratch { scratch in
            let store = scratch.store
            try store.addPairedDevice(PairedDevice(id: "0a1b2c3d", name: "iPhone", created: t0))
            try store.addPairedDevice(PairedDevice(id: "ffffffff", name: "iPad", created: t0.addingTimeInterval(5)))
            check(try store.pairedDevices().map(\.name) == ["iPhone", "iPad"] && (try store.pairedDevices()[0].lastSeen) == nil, "listed in order")
            try store.touchPairedDevice("0a1b2c3d", at: t0.addingTimeInterval(100))
            check(try store.pairedDevices()[0].lastSeen == t0.addingTimeInterval(100), "last seen")
            try store.deletePairedDevice("0a1b2c3d")
            check(try store.pairedDevices().map(\.id) == ["ffffffff"], "deleted")

            let memory = MemorySecretStore()
            let file = FileSecretStore(folder: scratch.folder)
            let keychain = KeychainSecretStore(service: "com.niklasinde.MeetingRecorder.tests.\(UUID().uuidString)")
            for secrets in [memory, file, keychain] as [PhoneSecretStore] {
                let one = PhoneSecrets.newKey(), two = PhoneSecrets.newKey()
                try secrets.save(one, for: "a")
                try secrets.save(two, for: "b")
                check(secrets.key(for: "a") == one && secrets.key(for: "b") == two, "\(type(of: secrets)) keeps keys apart")
                try secrets.save(two, for: "a")
                check(secrets.key(for: "a") == two, "\(type(of: secrets)) replaces")
                secrets.delete("a")
                check(secrets.key(for: "a") == nil && secrets.key(for: "b") == two, "\(type(of: secrets)) deletes one")
                secrets.delete("b")
                check(secrets.key(for: "b") == nil, "\(type(of: secrets)) deletes the other")
            }
            let permissions = (try? FileManager.default.attributesOfItem(atPath: scratch.folder.appendingPathComponent("phone-secrets.json").path)[.posixPermissions] as? Int) ?? 0
            check(permissions == 0o600, "the key file is private to the user")
        }
    }),

    // MARK: DTOs

    ("the data transfer types survive a round trip and leave out what is missing", {
        let detail = PhoneMeetingDetail(id: 3, title: "T", date: t0, duration: 61.5, languages: ["sv"], languageDetected: true,
                                        engines: PhoneEngines(transcript: "WhisperKit", summary: nil), summaryTitle: nil, summaryUnavailable: "Off",
                                        topics: [PhoneSummaryTopic(title: "A", points: ["x"])], actionItems: [PhoneActionItem(id: 1, owner: nil, text: "do", done: true)],
                                        notes: "n", transcript: [PhoneSegment(start: 1, end: 2, speaker: "you", speakerName: "Du", text: "hej")],
                                        audio: PhoneAudioInfo(available: true, duration: 61.5, bytes: 100, contentType: "audio/mp4"))
        let data = try PhoneAPI.encoder.encode(detail)
        check(try PhoneAPI.decoder.decode(PhoneMeetingDetail.self, from: data) == detail, "detail")
        check(!String(decoding: data, as: UTF8.self).contains("summaryTitle") && String(decoding: data, as: UTF8.self).contains("\"date\":\"2026-10-18T"), "nil omitted, dates are ISO 8601")

        let activity = PhoneActivity(from: t0, to: t0.addingTimeInterval(86400),
                                     totals: PhoneActivityTotals(activeSeconds: 5, projects: [PhoneTotal(name: "P", seconds: 5)], categories: [], apps: [],
                                                                 branches: [PhoneWorkTotal(name: "b", repo: "r", ticket: nil, project: nil, projectGuessed: false, seconds: 1)],
                                                                 tickets: [PhoneTicketTotal(ticket: "A-1", title: "t", url: "u", branches: ["b"], project: "P", projectGuessed: true, seconds: 1)]),
                                     days: [PhoneDayTotal(date: "2026-10-17", activeSeconds: 5)],
                                     blocks: [PhoneBlock(id: 1, start: t0, end: t0, app: "Xcode", projectGuessed: false)])
        check(try PhoneAPI.decoder.decode(PhoneActivity.self, from: PhoneAPI.encoder.encode(activity)) == activity, "activity")

        let github = PhoneGitHub(enabled: true, refreshedAt: t0, prs: ["created": [PhonePR(url: "u", number: 1, title: "t", repo: "r", isDraft: false, state: "open", updated: t0,
                                                                                          review: "approved", checks: "passed", author: nil, additions: 1, deletions: 2, comments: 3, labels: ["x"], ticket: nil)]],
                                 error: nil)
        check(try PhoneAPI.decoder.decode(PhoneGitHub.self, from: PhoneAPI.encoder.encode(github)) == github, "github")

        let chat = PhoneChatRequest(scope: PhoneChatScope(kind: "day", date: "2026-10-17"), messages: [PhoneChatMessage(role: "user", text: "hi")])
        check(try PhoneAPI.decoder.decode(PhoneChatRequest.self, from: PhoneAPI.encoder.encode(chat)) == chat, "chat request")
        for event in [PhoneChatEvent.token("a"), .tool("n"), .citations([PhoneCitation(meetingId: 1, title: "t", seconds: 3)]), .done("all"), .failed("no")] {
            check(try PhoneAPI.decoder.decode(PhoneChatEvent.self, from: PhoneAPI.encoder.encode(event)) == event, "event \(event.type)")
        }
        let result = PhonePairResult(deviceId: "0a1b2c3d", key: "a2V5", serverName: "Mac", host: "m.local", port: 1, apiVersion: 1)
        check(try PhoneAPI.decoder.decode(PhonePairResult.self, from: PhoneAPI.encoder.encode(result)) == result, "pair result")
    }),

    ("chat text is sent as the part added each time and citations are the meetings the lookups named", {
        check(PhoneChatLogic.delta(from: "", to: "Hej") == "Hej" && PhoneChatLogic.delta(from: "Hej", to: "Hej då") == " då", "continues")
        check(PhoneChatLogic.delta(from: "Hej då", to: "Nej") == "Nej", "a rewritten answer is sent whole")
        let notes = ["Searched meetings\n- id 7 \u{00B7} 2026-10-16 \u{00B7} Standup", "Read one\n- id 7 \u{00B7} x\n- id 9 \u{00B7} y", "Nothing\nplain line", "Looked\n- id 99 \u{00B7} gone"]
        let titles: [Int64: String] = [7: "Standup", 9: "Planning"]
        check(PhoneChatLogic.citations(notes: notes) { titles[$0] } == [PhoneCitation(meetingId: 7, title: "Standup"), PhoneCitation(meetingId: 9, title: "Planning")],
              "once each, in order, without meetings that are gone")
        let gate = PhoneChatGate()
        check(gate.acquire() && !gate.acquire(), "one at a time")
        gate.release()
        check(gate.acquire(), "free again")
    }),

    // MARK: Endpoints

    ("status reports the version, schema, time and features", {
        try withScratch { scratch in
            let response = scratch.get("/v1/status")
            let status = scratch.decode(PhoneStatus.self, response)
            check(response.status == 200 && response.contentType == "application/json", "ok")
            check(status?.appVersion == "9.9" && status?.apiVersion == PhoneAPI.version && status?.serverName == "test.local", "identity")
            check(status?.schemaVersion == MeetingStore.migrations.count && status?.serverTime == Date(timeIntervalSince1970: 1_792_300_000), "schema and time")
            check(status?.features == PhoneFeatures(githubEnabled: true, activityEnabled: true, chatAvailable: false), "features")
        }
    }),

    ("unknown paths are 404 and the wrong method on a known path is 405", {
        try withScratch { scratch in
            check(scratch.get("/").status == 404 && scratch.get("/v2/status").status == 404 && scratch.get("/v1/nothing").status == 404, "unknown")
            check(scratch.get("/v1/meetings/1/other").status == 404, "unknown under meetings")
            let wrong = scratch.get("/v1/status", method: "POST")
            check(wrong.status == 405 && wrong.headers["Allow"] == "GET", "post to status")
            check(scratch.get("/v1/meetings/1", method: "DELETE").status == 405 && scratch.get("/v1/github/refresh").status == 405, "delete and get")
            check(scratch.decode(PhoneError.self, scratch.get("/v1/nothing"))?.error == "not_found", "error body")
        }
    }),

    ("the meeting list is newest first, pages with before and carries speakers and chat counts", {
        try withScratch { scratch in
            let store = scratch.store
            let names = (10...14).map { "Meeting-2026-10-\($0)-1000.m4a" }
            for name in names { try store.saveTranscript(name, segments: [segment(0, "a", .you), segment(5, "b", .numbered(2))], language: .swedish,
                                                          engine: "x", speakers: [SpeakerProfile(speaker: .numbered(2), name: "Anna", embedding: nil)]) }
            try store.saveSummary(names[0], ParsedSummary(MeetingSummary(title: "Första", actionItems: [], topics: [.init(title: "T", points: ["p"])])))
            _ = try store.createChat(title: "c", scope: .meeting(try store.meetings().first { $0.audioFile == names[0] }!.id, label: nil))
            let page = scratch.decode(PhoneMeetingList.self, scratch.get("/v1/meetings?limit=2"))
            let newest = try store.meetings().map(\.created).max()
            check(page?.meetings.count == 2 && page?.meetings[0].date == newest, "two newest")
            check(page?.nextBefore == page?.meetings[1].date, "cursor is the last date")
            let next = scratch.decode(PhoneMeetingList.self, scratch.get("/v1/meetings?limit=2&before=\(ISO8601DateFormatter().string(from: page!.nextBefore!))"))
            check(next?.meetings.count == 2 && next!.meetings.allSatisfy { $0.date < page!.nextBefore! }, "next page is older")
            let last = scratch.decode(PhoneMeetingList.self, scratch.get("/v1/meetings?limit=2&before=\(ISO8601DateFormatter().string(from: next!.nextBefore!))"))
            check(last?.meetings.count == 1 && last?.nextBefore == nil, "last page has no cursor")
            let all = scratch.decode(PhoneMeetingList.self, scratch.get("/v1/meetings"))
            check(all?.meetings.count == 5 && all?.nextBefore == nil, "default limit holds all")
            let oldest = all?.meetings.last
            check(oldest?.title == "Första" && oldest?.hasSummary == true && oldest?.chatCount == 1, "summary flag, title and chat count")
            check(oldest?.speakers == ["Du", "Anna"] && oldest?.language == "sv", "speakers by name, language code")
            check(scratch.decode(PhoneMeetingList.self, scratch.get("/v1/meetings?limit=0"))?.meetings.count == 1, "limit is at least one")
            check(scratch.get("/v1/meetings?before=yesterday").status == 400, "bad cursor")
        }
    }),

    ("searching meetings uses the full text index and returns snippets", {
        try withScratch { scratch in
            let store = scratch.store
            try store.saveTranscript("Meeting-2026-10-10-1000.m4a", segments: [segment(0, "Vi pratar om fakturering och påminnelser")], language: .swedish, engine: "x")
            try store.saveTranscript("Meeting-2026-10-11-1000.m4a", segments: [segment(0, "Helt annat ämne")], language: .swedish, engine: "x")
            let found = scratch.decode(PhoneMeetingList.self, scratch.get("/v1/meetings?query=fakturer"))
            check(found?.meetings.count == 1 && found?.nextBefore == nil, "one match")
            check(found?.meetings.first?.snippet?.contains("**fakturering**") == true, "snippet highlights the match: \(found?.meetings.first?.snippet ?? "")")
            check(scratch.decode(PhoneMeetingList.self, scratch.get("/v1/meetings?query=zzzz"))?.meetings.isEmpty == true, "no match")
            check(scratch.decode(PhoneMeetingList.self, scratch.get("/v1/meetings?query=%20%20"))?.meetings.count == 2, "a blank query lists everything")
            check(scratch.get("/v1/meetings?query=%22%28%29%20OR").status == 200, "odd characters do not break the search")
        }
    }),

    ("a meeting's detail has the summary, action items, notes, transcript with ends and speaker names, and the audio", {
        try withScratch { scratch in
            let store = scratch.store
            let name = "Meeting-2026-10-10-1000.m4a"
            try store.saveTranscript(name, segments: [segment(0, "Hej", .you), segment(4, "Hallå", .numbered(1)), segment(100, "Sist", .numbered(1))], language: .swedish,
                                     detected: true, engine: "KB-Whisper", speakers: [SpeakerProfile(speaker: .numbered(1), name: "Anna", embedding: nil)])
            try store.saveSummary(name, ParsedSummary(MeetingSummary(title: "Daglig", actionItems: [.init(task: "Skicka", owner: "Anna")],
                                                                     topics: [.init(title: "Release", points: ["Tisdag", "Test"])])))
            try store.setNotes(name, "mina anteckningar")
            try store.setDurations([name: 130])
            let id = try store.meetings()[0].id
            let before = scratch.decode(PhoneMeetingDetail.self, scratch.get("/v1/meetings/\(id)"))?.audio
            check(before?.available == false && before?.bytes == nil && before?.contentType == nil, "no file, no audio")
            try Data(repeating: 1, count: 2048).write(to: scratch.recordings.appendingPathComponent(name))
            let detail = scratch.decode(PhoneMeetingDetail.self, scratch.get("/v1/meetings/\(id)"))
            check(detail?.title == "Daglig" && detail?.summaryTitle == "Daglig" && detail?.notes == "mina anteckningar", "titles and notes")
            check(detail?.topics == [PhoneSummaryTopic(title: "Release", points: ["Tisdag", "Test"])], "topics")
            check(detail?.actionItems.map(\.text) == ["Skicka"] && detail?.actionItems.first?.owner == "Anna" && detail?.actionItems.first?.done == false, "action items")
            check(detail?.languages == ["sv"] && detail?.languageDetected == true && detail?.engines == PhoneEngines(transcript: "KB-Whisper", summary: "apple-intelligence"), "languages and engines")
            check(detail?.transcript.map(\.end) == [4, 19, 115], "a segment ends where the next starts, at most 15 seconds on")
            check(detail?.transcript.map(\.speakerName) == ["Du", "Anna", "Anna"] && detail?.transcript.map(\.speaker) == ["you", "speaker-1", "speaker-1"], "speakers")
            check(detail?.audio == PhoneAudioInfo(available: true, duration: 130, bytes: 2048, contentType: "audio/mp4"), "audio info")
            check(scratch.get("/v1/meetings/9999").status == 404 && scratch.get("/v1/meetings/abc").status == 404, "unknown meeting")
        }
    }),

    ("audio is served whole or in ranges with the headers a player needs", {
        try withScratch { scratch in
            let store = scratch.store
            let name = "Meeting-2026-10-10-1000.m4a"
            try store.saveTranscript(name, segments: [], language: .english, engine: "x")
            let bytes = Data((0..<1000).map { UInt8($0 % 251) })
            let url = scratch.recordings.appendingPathComponent(name)
            try bytes.write(to: url)
            let id = try store.meetings()[0].id
            func read(_ response: PhoneResponse) -> Data? {
                guard case .file(let file, let offset, let length) = response.body, let handle = try? FileHandle(forReadingFrom: file) else { return nil }
                try? handle.seek(toOffset: UInt64(offset))
                return try? handle.read(upToCount: Int(length))
            }
            let whole = scratch.get("/v1/meetings/\(id)/audio")
            check(whole.status == 200 && whole.contentType == "audio/mp4" && whole.headers["Accept-Ranges"] == "bytes" && read(whole) == bytes, "whole file")
            let part = scratch.get("/v1/meetings/\(id)/audio", headers: ["range": "bytes=100-199"])
            check(part.status == 206 && part.headers["Content-Range"] == "bytes 100-199/1000" && read(part) == bytes[100..<200], "partial")
            let tail = scratch.get("/v1/meetings/\(id)/audio", headers: ["range": "bytes=-10"])
            check(tail.status == 206 && tail.headers["Content-Range"] == "bytes 990-999/1000" && read(tail) == bytes.suffix(10), "suffix")
            let open = scratch.get("/v1/meetings/\(id)/audio", headers: ["range": "bytes=900-"])
            check(open.status == 206 && read(open) == bytes.suffix(100), "open ended")
            let beyond = scratch.get("/v1/meetings/\(id)/audio", headers: ["range": "bytes=5000-"])
            check(beyond.status == 416 && beyond.headers["Content-Range"] == "bytes */1000", "unsatisfiable")
            try FileManager.default.removeItem(at: url)
            check(scratch.get("/v1/meetings/\(id)/audio").status == 404, "file gone")
        }
    }),

    ("a stored file name that leaves the recordings folder is never served", {
        try withScratch { scratch in
            try Data("secret".utf8).write(to: scratch.folder.appendingPathComponent("secret.m4a"))
            try scratch.store.setNotes("../secret.m4a", "x")
            try scratch.store.setNotes("sub/../../secret.m4a", "x")
            for meeting in try scratch.store.meetings() {
                check(scratch.get("/v1/meetings/\(meeting.id)/audio").status == 404, "audio of \(meeting.audioFile)")
                check(scratch.decode(PhoneMeetingDetail.self, scratch.get("/v1/meetings/\(meeting.id)"))?.audio.available == false, "detail of \(meeting.audioFile)")
            }
        }
    }),

    ("activity for a day has totals and blocks, leaves out idle time and keeps redacted blocks stripped", {
        try withScratch { scratch in
            let store = scratch.store
            let blocks = [activityBlock(0, 0, title: "Editing"), activityBlock(0, 60, app: "1Password", title: "Vault"), activityBlock(0, 120, app: "Slack", title: "DM"),
                          activityBlock(0, 180, idle: true), activityBlock(0, 240, title: "Writing", prompt: "secret prompt")]
            for block in blocks { _ = try store.saveBlock(block) }
            try store.redact(blockIDs: [2], as: .private)
            try store.redact(blockIDs: [3], as: .other)
            let day = ActivityLogic.dateText(t0)
            let response = scratch.get("/v1/activity/day?date=\(day)")
            let activity = scratch.decode(PhoneActivity.self, response)
            check(response.status == 200 && activity?.days.count == 1 && activity?.days.first?.date == day, "one day")
            check(activity?.blocks.count == 4, "idle left out: \(activity?.blocks.count ?? -1)")
            let byID = Dictionary(uniqueKeysWithValues: (activity?.blocks ?? []).map { ($0.id, $0) })
            check(byID[1]?.title == "Editing" && byID[1]?.branch == "QDLY-1-fix" && byID[1]?.repo == "api" && byID[1]?.summary == "Fixing a bug", "a normal block keeps its details")
            check(byID[2] == PhoneBlock(id: byID[2]!.id, start: byID[2]!.start, end: byID[2]!.end, app: "1Password", category: "coding", projectGuessed: false, redaction: "private"),
                  "a private block keeps app, times and category")
            check(byID[3]?.app == nil && byID[3]?.title == nil && byID[3]?.redaction == "other" && byID[3]?.category == nil, "an other block keeps only times")
            check(byID[5]?.excerpt == (ActivitySettings.promptsStored ? "secret prompt" : nil), "a stored prompt is sent only when the setting is on")
            check(activity?.totals.apps.contains { $0.name == "Other" } == true && activity?.totals.activeSeconds ?? 0 > 0, "totals count the other apps as Other")
            check(!String(decoding: { if case .data(let data) = response.body { return data } else { return Data() } }(), as: UTF8.self).contains("Vault"), "a stripped title is nowhere in the response")
            check(scratch.get("/v1/activity/day?date=nope").status == 400 && scratch.get("/v1/activity/day").status == 400, "bad dates")
        }
    }),

    ("a block's fields follow its redaction even when the row still holds more", {
        let rules: [ProjectRule] = []
        for redaction in [ActivityRedaction.private, .other, .otherSite] {
            var block = activityBlock(1, 0, title: "Secret title", redaction: redaction, prompt: "prompt")
            block.key.url = "bank.example/account"
            block.typedExcerpt = "typed"
            let dto = PhoneEndpoints.block(block, rules: rules, projects: [])
            check(dto.title == nil && dto.url == nil && dto.repo == nil && dto.branch == nil && dto.ticket == nil && dto.summary == nil && dto.excerpt == nil, "\(redaction) is stripped")
            check(dto.app == (redaction == .other ? nil : "Xcode") && dto.redaction == redaction.rawValue, "\(redaction) app")
        }
    }),

    ("activity for a week covers seven days with a total each", {
        try withScratch { scratch in
            _ = try scratch.store.saveBlock(activityBlock(0, 0, title: "Editing"))
            let activity = scratch.decode(PhoneActivity.self, scratch.get("/v1/activity/week?start=\(ActivityLogic.dateText(t0))"))
            check(activity?.days.count == 7 && activity?.days.map(\.date).sorted() == activity?.days.map(\.date), "seven days in order")
            check(activity?.days.filter { $0.activeSeconds > 0 }.count == 1 && activity?.blocks.count == 1, "the day with activity")
            check(activity?.to.timeIntervalSince(activity!.from) ?? 0 >= 6 * 86400, "a week long")
        }
    }),

    ("GitHub returns the cached pull requests by kind, nothing when it is off, and refreshes through the client", {
        try withScratch { scratch in
            let pr = GitHubPR(url: "https://github.com/acme/api/pull/7", number: 7, title: "QDLY-1: Example", repo: "acme/api", state: .open, updated: t0,
                              review: .approved, checks: .passed, author: "niklas", additions: 10, deletions: 2, comments: 3, labels: ["bug"])
            try scratch.store.saveGitHubPRs([.created: [pr], .mentioned: []], fetched: t0.addingTimeInterval(60))
            let github = scratch.decode(PhoneGitHub.self, scratch.get("/v1/github"))
            check(github?.enabled == true && github?.refreshedAt == t0.addingTimeInterval(60), "enabled and fetched")
            check(github?.prs["created"] == [PhoneEndpoints.pullRequest(pr)] && github?.prs["assigned"]?.isEmpty == true && github?.prs.count == 4, "all four kinds")
            check(github?.prs["created"]?.first?.ticket == "QDLY-1" && github?.prs["created"]?.first?.review == "approved", "fields")
            var off = scratch
            off.githubEnabled = false
            let hidden = off.decode(PhoneGitHub.self, off.get("/v1/github"))
            check(hidden?.enabled == false && hidden?.prs.values.allSatisfy(\.isEmpty) == true && hidden?.refreshedAt == nil, "off shows nothing")
            check(off.get("/v1/github/refresh", method: "POST").status == 409, "refresh refused while off")

            nonisolated(unsafe) var refreshed = 0
            var endpoints = scratch.endpoints
            endpoints.refreshGitHub = { refreshed += 1; return "Rate limited" }
            let request = HTTPRequest(method: "POST", path: "/v1/github/refresh", query: [:], headers: [:], body: Data())
            guard case .response(let response) = await_({ [endpoints] in await endpoints.handle(request) }) else { return check(false, "response") }
            check(refreshed == 1 && scratch.decode(PhoneGitHub.self, response)?.error == "Rate limited" && response.status == 200, "refresh ran once and reports its error")
        }
    }),

    ("a chat request becomes a job on the Mac with its scope and earlier turns, and bad ones are refused", {
        try withScratch { scratch in
            let name = "Meeting-2026-10-10-1000.m4a"
            try scratch.store.saveTranscript(name, segments: [segment(0, "Hej")], language: .swedish, engine: "x")
            let id = try scratch.store.meetings()[0].id
            func post(_ request: PhoneChatRequest) -> PhoneRoute {
                let endpoints = scratch.endpoints
                let http = HTTPRequest(method: "POST", path: "/v1/chat", query: [:], headers: [:], body: (try? PhoneAPI.encoder.encode(request)) ?? Data())
                return await_({ await endpoints.handle(http) })
            }
            func status(_ route: PhoneRoute) -> Int? { if case .response(let response) = route { return response.status } else { return nil } }
            let messages = [PhoneChatMessage(role: "user", text: "first"), PhoneChatMessage(role: "assistant", text: "answer"), PhoneChatMessage(role: "user", text: "second")]
            guard case .chat(let job) = post(PhoneChatRequest(scope: PhoneChatScope(kind: "meeting", meetingId: id), messages: messages)) else { return check(false, "a job") }
            check(job.question == "second" && job.history.map(\.text) == ["first", "answer"] && job.history.map(\.role) == [.user, .assistant], "history and question")
            check(job.scope.kind == .meeting && job.scope.id == id, "meeting scope")
            if case .chat(let general) = post(PhoneChatRequest(scope: PhoneChatScope(kind: "general"), messages: [messages[0]])) { check(general.scope.isGeneral, "general") } else { check(false, "general job") }
            if case .chat(let day) = post(PhoneChatRequest(scope: PhoneChatScope(kind: "day", date: "2026-10-17"), messages: [messages[0]])) { check(day.scope.kind == .day && day.scope.from != nil, "day") } else { check(false, "day job") }
            if case .chat(let week) = post(PhoneChatRequest(scope: PhoneChatScope(kind: "week", date: "2026-10-17"), messages: [messages[0]])) { check(week.scope.kind == .week, "week") } else { check(false, "week job") }
            check(status(post(PhoneChatRequest(scope: PhoneChatScope(kind: "meeting", meetingId: 999), messages: [messages[0]]))) == 404, "unknown meeting")
            check(status(post(PhoneChatRequest(scope: PhoneChatScope(kind: "meeting"), messages: [messages[0]]))) == 404, "meeting without id")
            check(status(post(PhoneChatRequest(scope: PhoneChatScope(kind: "nonsense"), messages: [messages[0]]))) == 400, "unknown scope")
            check(status(post(PhoneChatRequest(scope: PhoneChatScope(kind: "day"), messages: [messages[0]]))) == 400, "day without date")
            check(status(post(PhoneChatRequest(scope: PhoneChatScope(kind: "general"), messages: []))) == 400, "no messages")
            check(status(post(PhoneChatRequest(scope: PhoneChatScope(kind: "general"), messages: [messages[1]]))) == 400, "last message not from the user")
            check(status(post(PhoneChatRequest(scope: PhoneChatScope(kind: "general"), messages: [PhoneChatMessage(role: "system", text: "x")]))) == 400, "other roles")
            check(status(post(PhoneChatRequest(scope: PhoneChatScope(kind: "general"), messages: [PhoneChatMessage(role: "user", text: "  ")]))) == 400, "blank question")
            check(status(post(PhoneChatRequest(scope: PhoneChatScope(kind: "general"), messages: [PhoneChatMessage(role: "user", text: String(repeating: "x", count: 9000))]))) == 400, "long message")
            check(scratch.get("/v1/chat", method: "POST", body: Data("nope".utf8)).status == 400, "not json")
        }
    }),
]
