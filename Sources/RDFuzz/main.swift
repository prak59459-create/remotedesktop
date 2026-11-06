// libFuzzer 用のファズターゲット。scripts/fuzz.sh でビルド・実行する。
//
// 通常の swift build では何もしない実行ファイルになる。
// -sanitize=fuzzer -parse-as-library でビルドすると、libFuzzer が下の関数を何百万回も呼び、
// 攻撃者が送れるデータを解析する部分 (認証前・認証後とも) にクラッシュやメモリ破壊が無いかを探す。
// 最初の 1 バイトで対象を選ぶ。

import RDCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// 何度呼ばれても同じ鍵 (結果を再現できるように)
private let hostKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: [UInt8](repeating: 0x42, count: 32))
private let viewerKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: [UInt8](repeating: 0x24, count: 32))

@_cdecl("LLVMFuzzerTestOneInput")
public func rdFuzz(_ start: UnsafePointer<UInt8>, _ count: Int) -> CInt {
    guard count > 0 else { return 0 }
    let selector = start[0]
    let data = Array(UnsafeBufferPointer(start: start + 1, count: count - 1))
    fuzzOne(selector % 10, data)
    return 0
}

func fuzzOne(_ target: UInt8, _ data: [UInt8]) {
    switch target {
    case 0: // 画面データ (悪意あるホスト → ビューア)
        let fb = Framebuffer()
        fb.resize(width: 97, height: 61)
        _ = try? fb.apply(data)
    case 1: // RLE 単体
        var dst = [UInt8](repeating: 0, count: 64 * 64 * 4)
        dst.withUnsafeMutableBytes { d in
            data.withUnsafeBufferPointer { src in
                _ = try? TileRLE.decode(src, into: d.baseAddress!, stride: 64 * 4, width: 64, height: 64)
            }
        }
    case 2: // Noise: ホストが受け取る最初のメッセージ (認証前に誰でも送れる)
        let r = NoiseXXHandshake(role: .responder, staticKey: hostKey, prologue: rdPrologue)
        _ = try? r.readMessage(data)
        _ = try? r.writeMessage()
    case 3: // Noise: ビューアが受け取る 2 通目 (なりすましホストが送れる)
        let i = NoiseXXHandshake(role: .initiator, staticKey: viewerKey, prologue: rdPrologue)
        _ = try? i.writeMessage()
        _ = try? i.readMessage(data)
    case 4: // Noise: ホストが受け取る 3 通目
        let i = NoiseXXHandshake(role: .initiator, staticKey: viewerKey, prologue: rdPrologue)
        let r = NoiseXXHandshake(role: .responder, staticKey: hostKey, prologue: rdPrologue)
        guard let m1 = try? i.writeMessage(), (try? r.readMessage(m1)) != nil,
              (try? r.writeMessage()) != nil else { return }
        _ = try? r.readMessage(data)
    case 5: // 認証メッセージ
        _ = try? AuthRequest.decode(data)
        _ = try? AuthResult.decode(data)
        _ = try? Hello.decode(data)
    case 6: // 入力イベント (認証済みビューア → ホスト)
        if let t = data.first { _ = try? ClientEvent.decode(type: t, payload: Array(data.dropFirst())) }
    case 7: // WebSocket フレーム (中継サーバー → 端末)
        var offset = 0
        _ = try? PlainWebSocketFuzz.read(data, &offset)
    case 9: // HTTP 中継の下りストリームのフレーム (中継サーバー → 端末)
        HTTPRelayFrameFuzz.run(data)
    default: // ペアリングコード・Base32・指紋
        let s = String(decoding: data, as: UTF8.self)
        _ = PairingCode.parse(s)
        _ = Base32.decode(s)
        _ = Fingerprint.fromHex(s)
        _ = sanitize(s)
    }
}
