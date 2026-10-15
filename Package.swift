// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "MeetingRecorder", path: "Sources/MeetingRecorder"),
        .testTarget(name: "MeetingRecorderTests", dependencies: ["MeetingRecorder"], path: "Tests/MeetingRecorderTests")
    ]
)
