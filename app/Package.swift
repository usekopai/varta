// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Varta",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Local Whisper speech-to-text on the Neural Engine (Core ML). The model weights are
        // downloaded once to ~/.varta/models by run.sh or the Setup window, not stored in the repo.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", .upToNextMinor(from: "1.1.0")),
    ],
    targets: [
        // Everything that decides and acts: router, executor, accessibility, computer use, speech.
        .target(
            name: "VartaCore",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")],
            path: "Sources/VartaCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // The notch app.
        .executableTarget(
            name: "Varta",
            dependencies: ["VartaCore"],
            path: "Sources/Varta",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Route or run a command from the terminal, replay the fixture, and score the eval.
        .executableTarget(
            name: "varta-cli",
            dependencies: ["VartaCore", .product(name: "WhisperKit", package: "argmax-oss-swift")],
            path: "Sources/varta-cli",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Unit checks. The Command Line Tools ship neither XCTest nor Testing, so this is a plain executable.
        .executableTarget(
            name: "varta-selftest",
            dependencies: ["VartaCore"],
            path: "Sources/varta-selftest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
