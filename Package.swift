// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Networking",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Networking", targets: ["Networking"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
    ],
    targets: [
        .target(name: "Diagnostics"),
        .target(name: "Networking"),
        .testTarget(name: "NetworkingTests", dependencies: ["Networking"]),
    ],
    swiftLanguageModes: [.v5]
)
