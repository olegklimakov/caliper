// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CaliperCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CaliperCore", targets: ["CaliperCore"])
    ],
    targets: [
        // All private-API declarations live here and nowhere else.
        .target(
            name: "CPrivateShims",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        // Public NVMe SMART API that the IOKit Swift module does not export.
        .target(
            name: "CDriveHealth",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .target(name: "CaliperCore", dependencies: ["CPrivateShims", "CDriveHealth"]),
        .testTarget(name: "CaliperCoreTests", dependencies: ["CaliperCore"])
    ],
    swiftLanguageModes: [.v6]
)
