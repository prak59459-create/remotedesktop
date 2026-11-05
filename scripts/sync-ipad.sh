#!/bin/sh
# Sources/RDCore を iPad アプリ (Swift Playgrounds 用パッケージ) にコピーする。
# Swift Playgrounds はパッケージ外のローカルモジュールを参照できないため。
set -eu
cd "$(dirname "$0")/.."
dst=ipad/RemoteDesktop.swiftpm/Core
rm -rf "$dst"
mkdir -p "$dst"
for f in $(cd Sources/RDCore && find . -name '*.swift' | sort); do
  mkdir -p "$dst/$(dirname "$f")"
  {
    echo "// 自動生成: scripts/sync-ipad.sh が Sources/RDCore/${f#./} からコピー。直接編集しないでください。"
    cat "Sources/RDCore/$f"
  } > "$dst/$f"
done
echo "synced $(find "$dst" -name '*.swift' | wc -l | tr -d ' ') files to $dst"
