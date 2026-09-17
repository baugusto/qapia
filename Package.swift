// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Qapia",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Qapia", targets: ["Qapia"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "QapiaCore",
            dependencies: ["WhisperCpp", "CoreAudioTapSupport"],
            path: ".",
            exclude: [
                "App", "AppStore", "Assets", "Build", "Docs", "Scripts", "Tests", "CHANGELOG.md", "Package.swift", "README.md", "LICENSE",
                "Services/AudioTapSupport"
            ]
        ),
        .target(
            name: "CoreAudioTapSupport",
            path: "Services/AudioTapSupport",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .executableTarget(
            name: "Qapia",
            dependencies: ["QapiaCore"],
            path: "App",
            exclude: ["Info.plist", "QAPia.entitlements"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "QapiaTests",
            dependencies: ["QapiaCore"],
            path: "Tests",
            exclude: ["Fixtures"]
        ),
        .binaryTarget(
            name: "WhisperCpp",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b4938/whisper-b4938-xcframework.zip",
            checksum: "dcc6cdc6d6902d11893434ceda70c23a2a64450f65a1b570035c9908988dfedd"
        )
    ]
)
