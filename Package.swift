// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kcsecret",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "kcsecret", targets: ["kcsecret"]),
    ],
    targets: [
        // Pure logic with no system dependencies: .env parsing, .envrc editing, naming, config.
        .target(name: "KCSecretCore"),
        // The only code that touches the file-based keychain APIs. Apple deprecated them, but they
        // remain the only way to give an item an access list without a signed app and entitlements,
        // so their deprecation warnings are silenced here and nowhere else.
        .target(
            name: "KCSecretKeychain",
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])]
        ),
        .executableTarget(name: "kcsecret", dependencies: ["KCSecretCore", "KCSecretKeychain"]),
        .testTarget(name: "KCSecretCoreTests", dependencies: ["KCSecretCore"]),
    ],
    swiftLanguageModes: [.v5]
)
