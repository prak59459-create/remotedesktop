#!/bin/sh
# 攻撃者が送れるデータの解析部分を libFuzzer + AddressSanitizer でファジングする (Linux)。
#   scripts/fuzz.sh [秒数=60]
# クラッシュが見つかると Fuzz/artifacts/ に入力が保存され、終了コードが 0 以外になる。
set -eu
cd "$(dirname "$0")/.."
secs="${1:-60}"
swift build -c release --product RDFuzz --build-path .build-fuzz \
  -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library -Xcc -DRD_FUZZ
mkdir -p Fuzz/corpus Fuzz/artifacts
.build-fuzz/release/RDFuzz Fuzz/corpus -max_total_time="$secs" -max_len=70000 -timeout=10 \
  -artifact_prefix=Fuzz/artifacts/ -print_final_stats=1
