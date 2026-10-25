// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Varredor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Varredor", targets: ["Varredor"])
    ],
    targets: [
        .executableTarget(
            name: "Varredor",
            path: "Sources/Varredor"
        )
    ]
)
