// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DevDriveCacheClean",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .target(
            name: "DDCCCore",
            path: "Sources/DDCCCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "DDCCUI",
            dependencies: ["DDCCCore"],
            path: "Sources/DDCCUI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "DevDriveCacheClean",
            dependencies: ["DDCCUI"],
            path: "Sources/DevDriveCacheClean",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "HelpBookGen",
            dependencies: ["DDCCCore"],
            path: "Sources/HelpBookGen",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "HelpBookBuilder",
            dependencies: ["HelpBookGen"],
            path: "Sources/HelpBookBuilder",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SiteGen",
            dependencies: ["HelpBookGen"],
            path: "Sources/SiteGen",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SiteBuilder",
            dependencies: ["SiteGen"],
            path: "Sources/SiteBuilder",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DDCCCoreTests",
            dependencies: ["DDCCCore"],
            path: "Tests/DDCCCoreTests",
            // Binary fixtures for formats that cannot be written by hand:
            // BOMReaderTests' AppleDouble receipt. No dependency is added.
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DDCCUILogicTests",
            dependencies: ["DDCCUI", "DDCCCore"],
            path: "Tests/DDCCUILogicTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "HelpBookGenTests",
            dependencies: ["HelpBookGen", "DDCCCore"],
            path: "Tests/HelpBookGenTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SiteGenTests",
            dependencies: ["SiteGen"],
            path: "Tests/SiteGenTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
