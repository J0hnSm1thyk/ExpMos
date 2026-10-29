// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExpMos",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ExpMos", targets: ["ExpMos"])],
    targets: [
        .target(name: "ExplorerCore"),
        .executableTarget(name: "ExpMos", dependencies: ["ExplorerCore"]),
        .executableTarget(name: "ExplorerCoreChecks", dependencies: ["ExplorerCore"], path: "Tests/ExplorerCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
