// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FanControl", targets: ["FanControl"]),
    ],
    dependencies: [
        // Swift Testing open-source package — required because the Testing.framework
        // bundled with Command Line Tools lacks the runtime (lib_TestingInterop.dylib)
        // that only ships with Xcode.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.10.0"),
    ],
    targets: [
        // Hardware-independent SMC rules shared by the app and privileged helper.
        .target(
            name: "FanControlCore",
            path: "Sources/FanControlCore"
        ),

        // Core library — contains all SMC, Model, and UI code.
        // Separated from the executable so the test target can depend on it.
        .target(
            name: "FanControlKit",
            dependencies: ["FanControlCore"],
            path: "Sources/FanControlKit",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),

        // Executable — entry point only.
        .executableTarget(
            name: "FanControl",
            dependencies: ["FanControlKit"],
            path: "Sources/FanControl",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),

        // Privileged helper — runs via sudo to write SMC fan keys.
        .executableTarget(
            name: "FanHelper",
            dependencies: ["FanControlCore"],
            path: "Sources/FanHelper",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),

        // Tests — pure-Swift logic only; no SMC hardware required.
        .testTarget(
            name: "FanControlKitTests",
            dependencies: [
                "FanControlCore",
                "FanControlKit",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/FanControlKitTests"
        ),
    ]
)
