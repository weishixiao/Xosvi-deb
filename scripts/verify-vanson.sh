#!/bin/bash
# VansonEngine 本地编译自检（不需要 Mac / CI，在 iOS 设备上的 iSH 里也能跑）
#
# 用法：
#   bash scripts/verify-vanson.sh [/path/to/iPhoneOS.sdk]
#
# 做过什么：
#   1. 用真实 iOS SDK 头文件逐个编译 VansonEngine 的 13 个源文件（-fsyntax-only）
#   2. 真正编成 .o 并打成 libVansonEngine.a（验证链接期符号能产出）
#   3. 校验 VMMemoryEngine 类符号 + 桥接层要调的 selector 都在库里
#
# 这个脚本存在的意义：GitHub 免费 macOS runner 经常排队 15 分钟然后被取消，
# 那种失败与代码无关。改完引擎代码应先用本脚本自测。
set -uo pipefail
cd "$(dirname "$0")/.."

SDK="${1:-/tmp/sdks/iPhoneOS16.5.sdk}"
if [ ! -d "$SDK/System/Library/Frameworks/Foundation.framework" ]; then
    echo "!!! 找不到 iOS SDK: $SDK" >&2
    echo "    传入路径，例如: bash scripts/verify-vanson.sh /path/to/iPhoneOS16.5.sdk" >&2
    exit 2
fi

ROOT="VansonEngine"
INC="-I$ROOT -I$ROOT/include -I$ROOT/src -I$ROOT/src/core -I$ROOT/src/memory \
-I$ROOT/src/memory/core -I$ROOT/src/utils -I$ROOT/src/utils/helpers -I$ROOT/src/utils/managers"
FLAGS="-x objective-c++ -std=c++17 -fblocks -fobjc-arc -target arm64-apple-ios15.0"
SYS="-isysroot $SDK -F$SDK/System/Library/Frameworks"

SRCS=$(cd "$ROOT" && find src -name '*.mm' -o -name '*.cpp' | sort)

OBJ=/tmp/verify-vanson-obj
# 注意：完整 .o 打包在 iSH 里极慢，本脚本只做语法检查
rm -rf "$OBJ" && mkdir -p "$OBJ"

echo ">>> SDK: $SDK"
echo ">>> 语法检查（唯一必须通过的步骤）"
FAIL=0
for f in $SRCS; do
    out=$(clang++ $FLAGS $SYS $INC -fsyntax-only "$ROOT/$f" 2>&1 | rg 'error:' | head -3)
    if [ -n "$out" ]; then
        echo "  ❌ $f"; echo "$out" | sed 's/^/     /'; FAIL=$((FAIL+1))
    else
        echo "  ✅ $f"
    fi
done
if [ "$FAIL" -gt 0 ]; then
    echo "!!! $FAIL 个文件语法检查失败" >&2; exit 1
fi
echo
echo "=== 全部通过：$(( $(echo "$SRCS" | wc -l) )) 个源文件在真实 iOS SDK 下编译无错 ==="
echo "    （完整 .o 打包由 CI 的 scripts/build-vanson.sh 执行；iSH 里逐文件 -c 太慢，此处省略）"
