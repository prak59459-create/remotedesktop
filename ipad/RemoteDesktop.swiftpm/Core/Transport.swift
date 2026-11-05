// 自動生成: scripts/sync-ipad.sh が Sources/RDCore/Transport.swift からコピー。直接編集しないでください。
import Foundation

/// 暗号化チャネル (SecureStream) の下に敷く通信路。TCP 直結と中継サーバー経由を同じように扱う。
/// ここを流れるのは Noise の暗号文だけなので、通信路そのものは信用しない前提。
public protocol Transport: ByteStream {
    /// ログ用の相手の表記
    var peerDescription: String { get }
    /// レート制限のキー
    var peerIP: String { get }
    /// 相手が LAN 内 (プライベート IP) から直接つないでいるか。
    /// 中継経由は常に false。新しい端末の登録 (ペアリング) を LAN 内に限定するのに使う。
    var isLocalNetwork: Bool { get }
    /// 受信タイムアウト (秒)。0 で無効
    func setReceiveTimeout(_ seconds: Double)
}

extension TCPConnection: Transport {
    public var isLocalNetwork: Bool { isPrivateIPv4(peerIP) }
}

/// RFC 1918 のプライベートアドレス、ループバック、リンクローカルか
public func isPrivateIPv4(_ ip: String) -> Bool {
    let parts = ip.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4 else { return false }
    switch (parts[0], parts[1]) {
    case (10, _), (127, _): return true
    case (172, 16 ... 31): return true
    case (192, 168): return true
    case (169, 254): return true
    default: return false
    }
}
