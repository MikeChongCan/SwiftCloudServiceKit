// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CloudServiceKit",
    platforms: [
        .iOS(.v13),
        .tvOS(.v14),
        .macOS(.v10_15)
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "CloudServiceKit",
            targets: ["CloudServiceKit"]),
        .executable(
            name: "CloudServiceKitExampleCLI",
            targets: ["CloudServiceKitExampleCLI"])
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/OAuthSwift/OAuthSwift", from: "2.2.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2")
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "CloudServiceKit",
            dependencies: ["OAuthSwift"],
            path: "Sources",
            exclude: ["CloudServiceKitExampleCLI"]),
        .executableTarget(
            name: "CloudServiceKitExampleCLI",
            dependencies: [
                "CloudServiceKit",
                "KeychainAccess"
            ],
            path: "Example/CLI"),
        .testTarget(
            name: "CloudServiceKitTests",
            dependencies: ["CloudServiceKit"],
            path: "Tests/CloudServiceKitTests")
    ]
)
