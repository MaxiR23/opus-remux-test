// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpusRemuxTest",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "OpusRemuxTest",
            path: "Sources/OpusRemuxTest"
        )
    ]
)
