// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RTSPPlayer",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "RTSPPlayer",
            targets: ["RTSPPlayer"]),
    ],
    dependencies: [
        // VLCKit SPM 버전 사용
        .package(url: "https://github.com/tylerjonesio/vlckit-spm", from: "3.5.1")
    ],
    targets: [
        .target(
            name: "RTSPPlayer",
            dependencies: [
                .product(name: "VLCKitSPM", package: "vlckit-spm")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "RTSPPlayerTests",
            dependencies: ["RTSPPlayer"]),
    ]
)
