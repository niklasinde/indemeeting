// swift-tools-version:6.2
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
    // Only diarization is used, so FluidAudio's NeMo text-processing trait (a prebuilt binary) stays off.
    // SwiftTerm draws the embedded Claude terminal. Linked statically from source: nothing is embedded or loaded at run time.
    // 1.99.0 because the older releases compile a Metal shader and so need the Metal toolchain and a resource bundle.
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: []),
                   .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.0")],
    targets: [
        .executableTarget(name: "MeetingRecorder",
                          dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), .product(name: "SwiftTerm", package: "SwiftTerm")] + (hasWhisper ? ["whisper"] : []),
                          path: "Sources", sources: ["MeetingRecorder", "Shared"]),
        .testTarget(name: "MeetingRecorderTests", dependencies: ["MeetingRecorder"], path: "Tests/MeetingRecorderTests",
                    swiftSettings: testSettings)
    ] + (hasWhisper ? [.binaryTarget(name: "whisper", path: whisperPath)] : []),
    swiftLanguageModes: [.v5]
)
