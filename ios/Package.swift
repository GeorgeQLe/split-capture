// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SplitCaptureCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SplitCapture", targets: ["SplitCapture"])
    ],
    targets: [
        .target(
            name: "SplitCapture",
            path: "SplitCapture",
            exclude: [
                "Assets.xcassets",
                "ContentView.swift",
                "DirectCaptureBackend.swift",
                "Info.plist",
                "Info-iOS27.plist",
                "LoomCompositor.swift",
                "PhotosLibrarySaver.swift",
                "PresenterTakeController.swift",
                "PresenterTakeView.swift",
                "ScreenCaptureController.swift",
                "SplitCapture.entitlements",
                "SplitCaptureApp.swift"
            ],
            sources: [
                "Models.swift",
                "RecorderViewModel.swift",
                "RecordingStore.swift",
                "ScreenCaptureControlling.swift"
            ]
        ),
        .testTarget(
            name: "SplitCaptureTests",
            dependencies: ["SplitCapture"],
            path: "SplitCaptureTests",
            sources: [
                "RecorderViewModelTests.swift",
                "RecordingStoreTests.swift"
            ]
        )
    ]
)
