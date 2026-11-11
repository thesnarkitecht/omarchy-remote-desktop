// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OmarchyRemote",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "RFB", dependencies: ["CZlib"]),
        .executableTarget(name: "OmarchyRemote", dependencies: ["RFB"]),
        .executableTarget(name: "rfbcheck", dependencies: ["RFB"]),
    ]
)
