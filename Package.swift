// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SimMonkeyKit",
    platforms: [.iOS(.v15), .macOS(.v12), .tvOS(.v15)],
    products: [
        .library(name: "SimMonkeyKit", targets: ["SimMonkeyKit"])
    ],
    targets: [
        .target(name: "SimMonkeyKit")
    ]
)
