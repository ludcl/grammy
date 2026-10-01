// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Grammy",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Grammy", targets: ["Grammy"])],
    targets: [
        .target(name: "GrammyCore"),
        .executableTarget(name: "Grammy", dependencies: ["GrammyCore"]),
        .testTarget(name: "GrammyTests", dependencies: ["Grammy", "GrammyCore"]),
        .testTarget(name: "GrammyCoreTests", dependencies: ["GrammyCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
