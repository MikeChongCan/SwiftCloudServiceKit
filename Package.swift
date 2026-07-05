// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CloudServiceKit",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CloudServiceKit",
            targets: ["CloudServiceKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/OAuthSwift/OAuthSwift", from: "2.2.0"),
    ],
    targets: [
        .target(
            name: "CloudServiceKit",
            dependencies: ["OAuthSwift"],
            path: "Sources"),
        .testTarget(
            name: "CloudServiceKitTests",
            dependencies: ["CloudServiceKit"],
            path: "Tests/CloudServiceKitTests")
    ]
)
