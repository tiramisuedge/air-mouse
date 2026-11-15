// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AirTouch",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure gesture logic: hand model, pose classifier, smoothing, gesture state machine.
        .target(name: "AirTouchCore", path: "Sources/AirTouchCore"),
        // The macOS menu bar app: camera, Vision hand tracking, input events, UI.
        .executableTarget(
            name: "AirTouch",
            dependencies: ["AirTouchCore"],
            path: "Sources/AirTouch"
        ),
        .testTarget(
            name: "AirTouchCoreTests",
            dependencies: ["AirTouchCore"],
            path: "Tests/AirTouchCoreTests"
        ),
    ]
)
