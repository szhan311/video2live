// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "video2live",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "video2live",
            path: "Sources/LiveConverter",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AVKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Photos"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("ImageIO"),
                .linkedFramework("AppKit")
            ]
        )
    ]
)
