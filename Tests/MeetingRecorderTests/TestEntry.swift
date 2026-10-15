#if canImport(Testing)
import Testing

@Test(.serialized, arguments: allTests.map(\.name))
func run(_ name: String) throws {
    failures = []
    try allTests.first { $0.name == name }!.run()
    #expect(failures.isEmpty, "\(failures.joined(separator: "; "))")
}
#elseif canImport(XCTest)
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
