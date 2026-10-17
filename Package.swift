// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tessera",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "TesseraKit", targets: ["TesseraKit"]),
        .library(name: "TesseraHost", targets: ["TesseraHost"]),
        .executable(name: "Tessera", targets: ["TesseraMac"]),
        .executable(name: "tessera-cli", targets: ["TesseraCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.9.0"),
        // DeepSeek Harness (dsh) stores sessions as zstd-compressed JSONL.
        .package(url: "https://github.com/facebook/zstd", exact: "1.5.7")
    ],
    targets: [
        // Cross-platform core shared by the macOS host and the iOS client.
        .target(
            name: "TesseraKit",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        // Where Tessera's agent API is found; shared by the app and the `tessera` command, which
        // stays Foundation-only.
        .target(name: "TesseraAPI"),
        // macOS-only: owns processes, watches agent apps, places windows, serves remotes.
        .target(
            name: "TesseraHost",
            dependencies: ["TesseraKit", "TesseraAPI", .product(name: "SwiftTerm", package: "SwiftTerm"),
                           .product(name: "libzstd", package: "zstd")]
        ),
        // `tessera`: agents' command line and stdio MCP server, talking to the running app.
        .executableTarget(name: "TesseraCLI", dependencies: ["TesseraAPI"]),
        .executableTarget(
            name: "TesseraMac",
            dependencies: ["TesseraKit", "TesseraHost", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(name: "TesseraKitTests", dependencies: ["TesseraKit", "TesseraHost", "TesseraAPI",
                                                            .product(name: "libzstd", package: "zstd")])
    ],
    swiftLanguageModes: [.v5]
)
