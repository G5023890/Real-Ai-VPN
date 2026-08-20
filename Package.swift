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
            name: "WireGuardConfig",
            targets: ["WireGuardConfig"]
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
            name: "WireGuardConfig"
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
                "WireGuardConfig",
                "RealVPNCore",
                "SmartServerSelection"
            ],
            resources: [
                .copy("../../Resources/CoreML"),
                .copy("../../Resources/MenuBarIcons")
            ]
        ),
        .testTarget(
            name: "WireGuardConfigTests",
            dependencies: ["WireGuardConfig"]
        ),
        .testTarget(
            name: "SmartServerSelectionTests",
            dependencies: ["SmartServerSelection"]
        ),
        .testTarget(
            name: "RealVPNCoreTests",
            dependencies: ["RealVPNCore"]
        )
    ]
)
