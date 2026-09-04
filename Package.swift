// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PaintMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Paint", targets: ["PaintMac"])
    ],
    targets: [
        .executableTarget(
            name: "PaintMac",
            path: "Sources/PaintMac"
        )
    ]
)
