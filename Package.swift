// swift-tools-version:6.2
import Foundation
import PackageDescription

// Swift Build in Command Line Tools 27 intermittently drops the TestingMacros plugin; point at it explicitly.
let testingPlugins = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSettings: [SwiftSetting] = FileManager.default.fileExists(atPath: testingPlugins)
    ? [.unsafeFlags(["-plugin-path", testingPlugins])] : []

// whisper.cpp and llama.cpp on one ggml, built from source by scripts/build-ggml.sh (build.sh runs it). Without it the app
// builds without Whisper and the local Ministral.
let ggmlPath = ".deps/ggml.xcframework"
let hasGGML = FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent(ggmlPath).path)

let package = Package(
    name: "WorkTime",
    platforms: [.macOS("26.0")],
    // Only diarization is used, so FluidAudio's NeMo text-processing trait (a prebuilt binary) stays off.
    // SwiftTerm draws the embedded Claude terminal. Linked statically from source: nothing is embedded or loaded at run time.
    // 1.99.0 because the older releases compile a Metal shader and so need the Metal toolchain and a resource bundle.
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: []),
                   .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.0")],
    targets: [
        .executableTarget(name: "WorkTime",
                          dependencies: [.product(name: "FluidAudio", package: "FluidAudio"), .product(name: "SwiftTerm", package: "SwiftTerm")] + (hasGGML ? ["ggml"] : []),
                          path: "Sources", sources: ["WorkTime", "Shared"]),
        .testTarget(name: "WorkTimeTests", dependencies: ["WorkTime"], path: "Tests/WorkTimeTests",
                    swiftSettings: testSettings)
    ] + (hasGGML ? [.binaryTarget(name: "ggml", path: ggmlPath)] : []),
    swiftLanguageModes: [.v5]
)
