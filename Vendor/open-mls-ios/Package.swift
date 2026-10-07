// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "open-mls-ios",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "open-mls-ios",
            targets: ["open-mls-ios"]
        ),
    ],
    targets: [
        .target(
            name: "open-mls-ios",
            dependencies: ["OpenMlsUniFFI"],
            path: "Sources/open-mls-ios"
        ),
        .binaryTarget(name: "OpenMlsUniFFI", path: "OpenMlsUniFFI.xcframework")
    ]
)
