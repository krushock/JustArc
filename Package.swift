// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JustArc",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle ships as a binary XCFramework; build-app.sh embeds it in the bundle.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "JustArcCore",
            path: "Sources/JustArcCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "JustArc",
            dependencies: [
                "JustArcCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/JustArc",
            // Info.plist and the .lproj folders are assembled by Scripts/build-app.sh,
            // not processed by SwiftPM.
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "JustArcCoreTests",
            dependencies: ["JustArcCore"],
            path: "Tests/JustArcCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
