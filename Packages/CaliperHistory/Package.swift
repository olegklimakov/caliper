// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaliperHistory",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CaliperHistory", targets: ["CaliperHistory"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(path: "../CaliperCore"),
    ],
    targets: [
        .target(
            name: "CaliperHistory",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "CaliperCore", package: "CaliperCore"),
            ]
        ),
        .testTarget(name: "CaliperHistoryTests", dependencies: ["CaliperHistory"])
    ],
    swiftLanguageModes: [.v6]
)
