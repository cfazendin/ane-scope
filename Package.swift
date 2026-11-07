// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ane-scope",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "ane-scope", targets: ["ANEScope"])
    ],
    targets: [
        .executableTarget(
            name: "ANEScope",
            path: "Sources/ANEScope",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("IOReport"),
                .linkedFramework("CoreML"),
                .linkedFramework("CoreAI"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("Metal"),
                .linkedFramework("IOKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Charts")
            ]
        )
    ]
)
