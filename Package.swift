// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "VoiceBarDictate",
    platforms: [
        .macOS(.v14)
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
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Speech")
            ]
        ),
        .testTarget(
            name: "VoiceBarDictateTests",
            dependencies: ["VoiceBarDictate"]
        )
    ]
)
