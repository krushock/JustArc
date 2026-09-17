// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JustArc",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "JustArcCore",
            path: "Sources/JustArcCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "JustArc",
            dependencies: ["JustArcCore"],
            path: "Sources/JustArc",
            exclude: ["Resources/Info.plist"],
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
