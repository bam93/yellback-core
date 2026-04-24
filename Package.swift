// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "YellBackCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "YellBackCore", targets: ["YellBackCore"]),
        .executable(name: "yellback", targets: ["yellback-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams", .upToNextMajor(from: "5.0.0")),
    ],
    targets: [
        .target(
            name: "YellBackCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .executableTarget(
            name: "yellback-cli",
            dependencies: ["YellBackCore"]
        ),
        .testTarget(
            name: "YellBackCoreTests",
            dependencies: ["YellBackCore"]
        ),
    ]
)
