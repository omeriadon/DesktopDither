// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DesktopDither",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "DesktopDither", targets: ["DesktopDither"])
    ],
    targets: [
        .executableTarget(name: "DesktopDither"),
        .testTarget(name: "DesktopDitherTests", dependencies: ["DesktopDither"])
    ]
)
