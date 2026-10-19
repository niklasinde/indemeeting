import XCTest

/// Drives the app against the Mac's `--serve` instance and saves a screenshot of every state. Not part of the normal test
/// run: it needs a server, and `E2E_CODE` and `E2E_ADDRESS` (from the server's `pair` command), `E2E_SHOTS` (an output
/// folder) and optionally `E2E_MEETING` (a title to open) passed as `TEST_RUNNER_<NAME>` environment variables.
final class EndToEndTests: XCTestCase {
    private var app: XCUIApplication!
    private let environment = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func shot(_ name: String) {
        let folder = environment["E2E_SHOTS"] ?? NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    private func tab(_ name: String) {
        if !app.tabBars.buttons[name].exists { app.swipeDown() }
        app.tabBars.buttons[name].tap()
    }

    func test1_PairAndBrowse() throws {
        let code = try XCTUnwrap(environment["E2E_CODE"]), address = try XCTUnwrap(environment["E2E_ADDRESS"])
        app.launch()
        shot("01-welcome")
        app.buttons["Enter code instead"].tap()
        let codeField = app.textFields["Pairing code"]
        XCTAssertTrue(codeField.waitForExistence(timeout: 5))
        sleep(1)
        codeField.tap()
        sleep(1)
        codeField.typeText(code)
        let addressField = app.textFields["Mac address and port"]
        addressField.tap()
        sleep(1)
        addressField.typeText(address)
        shot("02-enter-code")
        app.buttons["Pair"].tap()
        sleep(4)
        shot("02b-after-pair")

        XCTAssertTrue(app.tabBars.buttons["Meetings"].waitForExistence(timeout: 20), "pairing did not finish")
        let title = environment["E2E_MEETING"] ?? "standup"
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        shot("03-meetings")
        row.tap()
        XCTAssertTrue(app.buttons["Play recording"].exists || app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play recording'")).firstMatch.waitForExistence(timeout: 10))
        shot("04-detail-summary")
        app.buttons["Notes"].tap()
        shot("05-detail-notes")
        app.buttons["Actions"].tap()
        shot("06-detail-actions")
        app.buttons["Transcript"].tap()
        shot("07-detail-transcript")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play recording'")).firstMatch.tap()
        sleep(6)
        shot("08-playing")
        app.buttons["Pause"].firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()

        tab("Activity")
        sleep(4)
        shot("09-activity-day")
        app.buttons["Week"].tap()
        sleep(4)
        shot("10-activity-week")

        tab("GitHub")
        sleep(4)
        shot("11-github")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review'")).firstMatch.tap()
        shot("12-github-review")

        tab("Chat")
        shot("13-chat-empty")
        app.buttons["What meetings did I have this week?"].tap()
        sleep(25)
        shot("14-chat-answer")

        tab("Settings")
        sleep(1)
        shot("15-settings")
    }

    /// Screens of the paired app, named with `E2E_SUFFIX`; run once per appearance, device and text size.
    func test4_Tour() throws {
        let suffix = environment["E2E_SUFFIX"] ?? "tour"
        let title = environment["E2E_MEETING"] ?? "standup"
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Meetings"].waitForExistence(timeout: 20))
        sleep(3)
        shot("meetings-\(suffix)")
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        sleep(2)
        shot("detail-\(suffix)")
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play recording'")).firstMatch
        for _ in 0..<6 where !play.isHittable { app.swipeUp() }
        shot("detail-scrolled-\(suffix)")
        play.tap()
        sleep(4)
        shot("playing-\(suffix)")
        app.buttons["Pause"].firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        for name in ["Activity", "GitHub", "Chat", "Settings"] {
            tab(name)
            sleep(3)
            shot("\(name.lowercased())-\(suffix)")
        }
        tab("Chat")
        app.buttons["What meetings did I have this week?"].tap()
        sleep(25)
        shot("chat-answer-\(suffix)")
    }

    func test5_Settings() throws {
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Meetings"].waitForExistence(timeout: 20))
        tab("Settings")
        sleep(3)
        shot("settings-\(environment["E2E_SUFFIX"] ?? "only")")
    }

    /// Seeks while playing, then asks a question while another client's chat is running (start one before this test).
    func test6_SeekAndBusyChat() throws {
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Meetings"].waitForExistence(timeout: 20))
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", environment["E2E_MEETING"] ?? "standup")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play recording'")).firstMatch.tap()
        let position = app.sliders["Position"]
        XCTAssertTrue(position.waitForExistence(timeout: 10))
        sleep(4)
        let before = position.value as? String ?? ""
        position.adjust(toNormalizedSliderPosition: 0.7)
        sleep(5)
        shot("seek-after")
        XCTAssertNotEqual(position.value as? String, before)
        app.buttons["Pause"].firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        tab("Chat")
        app.buttons["What did I decide about the release?"].tap()
        let busy = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'answering another question'")).firstMatch
        _ = busy.waitForExistence(timeout: 30)
        shot("chat-busy")
        XCTAssertTrue(busy.exists)
        XCTAssertTrue(app.buttons["Try again"].exists)
    }

    func test2_OfflineShowsCachedData() throws {
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Meetings"].waitForExistence(timeout: 20))
        sleep(10)
        shot("16-offline-meetings")
        tab("Activity")
        sleep(2)
        shot("17-offline-activity")
        tab("Settings")
        sleep(1)
        shot("18-offline-settings")
    }

    func test3_RevokedKeyAsksToPairAgain() throws {
        app.launch()
        XCTAssertTrue(app.buttons["Pair again"].waitForExistence(timeout: 30))
        shot("19-repair")
        app.buttons["Pair again"].tap()
        XCTAssertTrue(app.buttons["Enter code instead"].waitForExistence(timeout: 5))
        shot("20-welcome-after-forget")
    }
}
