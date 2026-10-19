import Foundation
import Network
import Testing
@testable import MeetingRecorderPhone

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

@Suite struct PairingInputTests {
    @Test func urlRoundTrip() throws {
        let pairing = PhonePairing(host: "mac.local", port: 52114, id: "82ae99e6", key: Data(repeating: 7, count: 16))
        let parsed = try #require(PhonePairing(url: pairing.url))
        #expect(parsed == pairing)
    }

    @Test func rejectsMalformedUrls() {
        for text in ["https://pair?host=a&port=1&id=82ae99e6&key=AAAAAAAAAAAAAAAAAAAAAA", "meetingrecorder://pair?host=a&port=0&id=82ae99e6&key=AAAAAAAAAAAAAAAAAAAAAA",
                     "meetingrecorder://pair?host=a&port=1&id=zz&key=AAAAAAAAAAAAAAAAAAAAAA", "meetingrecorder://pair?host=a&port=1&id=82ae99e6&key=AAAA",
                     "meetingrecorder://other?host=a&port=1&id=82ae99e6&key=AAAAAAAAAAAAAAAAAAAAAA"] {
            #expect(PhonePairing(url: URL(string: text)!) == nil, "\(text)")
        }
    }

    @Test func manualCodeIgnoresCaseSpacesAndDashes() throws {
        let pairing = PhonePairing(host: "m", port: 1, id: "0a0b0c0d", key: Data((0..<16).map { UInt8($0 * 11) }))
        let typed = pairing.manualCode.lowercased().replacingOccurrences(of: "-", with: "  ")
        #expect(PhonePairing(manualCode: typed, host: "m", port: 1) == pairing)
        #expect(PhonePairing(manualCode: "TOO-SHORT", host: "m", port: 1) == nil)
    }

    @Test func hostAndPortInput() {
        #expect(PhoneFormat.hostAndPort("mac.local")?.port == PhoneAPI.defaultPort)
        #expect(PhoneFormat.hostAndPort(" mac.local:52114 ")?.host == "mac.local")
        #expect(PhoneFormat.hostAndPort("192.168.1.4:52114")?.port == 52114)
        #expect(PhoneFormat.hostAndPort("[::1]:9")?.host == "::1")
        #expect(PhoneFormat.hostAndPort("mac.local:0") == nil)
        #expect(PhoneFormat.hostAndPort("mac.local:abc") == nil)
        #expect(PhoneFormat.hostAndPort("a b") == nil)
        #expect(PhoneFormat.hostAndPort("") == nil)
    }
}

@Suite struct FormatTests {
    @Test func durations() {
        #expect(PhoneFormat.duration(33 * 60 + 4) == "33 min")
        #expect(PhoneFormat.duration(20) == "1 min")
        #expect(PhoneFormat.duration(0) == "0 min")
        #expect(PhoneFormat.duration(3900) == "1 h 05 min")
        #expect(PhoneFormat.clock(247) == "4:07")
        #expect(PhoneFormat.clock(3723) == "1:02:03")
        #expect(PhoneFormat.clock(-5) == "0:00")
    }

    @Test func dayTitlesAndGrouping() {
        let now = date("2026-10-19T12:00:00Z")
        let locale = Locale(identifier: "en_US")
        #expect(PhoneFormat.dayTitle(now, now: now, calendar: utc, locale: locale) == "Today")
        #expect(PhoneFormat.dayTitle(date("2026-10-18T23:59:00Z"), now: now, calendar: utc, locale: locale) == "Yesterday")
        #expect(PhoneFormat.dayTitle(date("2026-10-16T08:02:00Z"), now: now, calendar: utc, locale: locale).contains("Friday"))
        #expect(PhoneFormat.dayTitle(date("2025-10-16T08:02:00Z"), now: now, calendar: utc, locale: locale).contains("2025"))
        let items = ["2026-10-19T09:00:00Z", "2026-10-19T08:00:00Z", "2026-10-18T10:00:00Z", "2026-10-10T10:00:00Z"].map(date)
        let groups = PhoneFormat.groupByDay(items, date: { $0 }, now: now, calendar: utc, locale: locale)
        #expect(groups.map(\.items.count) == [2, 1, 1])
        #expect(groups.first?.title == "Today")
    }

    @Test func dayStrings() {
        #expect(PhoneFormat.dayString(date("2026-01-05T10:00:00Z"), calendar: utc) == "2026-01-05")
        #expect(PhoneFormat.day(from: "2026-10-19", calendar: utc) == date("2026-10-19T00:00:00Z"))
        #expect(PhoneFormat.day(from: "nope", calendar: utc) == nil)
    }

    @Test func markdownExport() {
        let meeting = PhoneMeetingDetail(id: 7, title: "Standup", date: date("2026-10-16T08:02:00Z"), duration: 1964, languages: ["sv"], languageDetected: false,
                                         engines: PhoneEngines(), summaryTitle: "Daily standup", summaryUnavailable: nil,
                                         topics: [PhoneSummaryTopic(title: "Release", points: ["Ship on Friday", "Freeze Thursday"])],
                                         actionItems: [PhoneActionItem(id: 1, owner: "Anna", text: "Write notes", done: false), PhoneActionItem(id: 2, owner: nil, text: "Tag release", done: true)],
                                         notes: "  remember the flag  ", transcript: [], audio: PhoneAudioInfo(available: false))
        let markdown = PhoneFormat.markdown(for: meeting, locale: Locale(identifier: "en_US"), calendar: utc)
        #expect(markdown.hasPrefix("# Daily standup\n*Friday, October 16, 2026"))
        #expect(markdown.contains("33 min*"))
        #expect(markdown.contains("## Release\n- Ship on Friday\n- Freeze Thursday"))
        #expect(markdown.contains("- [ ] Anna: Write notes\n- [x] Tag release"))
        #expect(markdown.hasSuffix("## Notes\nremember the flag\n"))
    }

    @Test func timesInAnswersBecomeSeeks() throws {
        let linked = PhoneFormat.linkTimes(in: "Decided at 10:02 and again at 1:02:03, not 12:75 or v1:2:3x.")
        #expect(linked.contains("[10:02](mrseek://602)"))
        #expect(linked.contains("[1:02:03](mrseek://3723)"))
        #expect(!linked.contains("[12:75]"))
        #expect(PhoneFormat.seekSeconds(URL(string: "mrseek://602")!) == 602)
        #expect(PhoneFormat.seekSeconds(URL(string: "https://602")!) == nil)
    }

    @Test func shortSpeakers() {
        #expect(PhoneFormat.shortSpeakers(["a", "b"]) == ["a", "b"])
        #expect(PhoneFormat.shortSpeakers(["a", "b", "c", "d", "e"]) == ["a", "b", "c", "+2"])
    }
}

@Suite struct NetworkLogicTests {
    @Test func classifiesConnectionErrors() {
        #expect(PhoneNetworkError.classify(.tls(-9820)) == .keyRejected)
        #expect(PhoneNetworkError.classify(.tls(-9864)) == .keyRejected)
        #expect(PhoneNetworkError.classify(.tls(-9824)) == .keyRejected)
        #expect(PhoneNetworkError.classify(.tls(-9816)) == .blocked)
        #expect(PhoneNetworkError.classify(.posix(.ECONNREFUSED)) == .unreachable)
        #expect(PhoneNetworkError.classify(.posix(.ETIMEDOUT)) == .timeout)
        #expect(PhoneNetworkError.classify(.posix(.ECONNRESET)) == .connectionLost)
    }

    @Test func rejectionAndRetrySemantics() {
        #expect(PhoneNetworkError.keyRejected.isRejection)
        #expect(PhoneNetworkError.http(status: 401, error: nil).isRejection)
        #expect(!PhoneNetworkError.http(status: 404, error: nil).isRejection)
        #expect(PhoneNetworkError.unreachable.isConnectionFailure)
        #expect(!PhoneNetworkError.keyRejected.isConnectionFailure)
    }

    @Test func decodesErrorBodies() throws {
        let body = Data(#"{"error":"chat_busy","message":"Busy"}"#.utf8)
        let response = PhoneResponse(head: HTTPResponseHead(status: 429, reason: "Too Many Requests", headers: [:]), body: body)
        do { _ = try response.decoded(PhoneStatus.self); Issue.record("should throw") } catch let error as PhoneNetworkError {
            #expect(error == .http(status: 429, error: PhoneError(error: "chat_busy", message: "Busy")))
            #expect(error.message == "Busy")
        }
    }

    @Test func audioProxyRequestParsing() {
        let request = AudioProxy.parseRequest(Data("GET /tok/meetings/7/audio.m4a HTTP/1.1\r\nHost: 127.0.0.1\r\nrange: bytes=100-\r\n\r\n".utf8))
        #expect(request == AudioProxy.LocalRequest(method: "GET", path: "/tok/meetings/7/audio.m4a", range: "bytes=100-"))
        #expect(AudioProxy.parseRequest(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
        #expect(AudioProxy.meetingID(inPath: "/tok/meetings/7/audio.m4a", token: "tok") == 7)
        #expect(AudioProxy.meetingID(inPath: "/bad/meetings/7/audio.m4a", token: "tok") == nil)
        #expect(AudioProxy.meetingID(inPath: "/tok/meetings/x/audio.m4a", token: "tok") == nil)
        #expect(AudioProxy.meetingID(inPath: "/tok/secrets/7/audio", token: "tok") == nil)
    }

    @Test func audioProxyHeadKeepsRangeHeaders() {
        let head = HTTPResponseHead(status: 206, reason: "Partial Content", headers: ["content-range": "bytes 0-9/100", "content-length": "10", "content-type": "audio/mp4", "set-cookie": "x"])
        let text = String(decoding: AudioProxy.localHead(for: head), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 206 Partial Content\r\n"))
        #expect(text.contains("Content-Range: bytes 0-9/100"))
        #expect(text.contains("Content-Length: 10"))
        #expect(!text.lowercased().contains("set-cookie"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func endpointOrder() throws {
        let service = DiscoveredMac(name: "Niklass-MacBook-Pro", endpoint: .service(name: "Niklass-MacBook-Pro", type: "_meetingrecorder._tcp", domain: "local", interface: nil))
        let other = DiscoveredMac(name: "Other Mac", endpoint: .service(name: "Other Mac", type: "_meetingrecorder._tcp", domain: "local", interface: nil))
        var mac = PairedMac(deviceId: "a", serverName: "Niklass-MacBook-Pro.local", host: "Niklass-MacBook-Pro.local", port: 47821, override: nil, pairedAt: Date())
        let plain = MacLocator.order(mac: mac, discovered: [other, service])
        #expect(plain.count == 2)
        #expect(plain[0] == service.endpoint)
        mac.override = .init(host: "100.64.0.9", port: 1234)
        let typed = MacLocator.order(mac: mac, discovered: [service])
        #expect(typed.count == 3)
        #expect(typed[0] == .hostPort(host: "100.64.0.9", port: 1234))
    }
}

@Suite struct CacheTests {
    @Test func roundTripsAndClears() throws {
        let cache = try PhoneCache.inMemory()
        let list = PhoneMeetingList(meetings: [PhoneMeetingSummary(id: 1, title: "A", date: date("2026-10-16T08:02:00Z"), duration: 60, language: "sv", hasSummary: true,
                                                                    speakers: ["Du"], chatCount: 0, snippet: nil)], nextBefore: nil)
        let stamp = date("2026-10-17T10:00:00Z")
        cache.put(list, for: "meetings", at: stamp)
        let hit = try #require(cache.get(PhoneMeetingList.self, for: "meetings"))
        #expect(hit.value == list)
        #expect(hit.fetched == stamp)
        #expect(cache.get(PhoneMeetingList.self, for: "missing") == nil)
        #expect(cache.get(PhoneStatus.self, for: "meetings") == nil)
        cache.clear()
        #expect(cache.get(PhoneMeetingList.self, for: "meetings") == nil)
    }

    @Test func trimKeepsNewest() throws {
        let cache = try PhoneCache.inMemory()
        for index in 0..<5 { cache.put(PhoneError(error: "e", message: "\(index)"), for: "meeting.\(index)", at: Date(timeIntervalSince1970: Double(index))) }
        cache.put(PhoneError(error: "e", message: "x"), for: "other", at: Date(timeIntervalSince1970: 0))
        cache.trim(prefix: "meeting.", keeping: 2)
        #expect(cache.get(PhoneError.self, for: "meeting.4") != nil)
        #expect(cache.get(PhoneError.self, for: "meeting.3") != nil)
        #expect(cache.get(PhoneError.self, for: "meeting.2") == nil)
        #expect(cache.get(PhoneError.self, for: "other") != nil)
    }

    @Test func pairedMacStoreAndKeychainDouble() {
        let keys = MemoryKeyStore()
        try? keys.save(Data([1, 2]), for: "a")
        #expect(keys.key(for: "a") == Data([1, 2]))
        keys.delete("a")
        #expect(keys.key(for: "a") == nil)
        let store = MemoryPairedMacStore()
        let mac = PairedMac(deviceId: "a", serverName: "s", host: "h", port: 1, override: nil, pairedAt: Date())
        store.save(mac)
        #expect(store.load() == mac)
        store.save(nil)
        #expect(store.load() == nil)
    }

    @Test func localSearchMatchesEveryWord() {
        let item = { (title: String) in PhoneMeetingSummary(id: 1, title: title, date: Date(), duration: nil, language: nil, hasSummary: false, speakers: [], chatCount: 0, snippet: nil) }
        let items = [item("Daily standup release"), item("Planning"), item("Release retro")]
        #expect(MeetingsModel.localMatches(items, "release").count == 2)
        #expect(MeetingsModel.localMatches(items, "release standup").count == 1)
        #expect(MeetingsModel.localMatches(items, "zzz").isEmpty)
    }

    @Test func chatHistoryDropsUnansweredQuestions() {
        let turns = [ChatTurn(role: "user", text: "q1"), ChatTurn(role: "assistant", text: "a1"), ChatTurn(role: "user", text: "q2"),
                     { var turn = ChatTurn(role: "assistant", text: ""); turn.failure = "busy"; return turn }()]
        #expect(ChatModel.messages(from: turns) == [PhoneChatMessage(role: "user", text: "q1"), PhoneChatMessage(role: "assistant", text: "a1")])
    }
}
