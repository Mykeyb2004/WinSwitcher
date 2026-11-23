// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WinSwitcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "WinSwitcherCore", targets: ["WinSwitcherCore"]),
        .executable(name: "WinSwitcher", targets: ["WinSwitcher"])
    ],
    targets: [
        .target(
            name: "WinSwitcherCore",
            path: "Sources/WinSwitcherCore"
        ),
        .executableTarget(
            name: "WinSwitcher",
            dependencies: ["WinSwitcherCore"],
            path: "Sources/WinSwitcher",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "WinSwitcherTests",
            dependencies: ["WinSwitcherCore"],
            path: "Tests/WinSwitcherTests"
        )
    ]
)
