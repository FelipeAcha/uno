// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FindMyBLERadar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RadarCore", targets: ["RadarCore"]),
        .executable(name: "FindMyBLERadar", targets: ["FindMyBLERadar"])
    ],
    targets: [
        .target(
            name: "RadarCore",
            path: "Sources/RadarCore"
        ),
        .executableTarget(
            name: "FindMyBLERadar",
            dependencies: ["RadarCore"],
            path: "Sources/FindMyBLERadar"
        ),
        .testTarget(
            name: "RadarCoreTests",
            dependencies: ["RadarCore"],
            path: "Tests/RadarCoreTests"
        )
    ]
)
