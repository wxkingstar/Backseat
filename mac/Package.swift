// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "backseat",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "backseat", path: "Sources/backseat")
    ]
)
