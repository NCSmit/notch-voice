// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "NotchVoice", path: "Sources/NotchVoice"),
        .testTarget(name: "NotchVoiceTests", dependencies: ["NotchVoice"], path: "Tests/NotchVoiceTests"),
    ]
)
