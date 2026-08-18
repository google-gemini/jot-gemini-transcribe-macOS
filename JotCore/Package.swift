// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "JotCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "JotCore", targets: ["JotCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/Clipy/Sauce.git", from: "2.2.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "JotCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "Sauce",
                "KeyboardShortcuts",
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "JotCoreTests",
            dependencies: ["JotCore"],
            path: "Tests"
        ),
    ]
)
