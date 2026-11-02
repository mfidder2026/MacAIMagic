// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MacAIMagic",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacAIMagic",
            path: "Sources/MacAIMagic"
        ),
        .testTarget(
            name: "MacAIMagicTests",
            dependencies: ["MacAIMagic"],
            path: "Tests/MacAIMagicTests",
            exclude: ["Fixtures"]
        ),
    ]
)
