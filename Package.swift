// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RexDrop",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "RexDrop", targets: ["RexDrop"])],
    targets: [
        .executableTarget(name: "RexDrop"),
        .testTarget(name: "RexDropTests", dependencies: ["RexDrop"]),
        .testTarget(name: "RexDropIntegrationTests", dependencies: ["RexDrop"], path: "Tests/Integration")
    ],
    swiftLanguageModes: [.v5]
)
