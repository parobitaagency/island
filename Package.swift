// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Island",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Moves windows into the SkyLight space above the lock screen.
        .package(url: "https://github.com/Lakr233/SkyLightWindow", exact: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Island",
            dependencies: ["SkyLightWindow"],
            path: "Sources/Island",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
