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
        // 7-Zip's client-side sources plus our C bridge. The format handlers and codecs
        // themselves live in 7z.so, built from the same source by Scripts/build-7z-library.sh
        // and loaded at run time.
        .target(
            name: "SevenZipBridge",
            path: "Sources/SevenZipBridge",
            sources: [
                "Bridge",
                "7zip/C/Alloc.c",
                "7zip/CPP/Common/IntToString.cpp",
                "7zip/CPP/Common/MyString.cpp",
                "7zip/CPP/Common/MyVector.cpp",
                "7zip/CPP/Common/MyWindows.cpp",
                "7zip/CPP/Common/NewHandler.cpp",
                "7zip/CPP/Common/StringConvert.cpp",
                "7zip/CPP/Common/StringToInt.cpp",
                "7zip/CPP/Common/UTFConvert.cpp",
                "7zip/CPP/Common/Wildcard.cpp",
                "7zip/CPP/Windows/FileDir.cpp",
                "7zip/CPP/Windows/FileFind.cpp",
                "7zip/CPP/Windows/FileIO.cpp",
                "7zip/CPP/Windows/FileName.cpp",
                "7zip/CPP/Windows/PropVariant.cpp",
                "7zip/CPP/Windows/PropVariantConv.cpp",
                "7zip/CPP/Windows/TimeUtils.cpp",
                "7zip/CPP/7zip/Common/FileStreams.cpp",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
                .define("_REENTRANT"),
                // 7-Zip's own sources, compiled unchanged; their warnings are upstream's.
                .unsafeFlags(["-w"]),
            ],
            cxxSettings: [
                .headerSearchPath("7zip/CPP"),
                .define("_FILE_OFFSET_BITS", to: "64"),
                .define("_LARGEFILE_SOURCE"),
                .define("_REENTRANT"),
                .unsafeFlags(["-w"]),
            ],
            linkerSettings: [
                // For decoding file names in legacy code pages.
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "JustArcCore",
            dependencies: ["SevenZipBridge"],
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
        // Drives the app's real views: drops, drags out and the Settings panes.
        .testTarget(
            name: "JustArcAppTests",
            dependencies: ["JustArc", "JustArcCore"],
            path: "Tests/JustArcAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ],
    cxxLanguageStandard: .cxx11
)
