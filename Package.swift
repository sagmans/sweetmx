// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SweetMX",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "SweetMX", targets: ["SweetMX"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.19.6"),
    ],
    targets: [
        .executableTarget(
            name: "SweetMX",
            path: "Sources/SweetMX",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
            ]
        ),
        // The window manager model: state, reducer and layout math. It imports Foundation only, so
        // `wm-sim` can check every layout rule with no real window and no permission.
        .target(
            name: "WMCore",
            path: "Sources/WMCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Real windows, keys and touches. Apart from WMCore so the model never links AppKit, and
        // without default main-actor isolation: Accessibility calls must run off the main actor,
        // so a hung app cannot freeze app search or the clipboard history.
        .target(
            name: "WMPlatform",
            dependencies: ["WMCore"],
            path: "Sources/WMPlatform",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // Development tools, not products: `make bundle` copies only the SweetMX executable and
        // refuses a bundle that holds anything else, so neither tool can ship.
        .executableTarget(
            name: "wm-sim",
            dependencies: ["WMCore"],
            path: "Sources/wm-sim",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // No WMCore dependency on purpose: the control client speaks to the app over a socket and
        // must not be able to run the model, or reach a window, by itself.
        .executableTarget(
            name: "wmctl",
            path: "Sources/wmctl",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "SweetMXTests",
            dependencies: [
                "SweetMX",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/SweetMXTests",
            exclude: ["__Snapshots__"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // XCTestCase initializers are nonisolated, so default main-actor isolation cannot
                // apply here; test classes opt in with an explicit @MainActor instead.
            ]
        ),
        // The performance gate. Its own target so `swift test` (debug) keeps the functional suite
        // fast, and `make benchmark` can build this one with optimizations, as the shipped app is.
        .testTarget(
            name: "SweetMXBenchmarks",
            dependencies: ["SweetMX", "WMCore"],
            path: "Tests/SweetMXBenchmarks",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
