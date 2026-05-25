// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "SmartVPN",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SmartVPNMacApp",
            targets: ["SmartVPNMacApp"]
        ),
        .library(
            name: "AmneziaConfig",
            targets: ["AmneziaConfig"]
        ),
        .library(
            name: "SmartServerSelection",
            targets: ["SmartServerSelection"]
        ),
        .library(
            name: "RealVPNCore",
            targets: ["RealVPNCore"]
        )
    ],
    targets: [
        .target(
            name: "AmneziaConfig"
        ),
        .target(
            name: "SmartServerSelection"
        ),
        .target(
            name: "RealVPNCore"
        ),
        .executableTarget(
            name: "SmartVPNMacApp",
            dependencies: [
                "AmneziaConfig",
                "RealVPNCore",
                "SmartServerSelection"
            ],
            resources: [
                .copy("../../Resources/MenuBarIcons")
            ]
        ),
        .testTarget(
            name: "AmneziaConfigTests",
            dependencies: ["AmneziaConfig"]
        ),
        .testTarget(
            name: "SmartServerSelectionTests",
            dependencies: ["SmartServerSelection"]
        )
    ]
)
