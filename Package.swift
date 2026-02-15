// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceBarDictate",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "VoiceBarDictate",
            targets: ["VoiceBarDictate"]
        )
    ],
    targets: [
        .executableTarget(
            name: "VoiceBarDictate",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ]
)
