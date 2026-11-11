// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Swarf",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CAMCore", targets: ["CAMCore"]),
        .executable(name: "Swarf", targets: ["SwarfApp"]),
        .executable(name: "swarf-cli", targets: ["swarf-cli"]),
    ],
    targets: [
        .target(
            name: "CAMCore",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        ),
        .executableTarget(
            name: "SwarfApp",
            dependencies: ["CAMCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "swarf-cli", dependencies: ["CAMCore"]),
        .testTarget(name: "CAMCoreTests", dependencies: ["CAMCore"]),
    ]
)
