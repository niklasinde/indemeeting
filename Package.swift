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
        .executableTarget(name: "MeetingRecorder", dependencies: ["whisper"], path: "Sources/MeetingRecorder",
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                                                          "-Xlinker", "-rpath", "-Xlinker", "@executable_path"])]),
        .binaryTarget(name: "whisper",
                      url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-b5130-xcframework.zip",
                      checksum: "033a43b0174e8cf9b366f72e4a428cdcf126f93ad1c87d3fa119a96bed6f231a"),
        .testTarget(name: "MeetingRecorderTests", dependencies: ["MeetingRecorder"], path: "Tests/MeetingRecorderTests",
                    swiftSettings: testSettings)
    ]
)
