// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Handy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Handy",
            path: "Handy",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "HandyTests",
            dependencies: ["Handy"],
            path: "Tests/HandyTests"
        )
    ]
)
