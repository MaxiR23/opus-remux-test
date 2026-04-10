// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OpusRemuxTest",
    platforms: [.macOS(.v13), .iOS(.v16)],
    targets: [
        .target(
            name: "OpusRemuxLib",
            path: "Sources/OpusRemuxLib"
        ),
        .executableTarget(
            name: "OpusRemuxTest",
            dependencies: ["OpusRemuxLib"],
            path: "Sources/OpusRemuxTest"
        ),
        .testTarget(
            name: "ResourceLoaderTests",
            dependencies: ["OpusRemuxLib"],
            path: "Tests/ResourceLoaderTests"
        )
    ]
)
