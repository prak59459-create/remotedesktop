// swift-tools-version: 5.9

// iPad の Swift Playgrounds (または Xcode) で開くアプリです。
// Core/ は ../../Sources/RDCore のコピー (scripts/sync-ipad.sh で更新)。直接編集しないでください。

import AppleProductTypes
import PackageDescription

let package = Package(
    name: "RemoteDesktop",
    platforms: [
        .iOS("16.0"),
    ],
    products: [
        .iOSApplication(
            name: "RemoteDesktop",
            targets: ["AppModule"],
            bundleIdentifier: "local.remotedesktop.viewer",
            displayVersion: "1.0",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .desktopcomputer),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [
                .pad,
                .phone,
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .landscapeRight,
                .landscapeLeft,
                .portraitUpsideDown(.when(deviceFamilies: [.pad])),
            ],
            capabilities: [
                .localNetwork(purposeString: "同じ Wi-Fi にある Windows PC に接続するために使います。"),
            ]
        ),
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        ),
    ]
)
