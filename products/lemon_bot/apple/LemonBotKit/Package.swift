// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LemonBotKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LemonBotKit", targets: ["LemonBotKit"]),
        .library(name: "LemonBotUI", targets: ["LemonBotUI"])
    ],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.13.0")],
    targets: [
        .target(name: "LemonBotKit", path: "Sources/LemonBotKit"),
        .target(name: "LemonBotUI", dependencies: ["LemonBotKit", .product(name: "SwiftTerm", package: "SwiftTerm")], path: "Sources/LemonBotUI"),
        .testTarget(name: "LemonBotKitTests", dependencies: ["LemonBotKit"], path: "Tests/LemonBotKitTests")
    ],
    swiftLanguageVersions: [.v5]
)
