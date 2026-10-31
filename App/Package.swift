// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacDeepSeek",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacDeepSeek",
            path: "Sources/MacDeepSeek"
        ),
        .testTarget(
            name: "MacDeepSeekTests",
            dependencies: ["MacDeepSeek"],
            path: "Tests/MacDeepSeekTests"
        ),
    ]
)
