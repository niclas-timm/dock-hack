// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DockHack",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DockHack",
            path: "Sources/DockHack"
        )
    ]
)
