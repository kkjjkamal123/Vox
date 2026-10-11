// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vox",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Vox",
            path: "Sources/Vox",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Osize"])],
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
