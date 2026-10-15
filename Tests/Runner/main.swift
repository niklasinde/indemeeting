import Foundation

var failed = 0
for test in allTests {
    failures = []
    do { try test.run() } catch { failures.append("threw \(error)") }
    if failures.isEmpty {
        print("PASS \(test.name)")
    } else {
        failed += 1
        print("FAIL \(test.name)")
        failures.forEach { print("     \($0)") }
    }
}
print("\(allTests.count - failed)/\(allTests.count) passed")
exit(failed == 0 ? 0 : 1)
