// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Jarvis",
            path: "Sources/Jarvis",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "JarvisTests",
            dependencies: ["Jarvis"],
            path: "Tests/JarvisTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
