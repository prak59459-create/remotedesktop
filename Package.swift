// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RemoteDesktop",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(name: "RDCore", targets: ["RDCore"]),
        // Windows で動かす「接続される側」(画面キャプチャ + 入力注入)。コマンドライン版
        .executable(name: "RDHost", targets: ["RDHost"]),
        // 同じく GUI 版 (ウィンドウとタスクトレイ)
        .executable(name: "RemoteDesktopHost", targets: ["RemoteDesktopHost"]),
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
            name: "CWinSys",
            linkerSettings: [
                .linkedLibrary("Winhttp", .when(platforms: [.windows])),
                .linkedLibrary("ncrypt", .when(platforms: [.windows])),
            ]
        ),
        .target(
            name: "RDCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .target(name: "CWinSys", condition: .when(platforms: [.windows])),
            ],
            linkerSettings: [
                .linkedLibrary("Ws2_32", .when(platforms: [.windows])),
                .linkedLibrary("Crypt32", .when(platforms: [.windows])),
                .linkedLibrary("Winhttp", .when(platforms: [.windows])),
                .linkedLibrary("ncrypt", .when(platforms: [.windows])),
                .linkedFramework("Security", .when(platforms: [.macOS])),
                .linkedFramework("LocalAuthentication", .when(platforms: [.macOS])),
            ]
        ),
        // ホスト (接続される側) の本体。コマンドライン版と GUI 版で共有する
        .target(
            name: "RDHostKit",
            dependencies: [
                "RDCore",
                .target(name: "CWinSys", condition: .when(platforms: [.windows])),
            ],
            linkerSettings: [
                .linkedLibrary("User32", .when(platforms: [.windows])),
                .linkedLibrary("Gdi32", .when(platforms: [.windows])),
                .linkedLibrary("Ws2_32", .when(platforms: [.windows])),
                .linkedLibrary("Advapi32", .when(platforms: [.windows])),
            ]
        ),
        // コマンドライン版 (RDHost.exe)
        .executableTarget(
            name: "RDHost",
            dependencies: ["RDHostKit", "RDCore"]
        ),
        // GUI 版 (RemoteDesktopHost.exe)。Windows 以外では「Windows 専用」と表示するだけ
        .executableTarget(
            name: "RemoteDesktopHost",
            dependencies: ["RDHostKit", "RDCore"],
            path: "Sources/RDHostApp",
            exclude: ["AppIcon.ico"],
            linkerSettings: [
                .linkedLibrary("User32", .when(platforms: [.windows])),
                .linkedLibrary("Gdi32", .when(platforms: [.windows])),
                .linkedLibrary("Shell32", .when(platforms: [.windows])),
                .linkedLibrary("Advapi32", .when(platforms: [.windows])),
                .linkedLibrary("Kernel32", .when(platforms: [.windows])),
                // コンソール窓を出さない GUI アプリとしてリンクする (入口は通常の main)
                .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
                             .when(platforms: [.windows])),
            ]
        ),
        .executableTarget(
            name: "RDViewer",
            dependencies: ["RDCore"]
        ),
        // libFuzzer 用 (scripts/fuzz.sh)。通常のビルドでは何もしない実行ファイル
        .target(name: "CFuzzMain"),
        .executableTarget(
            name: "RDFuzz",
            dependencies: [
                "RDCore",
                .target(name: "CFuzzMain", condition: .when(platforms: [.linux])),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "RDCoreTests",
            dependencies: ["RDCore"]
        ),
        .testTarget(
            name: "RDHostKitTests",
            dependencies: ["RDHostKit", "RDCore"]
        ),
    ]
)
