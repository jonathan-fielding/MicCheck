// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MicDeck",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MicDeck", targets: ["MicDeck"]),
        .executable(name: "ngmic", targets: ["ngmic"]),
    ],
    targets: [
        .target(name: "MicKit", linkerSettings: [
            .linkedFramework("IOKit"),
            .linkedFramework("IOUSBHost"),
            .linkedFramework("CoreAudio"),
            .linkedFramework("CoreFoundation"),
        ]),
        .executableTarget(name: "MicDeck", dependencies: ["MicKit"]),
        .executableTarget(name: "ngmic", dependencies: ["MicKit"]),
        .testTarget(name: "MicKitTests", dependencies: ["MicKit"]),
    ],
    swiftLanguageModes: [.v5]
)
