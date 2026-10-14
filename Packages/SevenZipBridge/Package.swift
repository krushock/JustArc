// swift-tools-version: 6.0
import PackageDescription

// JustArc's bridge to 7-Zip, built as a dynamic library.
//
// 7-Zip is under the GNU LGPL. Code compiled into an app's own executable has to be
// replaceable by whoever has the app, which for a closed executable means shipping
// its object files. Kept in a library of its own, everything of 7-Zip's can be
// replaced by swapping one file, and JustArc's executables contain none of it. See
// LICENSE.md beside this file.
let package = Package(
    name: "SevenZipBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SevenZipBridge", type: .dynamic, targets: ["SevenZipBridge"]),
    ],
    targets: [
        // 7-Zip's client-side sources plus the C bridge over them. The format handlers
        // and codecs themselves live in 7z.so, built from the same source by
        // Scripts/build-7z-library.sh and loaded at run time.
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
    ],
    cxxLanguageStandard: .cxx11
)
