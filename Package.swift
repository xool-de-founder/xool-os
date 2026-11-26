// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "XoolOS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "XoolOS", targets: ["XoolOS"]),
    ],
    targets: [
        .executableTarget(
            name: "XoolOS",
            path: "Sources/XoolOS",
            // The interface is main-thread by nature; Swift 6's strict
            // isolation buys nothing here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Test-only: keeps every window the unit tests make off the screen.
        .target(
            name: "NoWindows",
            path: "Tests/NoWindows",
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(
            name: "XoolOSTests",
            dependencies: ["XoolOS", "NoWindows"],
            path: "Tests/XoolOSTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
