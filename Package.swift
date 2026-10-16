// swift-tools-version:5.9
import Foundation
import PackageDescription

// Swift Build in Command Line Tools 27 intermittently drops the TestingMacros plugin; point at it explicitly.
let testingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingPlugins)
    ? [.unsafeFlags(["-plugin-path", testingPlugins])] : []

// Built from source by scripts/build-whisper.sh (build.sh runs it). Without it the app builds without KB-Whisper.
let whisperPath = ".deps/whisper.xcframework"
let hasWhisper = FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent(whisperPath).path)

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "MeetingRecorder", dependencies: hasWhisper ? ["whisper"] : [], path: "Sources/MeetingRecorder"),
        .testTarget(name: "MeetingRecorderTests", dependencies: ["MeetingRecorder"], path: "Tests/MeetingRecorderTests",
                    swiftSettings: testSettings)
    ] + (hasWhisper ? [.binaryTarget(name: "whisper", path: whisperPath)] : [])
)
