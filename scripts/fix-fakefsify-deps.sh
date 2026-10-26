#!/bin/bash
# v7.14.6：让 Sandbox/build/fakefsify 自包含，不再依赖 /opt/homebrew 的运行时路径。
#
# 背景（CI 实测）：
#   1) fakefsify 是 host 工具，链的是 Homebrew 的 libarchive 动态库；
#   2) 上一版脚本只把 libarchive*.dylib 拷进 build/lib 并改写了「主二进制」的引用，
#      但没处理 libarchive 自己的依赖；
#   3) 缓存命中那一轮 Build iSH sandbox 被 skip，没 brew install libarchive，
#      Homebrew 的 libb2 也不在，于是 dyld：
#        Library not loaded: /opt/homebrew/opt/libb2/lib/libb2.1.dylib
#        Referenced from: build/lib/libarchive.13.dylib
#      → Abort trap: 6 (exit 134)，构建在 rootfs 阶段失败。
#
# 做法：以 fakefsify 为根，广度优先遍历 otool -L，把所有非系统 dylib
# （/opt/homebrew/**、/usr/local/**）递归拷进 build/lib，并把**每一层**的引用
# 改成 @loader_path 相对路径。系统库（/usr/lib、/System）保持原样。
#
# 用法：cd Sandbox && bash <repo>/scripts/fix-fakefsify-deps.sh
# 退出码：0 = 成功（或当前非 macOS 主机）；1 = 缺少 fakefsify

set -uo pipefail

BIN="build/fakefsify"
LIBDIR="build/lib"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "[fakefsify-deps] 非 macOS 主机，跳过"
  exit 0
fi

if [ ! -f "$BIN" ]; then
  echo "[fakefsify-deps] 缺少 $BIN" >&2
  exit 1
fi

mkdir -p "$LIBDIR"

is_system() {
  case "$1" in
    /usr/lib/*|/System/*|@loader_path/*|@rpath/*|@executable_path/*) return 0 ;;
    *) return 1 ;;
  esac
}

# 已处理集合（文件名去重，避免同一 dylib 多次拷贝/改写）
declare -A SEEN=()
QUEUE=("$BIN")
copied=0
rewritten=0

while [ ${#QUEUE[@]} -gt 0 ]; do
  cur="${QUEUE[0]}"
  QUEUE=("${QUEUE[@]:1}")
  base=$(basename "$cur")
  [ -n "${SEEN[$base]:-}" ] && continue
  SEEN[$base]=1

  # otool -L 第一行是文件本身，其余是依赖
  deps=$(otool -L "$cur" 2>/dev/null | tail -n +2 | awk '{print $1}')
  [ -z "$deps" ] && continue

  for dep in $deps; do
    depbase=$(basename "$dep")
    # 系统库 / 已相对化的引用：保留
    if is_system "$dep"; then
      # 若已经是相对布局，仍要保证文件在 lib/ 里（缓存里可能缺）
      case "$dep" in
        @loader_path/lib/*)
          [ -f "$LIBDIR/$depbase" ] || echo "[fakefsify-deps] 警告：引用存在但文件缺失 $dep" >&2
          ;;
      esac
      continue
    fi

    # 非系统依赖：必须落在 build/lib 里
    if [ ! -f "$LIBDIR/$depbase" ]; then
      if [ -f "$dep" ]; then
        cp -f "$dep" "$LIBDIR/$depbase"
        chmod u+w "$LIBDIR/$depbase" 2>/dev/null || true
        # 清掉原签名，改写 install_name 后才可被 dyld 接受
        install_name_tool -id "@loader_path/$depbase" "$LIBDIR/$depbase" 2>/dev/null || true
        copied=$((copied + 1))
        echo "[fakefsify-deps] + $depbase  ($dep)"
      else
        echo "[fakefsify-deps] 缺失 $dep（未安装在当前 runner）" >&2
        continue
      fi
    fi

    # 把当前文件的引用指到相对路径（对主二进制和库本身都适用）
    install_name_tool -change "$dep" "@loader_path/lib/$depbase" "$cur" 2>/dev/null \
      && rewritten=$((rewritten + 1))

    # 继续追踪这个库自己的依赖
    QUEUE+=("$LIBDIR/$depbase")
  done
done

# 兜底：fakefsify 里可能还有指向 Homebrew 的 @rpath 形式，逐条改成绝对库名
unresolved=$(otool -L "$BIN" 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -c '/opt/homebrew\|/usr/local' || true)
echo "[fakefsify-deps] 拷贝 $copied 个依赖，改写 $rewritten 处引用，未解析 $unresolved 条"

if [ "$unresolved" -gt 0 ]; then
  echo "[fakefsify-deps] 仍有 Homebrew 绝对路径依赖：" >&2
  otool -L "$BIN" | tail -n +2 | awk '{print "   " $1}' >&2
  exit 1
fi

# 重新签名：install_name_tool 改动后原 ad-hoc 签名失效，未签名的 dylib 在 arm64 上会被拒
for f in "$BIN" "$LIBDIR"/*.dylib; do
  [ -f "$f" ] || continue
  codesign --force --sign - "$f" >/dev/null 2>&1 || true
done

echo "[fakefsify-deps] 自包含检查："
otool -L "$BIN" | tail -n +2 | awk '{print "   " $1}'
exit 0
