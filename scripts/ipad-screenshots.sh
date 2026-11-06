#!/usr/bin/env bash
# iPad アプリをシミュレーターで動かし、テスト用ホスト (Mac 版 RDHost: テストパターンを配信) に
# 実際にペアリング・接続して、各画面のスクリーンショットを撮る。macOS + Xcode 専用。
#   使い方: scripts/ipad-screenshots.sh [出力先ディレクトリ]
# 自動操作は -DRD_SCREENSHOTS を付けたビルドにだけ含まれる (App/ScreenshotDriver.swift)。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mkdir -p "${1:-screenshots}" && cd "${1:-screenshots}" && pwd)"
WORK="$(mktemp -d)"
BUNDLE=local.remotedesktop.viewer
HOST_PID=""
UDID=""

cleanup() {
  [ -n "$HOST_PID" ] && kill "$HOST_PID" 2>/dev/null || true
  # ペアリングコード (使い捨て) はログから伏せる
  [ -f "$WORK/host.log" ] && sed -E 's/(ペアリングコード: *)[0-9A-Z-]+/\1(伏せ字)/' "$WORK/host.log" | tr -d '\r' > "$OUT/host.log" || true
}
trap cleanup EXIT

echo "== ホストをビルド"
swift build --product RDHost

echo "== シミュレーターを起動"
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devs = json.load(sys.stdin)["devices"]
def ver(rt):
    try: return tuple(int(x) for x in rt.split("iOS-")[1].split("-"))
    except Exception: return (0,)
cands = sorted(((ver(rt), d) for rt, ds in devs.items() if "iOS" in rt for d in ds if d["name"].startswith("iPad")),
               key=lambda t: t[0])
pick = [d for v, d in cands if "iPad Pro 13" in d["name"]] or [d for v, d in cands if "iPad Air" in d["name"]] or [d for v, d in cands]
print(pick[-1]["udid"])
')"
xcrun simctl list devices | grep "$UDID"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance light || true
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 || true

echo "== iPad アプリをビルド (撮影用の自動操作つき)"
(cd ipad/RemoteDesktop.swiftpm && xcodebuild build -scheme RemoteDesktop -destination "id=$UDID" \
  -derivedDataPath "$WORK/dd" -skipPackagePluginValidation \
  OTHER_SWIFT_FLAGS='$(inherited) -DRD_SCREENSHOTS' | tail -n 30)
APP="$(find "$WORK/dd/Build/Products" -maxdepth 2 -name 'RemoteDesktop.app' | head -1)"
[ -n "$APP" ] || { echo "アプリが見つかりません"; exit 1; }
xcrun simctl install "$UDID" "$APP"

echo "== ホストを起動 (ペアリングコードは 10 分で切れるので、アプリのビルド後に起動する)"
IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
[ -n "$IP" ] || IP=127.0.0.1
echo "ホストの IP: $IP"
RD_TEST_AUTO_APPROVE=1 RD_TEST_LOOPBACK_IS_LAN=1 \
  script -q "$WORK/host.log" .build/debug/RDHost --pair --port 5999 --data-dir "$WORK/host" --idle-timeout 30 \
  < /dev/null > /dev/null 2>&1 &
HOST_PID=$!
for _ in $(seq 120); do grep -q 'ペアリングコード:' "$WORK/host.log" 2>/dev/null && break; sleep 1; done
CODE="$(grep -o 'ペアリングコード: *[0-9A-Z-]*' "$WORK/host.log" | head -1 | sed -E 's/.*: *//')"
[ -n "$CODE" ] || { echo "ペアリングコードが取れません"; cat "$WORK/host.log" || true; exit 1; }

echo "== Face ID を登録済みにする (シミュレーターの機能。撮影後に「一致」を送って本人確認を通す)"
xcrun simctl spawn "$UDID" notifyutil -s com.apple.BiometricKit.enrollmentChanged '1'
xcrun simctl spawn "$UDID" notifyutil -p com.apple.BiometricKit.enrollmentChanged

echo "== 起動して撮影"
SIMCTL_CHILD_RD_SHOT_HOST="$IP" SIMCTL_CHILD_RD_SHOT_PORT=5999 SIMCTL_CHILD_RD_SHOT_CODE="$CODE" \
SIMCTL_CHILD_RD_SHOT_RELAY="https://my-relay.onrender.com" \
  xcrun simctl launch "$UDID" "$BUNDLE"
sleep 2
SHOTS="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Documents/shots"
deadline=$((SECONDS + 300))
while [ $SECONDS -lt $deadline ] && [ ! -f "$SHOTS/finished" ]; do
  for r in "$SHOTS"/*.ready; do
    [ -e "$r" ] || continue
    n="$(basename "$r" .ready)"
    [ -f "$SHOTS/$n.done" ] && continue
    sleep 0.5
    xcrun simctl io "$UDID" screenshot "$OUT/$n.png" >/dev/null
    echo "撮影: $n"
    # 本人確認の画面が出ていれば、顔が一致したことにする (出ていなければ何も起きない)
    xcrun simctl spawn "$UDID" notifyutil -p com.apple.BiometricKit_Sim.pearl.match || true
    sleep 0.3
    touch "$SHOTS/$n.done"
  done
  sleep 0.5
done

sleep 1
if [ -f "$SHOTS/used-bonjour" ]; then
  echo "== Bonjour で見つけた「$(cat "$SHOTS/used-bonjour")」に名前で接続しました"
else
  echo "== Bonjour では見つからず、IP アドレスで接続しました"
fi
echo "== ホストが受け取った入力"
grep -a '\[input\]' "$WORK/host.log" | tr -d '\r' | head -20 || true
ls -1 "$OUT"
[ -f "$OUT/07-remote-landscape.png" ] || { echo "リモート画面まで進めませんでした"; exit 1; }
