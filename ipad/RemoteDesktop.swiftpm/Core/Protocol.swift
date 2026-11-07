// 自動生成: scripts/sync-ipad.sh が Sources/RDCore/Protocol.swift からコピー。直接編集しないでください。
import Foundation

/// 既定のポート番号
public let defaultPort: UInt16 = 5999

/// hello メッセージ先頭のマジック
public let protocolMagic: UInt32 = 0x3244_5253 // "SRD2" (暗号化必須版)

/// メッセージ = [type: u8][length: u32 LE][payload: length bytes]
/// (常に SecureStream = Noise 暗号化チャネルの上で送る)
public enum MessageType: UInt8 {
    // ホスト → ビューア
    case hello = 1            // magic u32, width u32, height u32
    case frame = 2            // FrameEncoder の出力 (変更タイルの集合)
    case frame2 = 3           // FrameEncoder の出力 (v2: タイルごとに形式つき。capabilities で対応を伝えたビューアにだけ送る)

    // ビューア → ホスト
    case frameAck = 10        // フレームを処理し終えた (フロー制御)
    case mouseMove = 11       // x i32, y i32 (フレーム座標)
    case mouseButton = 12     // button u8, down u8
    case mouseWheel = 13      // dx i32, dy i32 (Windows の WHEEL_DELTA=120 単位)
    case key = 14             // code u16, flags u8
    case requestKeyframe = 15 // 全画面を送り直してもらう
    case text = 16            // 文字列入力 (UTF-8)。ソフトウェアキーボードや IME の確定文字
    case capabilities = 17    // flags u32 (ViewerCapability)。古いホストは知らない種類として無視する

    // 認証 (暗号化チャネル確立後、画面配信の前)
    case authRequest = 20     // AuthRequest
    case authResult = 21      // AuthResult
}

public enum MouseButton: UInt8 {
    case left = 0, right = 1, middle = 2, x1 = 3, x2 = 4
}

/// key メッセージの flags
public enum KeyFlag {
    public static let down: UInt8 = 0x01
    /// code が PC/AT スキャンコードではなく Windows の仮想キーコードであることを示す
    public static let virtualKey: UInt8 = 0x02
}

/// key メッセージの code にスキャンコードを入れるとき、拡張キー (E0 prefix) はこのビットを立てる
public let extendedScancodeFlag: UInt16 = 0xE000

public struct Hello: Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public func encode() -> [UInt8] {
        var w = ByteWriter(capacity: 12)
        w.u32(protocolMagic)
        w.u32(UInt32(width))
        w.u32(UInt32(height))
        return w.bytes
    }

    public static func decode(_ payload: [UInt8]) throws -> Hello {
        var r = ByteReader(payload)
        guard try r.u32() == protocolMagic else { throw ProtocolError.invalid("magic が一致しません") }
        let w = Int(try r.u32()), h = Int(try r.u32())
        // 悪意あるホストに巨大な画面バッファ (16384² × 4 = 1GiB) を確保させないよう、8K (7680x4320) 相当までに制限
        guard w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 7680 * 4320 else {
            throw ProtocolError.invalid("画面サイズ \(w)x\(h)")
        }
        return Hello(width: w, height: h)
    }
}

/// ビューアからホストへ送るイベント
public enum ClientEvent: Equatable {
    case frameAck
    case requestKeyframe
    case mouseMove(x: Int32, y: Int32)
    case mouseButton(MouseButton, down: Bool)
    case mouseWheel(dx: Int32, dy: Int32)
    case key(code: UInt16, down: Bool, virtualKey: Bool)
    case text(String)
    case capabilities(UInt32)

    public static let maxTextBytes = 1024

    public func encode() -> (MessageType, [UInt8]) {
        var w = ByteWriter(capacity: 8)
        switch self {
        case .frameAck:
            return (.frameAck, [])
        case .requestKeyframe:
            return (.requestKeyframe, [])
        case let .mouseMove(x, y):
            w.i32(x); w.i32(y)
            return (.mouseMove, w.bytes)
        case let .mouseButton(b, down):
            w.u8(b.rawValue); w.u8(down ? 1 : 0)
            return (.mouseButton, w.bytes)
        case let .mouseWheel(dx, dy):
            w.i32(dx); w.i32(dy)
            return (.mouseWheel, w.bytes)
        case let .key(code, down, vk):
            w.u16(code)
            w.u8((down ? KeyFlag.down : 0) | (vk ? KeyFlag.virtualKey : 0))
            return (.key, w.bytes)
        case let .text(s):
            return (.text, Array(Array(s.utf8).prefix(Self.maxTextBytes)))
        case let .capabilities(flags):
            w.u32(flags)
            return (.capabilities, w.bytes)
        }
    }

    public static func decode(type: UInt8, payload: [UInt8]) throws -> ClientEvent? {
        guard let t = MessageType(rawValue: type) else { return nil }
        var r = ByteReader(payload)
        switch t {
        case .frameAck: return .frameAck
        case .requestKeyframe: return .requestKeyframe
        case .mouseMove: return .mouseMove(x: try r.i32(), y: try r.i32())
        case .mouseButton:
            guard let b = MouseButton(rawValue: try r.u8()) else { return nil }
            return .mouseButton(b, down: try r.u8() != 0)
        case .mouseWheel: return .mouseWheel(dx: try r.i32(), dy: try r.i32())
        case .key:
            let code = try r.u16()
            let flags = try r.u8()
            return .key(code: code, down: flags & KeyFlag.down != 0, virtualKey: flags & KeyFlag.virtualKey != 0)
        case .text:
            guard payload.count <= maxTextBytes else { return nil }
            return .text(String(decoding: payload, as: UTF8.self))
        case .capabilities: return .capabilities(try r.u32())
        case .hello, .frame, .frame2, .authRequest, .authResult: return nil
        }
    }
}

/// ByteStream 上でメッセージを送受信する。send はスレッドセーフ。
public final class MessageChannel {
    public let stream: ByteStream
    private let sendLock = NSLock()
    public let maxPayload: Int

    public init(_ stream: ByteStream, maxPayload: Int = 64 * 1024 * 1024) {
        self.stream = stream
        self.maxPayload = maxPayload
    }

    public func send(_ type: MessageType, _ payload: [UInt8]) throws {
        var msg = ByteWriter(capacity: 5 + payload.count)
        msg.u8(type.rawValue)
        msg.u32(UInt32(payload.count))
        msg.bytes.append(contentsOf: payload)
        sendLock.lock()
        defer { sendLock.unlock() }
        try stream.sendAll(msg.bytes)
    }

    public func send(_ event: ClientEvent) throws {
        let (t, p) = event.encode()
        try send(t, p)
    }

    /// 1 メッセージ受信する (type は未知の値の可能性もあるので生の u8 で返す)
    public func receive() throws -> (type: UInt8, payload: [UInt8]) {
        var r = ByteReader(try stream.receive(exactly: 5))
        let type = try r.u8()
        let len = Int(try r.u32())
        guard len <= maxPayload else { throw ProtocolError.invalid("payload が大きすぎます (\(len))") }
        let payload = len > 0 ? try stream.receive(exactly: len) : []
        return (type, payload)
    }

    public func close() { stream.close() }
}
