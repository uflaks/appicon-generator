// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppIconGenerator",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AppIconCore", targets: ["AppIconCore"]),
        .executable(name: "appicon", targets: ["appicon"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
    ],
    targets: [
        .target(name: "AppIconCore"),
        .executableTarget(
            name: "appicon",
            dependencies: [
                "AppIconCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "AppIconCoreTests", dependencies: ["AppIconCore"]),
    ]
)
