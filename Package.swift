// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RemoteDesktop",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(name: "RDCore", targets: ["RDCore"]),
        // Windows で動かす「接続される側」(画面キャプチャ + 入力注入)
        .executable(name: "RDHost", targets: ["RDHost"]),
        // macOS で動かす「接続する側」(ビューア)
        .executable(name: "RDViewer", targets: ["RDViewer"]),
    ],
    targets: [
        .target(
            name: "RDCore",
            linkerSettings: [
                .linkedLibrary("Ws2_32", .when(platforms: [.windows])),
            ]
        ),
        .executableTarget(
            name: "RDHost",
            dependencies: ["RDCore"],
            linkerSettings: [
                .linkedLibrary("User32", .when(platforms: [.windows])),
                .linkedLibrary("Gdi32", .when(platforms: [.windows])),
                .linkedLibrary("Ws2_32", .when(platforms: [.windows])),
            ]
        ),
        .executableTarget(
            name: "RDViewer",
            dependencies: ["RDCore"]
        ),
        .testTarget(
            name: "RDCoreTests",
            dependencies: ["RDCore"]
        ),
    ]
)
