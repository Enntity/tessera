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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.9.0")
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
            dependencies: ["TesseraKit", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .executableTarget(
            name: "TesseraMac",
            dependencies: ["TesseraKit", "TesseraHost", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(name: "TesseraKitTests", dependencies: ["TesseraKit", "TesseraHost"])
    ],
    swiftLanguageModes: [.v5]
)
