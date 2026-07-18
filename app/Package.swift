// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pill",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MBShim", path: "Sources/MBShim"),
        .executableTarget(name: "Pill", dependencies: ["MBShim"], path: "Sources/Pill")
    ]
)
