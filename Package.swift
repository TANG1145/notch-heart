// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchHeart",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "NotchHeart", targets: ["NotchHeart"])],
    targets: [
        .target(name: "HeartCore"),
        .executableTarget(name: "NotchHeart", dependencies: ["HeartCore"]),
        .executableTarget(name: "HeartCoreChecks", dependencies: ["HeartCore"], path: "Tests/HeartCoreTests")
    ]
)
