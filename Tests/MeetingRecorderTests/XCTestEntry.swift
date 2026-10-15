#if canImport(XCTest)
import XCTest

final class MeetingRecorderTests: XCTestCase {
    func testAll() throws {
        for test in allTests {
            failures = []
            try test.run()
            XCTAssertTrue(failures.isEmpty, "\(test.name): \(failures.joined(separator: "; "))")
        }
    }
}
#endif
