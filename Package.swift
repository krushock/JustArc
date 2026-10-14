// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JustArc",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Sparkle ships as a binary XCFramework; build-app.sh embeds it in the bundle.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // The bridge to 7-Zip, with the 7-Zip sources it is compiled from. A package
        // of its own so that it can be a dynamic library: nothing of 7-Zip's is
        // compiled into JustArc's own executables. See Packages/SevenZipBridge.
        .package(path: "Packages/SevenZipBridge"),
    ],
    targets: [
        .target(
            name: "JustArcCore",
            dependencies: [.product(name: "SevenZipBridge", package: "SevenZipBridge")],
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
        // What Quick Look shows for an archive. A library, so that the tests can
        // draw it without Quick Look.
        .target(
            name: "JustArcPreview",
            dependencies: ["JustArcCore"],
            path: "Sources/JustArcPreview",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        // The Quick Look extension's executable. An app extension has no main of its
        // own: it starts in Foundation's NSExtensionMain, which loads the class named
        // in its Info.plist. Scripts/build-app.sh wraps it into the .appex.
        .executableTarget(
            name: "JustArcQuickLook",
            dependencies: ["JustArcPreview"],
            path: "Sources/JustArcQuickLook",
            exclude: ["Resources"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("QuickLookUI"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        .testTarget(
            name: "JustArcCoreTests",
            dependencies: ["JustArcCore"],
            path: "Tests/JustArcCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Drives the app's real views: drops, drags out and the Settings panes.
        .testTarget(
            name: "JustArcAppTests",
            dependencies: ["JustArc", "JustArcCore", "JustArcPreview"],
            path: "Tests/JustArcAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
