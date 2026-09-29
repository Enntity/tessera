// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tessera",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "TesseraKit", targets: ["TesseraKit"]),
        .library(name: "TesseraHost", targets: ["TesseraHost"]),
        .executable(name: "Tessera", targets: ["TesseraMac"])
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
        // macOS-only: owns processes, watches agent apps, places windows, serves remotes.
        .target(
            name: "TesseraHost",
            dependencies: ["TesseraKit", .product(name: "SwiftTerm", package: "SwiftTerm"),
                           .product(name: "libzstd", package: "zstd")]
        ),
        .executableTarget(
            name: "TesseraMac",
            dependencies: ["TesseraKit", "TesseraHost", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(name: "TesseraKitTests", dependencies: ["TesseraKit", "TesseraHost",
                                                            .product(name: "libzstd", package: "zstd")])
    ],
    swiftLanguageModes: [.v5]
)
