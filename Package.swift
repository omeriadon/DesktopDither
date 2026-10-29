// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DesktopGlow",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DesktopGlow", targets: ["DesktopGlow"])
    ],
    targets: [
        .executableTarget(name: "DesktopGlow"),
        .testTarget(name: "DesktopGlowTests", dependencies: ["DesktopGlow"])
    ]
)
