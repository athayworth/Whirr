// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Whirr",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "WhirrCore",
            path: "Sources/WhirrCore"
        ),
        .executableTarget(
            name: "Whirr",
            dependencies: ["WhirrCore"],
            path: "Sources/Whirr",
            exclude: ["Resources/Info.plist"]
        ),
        .executableTarget(
            name: "whirr-probe",
            dependencies: ["WhirrCore"],
            path: "Sources/WhirrProbe"
        ),
        .testTarget(
            name: "WhirrCoreTests",
            dependencies: ["WhirrCore"],
            path: "Tests/WhirrCoreTests"
        )
    ]
)
