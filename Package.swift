// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "bridgeport",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.26.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "bridgeport",
            dependencies: [
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
            linkerSettings: [
                // The app bundle scripts embed Sparkle.framework in
                // Contents/Frameworks; the bare SwiftPM binary needs this
                // rpath to find it there when launched from the bundle.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "bridgeportTests",
            dependencies: ["bridgeport"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
            linkerSettings: [
                // SwiftPM does not place binary-artifact frameworks on the
                // test bundle's search path; point dyld at the Sparkle
                // artifact directly (relative to the package root, which is
                // the working directory for `swift test`).
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", ".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"])
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
