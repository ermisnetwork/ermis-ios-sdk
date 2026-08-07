// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ErmisChat",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15), .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "ErmisChat",
            targets: ["ErmisChat"]
        ),
        .library(
            name: "ErmisChatUI",
            targets: ["ErmisChatUI"]
        ),
//        .library(name: "ErmisWalletAuth",
//                 targets: ["ErmisWalletAuth"])
    ],
    dependencies: [
        .package(url: "https://github.com/Recouse/EventSource.git", from: "0.1.7"),
//        .package(url: "https://github.com/reown-com/reown-swift", from: "1.6.0"),
//        .package(url: "https://github.com/Boilertalk/Web3.swift.git", from: "0.6.0"),
        .package(url: "https://github.com/daltoniam/Starscream.git", from: "3.1.2"),
        .package(url: "https://github.com/airbnb/lottie-spm.git", from: "4.5.2"),
//        .package(url: "https://github.com/ermisnetwork/ermis-shared-ios", exact: "1.0.0"),
        .package(path: "../ermis-shared-ios"),
        .package(path: "../open-mls-ios")
    ],
    targets: [
        .target(
            name: "ErmisChat",
            dependencies: [
                "open-mls-ios",
                .product(name: "ErmisShared", package: "ermis-shared-ios"),
                .product(name: "EventSource", package: "EventSource"),
            ],
            exclude: ["Info.plist"],
            resources: [.copy("Database/ErmisChatModel.xcdatamodeld")]
        ),
        .target(
            name: "ErmisChatUI",
            dependencies: [
                "ErmisChat",
                .product(name: "ErmisShared", package: "ermis-shared-ios"),
                .product(name: "ErmisSharedUI", package: "ermis-shared-ios"),
                .product(name: "Lottie", package: "lottie-spm")
            ],
            exclude: ["Info.plist", "Generated/L10n_template.stencil"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ErmisChatTests",
            dependencies: ["ErmisChat", "open-mls-ios"]
        ),
//        .target(
//            name: "ErmisWalletAuth",
//            dependencies: [
//                "ErmisChat",
//                .product(name: "ErmisShared", package: "ermis-shared-ios"),
////                .product(name: "ReownAppKit", package: "reown-swift"),
////                .product(name: "WalletConnect", package: "reown-swift"),
////                .product(name: "Web3", package: "Web3.swift"),
//                .product(name: "Starscream", package: "Starscream")
//            ],
//            exclude: ["Info.plist"]
//        ),
    ]
)
//#if swift(>=5.6)
//package.dependencies.append(
//    .package(name: "SwiftDocCPlugin", url: "https://github.com/apple/swift-docc-plugin", .exact("1.0.0"))
//)
//#endif
