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
    dependencies: [
        // 暗号プリミティブ (X25519 / ChaCha20-Poly1305 / SHA-256 / HMAC)。
        // Apple 製。macOS では CryptoKit、Windows / Linux では BoringSSL を使う。
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
    ],
    targets: [
        .target(
            name: "RDCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            linkerSettings: [
                .linkedLibrary("Ws2_32", .when(platforms: [.windows])),
                .linkedLibrary("Crypt32", .when(platforms: [.windows])),
                .linkedLibrary("Winhttp", .when(platforms: [.windows])),
                .linkedFramework("Security", .when(platforms: [.macOS])),
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
