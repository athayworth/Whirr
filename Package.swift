// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Whirr",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-update framework. EdDSA-signed releases; we ship the public
        // key in Info.plist (SUPublicEDKey) and sign each release with the
        // private key via Sparkle's `sign_update` CLI. See README for the
        // release workflow. Pinned to 2.x to avoid surprise major bumps.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "WhirrCore",
            path: "Sources/WhirrCore",
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .executableTarget(
            name: "Whirr",
            dependencies: [
                "WhirrCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Whirr",
            exclude: [
                "Resources/Info.plist",
                "Resources/com.athayworth.whirr.sampler.plist",
                "Resources/AppIcon.icns",
                "Resources/AppIcon.iconset",
                "Resources/Whirr.entitlements"
            ]
        ),
        .executableTarget(
            name: "whirr-probe",
            dependencies: ["WhirrCore"],
            path: "Sources/WhirrProbe"
        ),
        .executableTarget(
            name: "whirr-sampler",
            dependencies: ["WhirrCore"],
            path: "Sources/WhirrSampler"
        ),
        .testTarget(
            name: "WhirrCoreTests",
            dependencies: ["WhirrCore"],
            path: "Tests/WhirrCoreTests"
        )
    ]
)
