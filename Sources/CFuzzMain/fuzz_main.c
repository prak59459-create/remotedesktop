// SwiftPM は Linux の実行ファイルの main を "<ターゲット名>_main" に付け替える。
// -parse-as-library で Swift 側に main が無いファズ用ビルドでは、ここで libFuzzer を起動する。
#include "CFuzzMain.h"
#ifdef RD_FUZZ
#include <stddef.h>
#include <stdint.h>
int LLVMFuzzerRunDriver(int *argc, char ***argv, int (*cb)(const uint8_t *, size_t));
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int RDFuzz_main(int argc, char **argv) {
    return LLVMFuzzerRunDriver(&argc, &argv, LLVMFuzzerTestOneInput);
}
#endif
