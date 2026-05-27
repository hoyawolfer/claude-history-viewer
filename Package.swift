// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeHistoryViewer",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeHistoryViewer",
            path: "Sources/ClaudeHistoryViewer",
            resources: [.process("Resources")]
        )
    ]
)
