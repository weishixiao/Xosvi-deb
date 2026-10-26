#!/bin/bash
# VansonMod 内存引擎静态库构建（Xosvi 集成）
#
# 把 VansonEngine/ 下的 Objective-C++ / C++ 内存引擎（源自 VansonMod, GPL-3.0）编成
# libVansonEngine.a，供 SwiftPM 主 App 链接（Package.swift 用 -L vanson-stage/lib -lVansonEngine）。
# 与 scripts/build-hud.sh 同一模式：SwiftPM 不便直接编 .mm/C++ 混编 + 复杂相对 include，
# 先独立编静态库再链接最稳。
#
# 产物：vanson-stage/lib/libVansonEngine.a（arm64 + arm64e fat，能 fat 就 fat）
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo ">>> VansonEngine: compiling libVansonEngine.a (sdk=$SDK)"

ROOT="VansonEngine"
mkdir -p vanson-stage/lib build-vanson

# 前置自检：源文件必须齐全（CI 上缺文件时给出明确报错，而不是链接期报 undefined symbol）
if [ ! -f "$ROOT/include/VMMemoryEngine.h" ]; then
    echo "!!! $ROOT/include/VMMemoryEngine.h 缺失——VansonEngine/ 目录未完整提交？" >&2
    exit 1
fi

# 源文件清单（与 VansonEngine/ 目录结构对应）
SRCS="
$ROOT/src/XosviVansonBridge.mm
$ROOT/src/memory/VMMemoryEngine.mm
$ROOT/src/memory/core/MemoryCore.cpp
$ROOT/src/memory/core/SessionCore.mm
$ROOT/src/core/SystemCore.cpp
$ROOT/src/utils/helpers/VMLocalization.mm
$ROOT/src/utils/helpers/VMStoragePathHelper.mm
$ROOT/src/utils/managers/StorageCore.mm
$ROOT/src/utils/managers/PatchCore.mm
$ROOT/src/utils/managers/LockCore.mm
$ROOT/src/utils/managers/VMLockEngine.mm
$ROOT/src/utils/managers/VMLockManager.mm
$ROOT/src/utils/managers/VMSignatureModel.mm
$ROOT/src/utils/managers/VMPointerChain.mm
$ROOT/src/utils/managers/VMRVAPatch.mm
"

# include 搜索路径：每个子目录都加，兼容原项目 "../core/X.hpp"、"../../include/Y.h" 等相对层级
INCFLAGS="-I $ROOT -I $ROOT/include -I $ROOT/src -I $ROOT/src/core -I $ROOT/src/memory \
-I $ROOT/src/memory/core -I $ROOT/src/utils -I $ROOT/src/utils/helpers -I $ROOT/src/utils/managers"

CFLAGS="-fobjc-arc -fvisibility=hidden -fvisibility-inlines-hidden -std=c++17 \
-Wno-error -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function \
-Wno-unused-private-field -Wno-nullability-completeness -Wno-comment"

build_arch() {
    local arch="$1"
    local dir="build-vanson/$arch"
    mkdir -p "$dir"
    rm -f "$dir"/*.o
    local objs=()
    for f in $SRCS; do
        local base; base="$(basename "$f")"
        local o="$dir/${base%.*}.o"
        echo "    [$arch] $f"
        case "$f" in
            *.mm)
                xcrun -sdk iphoneos clang++ -arch "$arch" -isysroot "$SDK" \
                    -miphoneos-version-min=15.0 $CFLAGS $INCFLAGS -c "$f" -o "$o" ;;
            *.cpp)
                xcrun -sdk iphoneos clang++ -arch "$arch" -isysroot "$SDK" \
                    -miphoneos-version-min=15.0 $CFLAGS $INCFLAGS -c "$f" -o "$o" ;;
            */*.m)
                xcrun -sdk iphoneos clang -arch "$arch" -isysroot "$SDK" \
                    -miphoneos-version-min=15.0 $CFLAGS $INCFLAGS -c "$f" -o "$o" ;;
            *)
                echo "!!! unknown source type: $f" >&2; return 1 ;;
        esac || return 1
        objs+=("$o")
    done
    ar rcs "vanson-stage/lib/libVansonEngine-$arch.a" "${objs[@]}"
}

if build_arch arm64; then
    echo ">>> VansonEngine arm64 OK"
else
    echo "!!! VansonEngine arm64 build FAILED — aborting"
    exit 1
fi

ARM64E_OK=0
if build_arch arm64e; then
    echo ">>> VansonEngine arm64e OK"
    ARM64E_OK=1
else
    echo "!!! VansonEngine arm64e build failed — fallback arm64 only"
fi

if [ "$ARM64E_OK" = "1" ]; then
    lipo -create vanson-stage/lib/libVansonEngine-arm64.a \
        vanson-stage/lib/libVansonEngine-arm64e.a \
        -output vanson-stage/lib/libVansonEngine.a
    echo ">>> libVansonEngine.a fat (arm64+arm64e): $(du -h vanson-stage/lib/libVansonEngine.a | cut -f1)"
else
    cp vanson-stage/lib/libVansonEngine-arm64.a vanson-stage/lib/libVansonEngine.a
    echo ">>> libVansonEngine.a arm64 only: $(du -h vanson-stage/lib/libVansonEngine.a | cut -f1)"
fi
