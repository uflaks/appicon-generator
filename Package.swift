// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppIconGenerator",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AppIconCore", targets: ["AppIconCore"])
    ],
    targets: [
        .target(name: "AppIconCore"),
        .testTarget(name: "AppIconCoreTests", dependencies: ["AppIconCore"]),
    ]
)
