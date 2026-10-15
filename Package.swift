// swift-tools-version:5.9
import Foundation
import PackageDescription

// Swift Build in Command Line Tools 27 intermittently drops the TestingMacros plugin; point at it explicitly.
let testingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingPlugins)
    ? [.unsafeFlags(["-plugin-path", testingPlugins])] : []

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "MeetingRecorder", path: "Sources/MeetingRecorder"),
        .testTarget(name: "MeetingRecorderTests", dependencies: ["MeetingRecorder"], path: "Tests/MeetingRecorderTests",
                    swiftSettings: testSettings)
    ]
)
