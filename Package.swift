// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Commonplace",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Commonplace", path: "Sources/Commonplace")
    ]
)
