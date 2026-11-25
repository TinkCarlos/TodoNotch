// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TodoNotch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TodoNotchCore", targets: ["TodoNotchCore"]),
        .executable(name: "TodoNotch", targets: ["TodoNotch"])
    ],
    targets: [
        .target(
            name: "TodoNotchCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "TodoNotch",
            dependencies: ["TodoNotchCore"]
        ),
        .testTarget(
            name: "TodoNotchTests",
            dependencies: ["TodoNotchCore"]
        )
    ]
)
