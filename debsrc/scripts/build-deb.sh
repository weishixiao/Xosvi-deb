#!/bin/bash
# build-deb.sh —— 把 Xosvi.app 打成越狱 deb。
#
# 只在 macOS 上跑（需要 xcrun / ldid / dpkg-deb）。CI 由
# .github/workflows/build-deb.yml 调用；本地等价于：
#     bash scripts/build-ipa.sh && bash debsrc/scripts/build-deb.sh
#
# 产出两种 bootstrap 各一份，差异只有两处（Architecture 与 payload 路径前缀）：
#     xosvi_<版本>_iphoneos-arm64e.deb   roothide：Architecture iphoneos-arm64e，
#                                        payload 用 rootful 路径，dpkg 自己
#                                        重定向进随机 jbroot；plist 里守护路径
#                                        不加前缀（roothide 的 launchctl 会加）
#     xosvi_<版本>_iphoneos-arm64.deb    rootless：payload 全部落在 /var/jb 下；
#                                        plist 里守护路径写 /var/jb/usr/libexec/xosvid
#
# 只出其中一种：DEB_ARCHS="iphoneos-arm64e" bash debsrc/scripts/build-deb.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEB="$ROOT/debsrc"
WORK="$ROOT/build-deb"
ARCHS="${DEB_ARCHS:-iphoneos-arm64e iphoneos-arm64}"

# App 来源优先级：$APP_SRC（CI 从 tipa 解出来的）> build/Xosvi.app > 仓库里任意一个
APP_SRC="${APP_SRC:-}"
if [ -z "$APP_SRC" ] || [ ! -d "$APP_SRC" ]; then
    if [ -d "$ROOT/build/Xosvi.app" ]; then
        APP_SRC="$ROOT/build/Xosvi.app"
    else
        APP_SRC="$(find "$ROOT" -maxdepth 4 -name 'Xosvi.app' -type d -not -path '*/build-deb/*' | head -1)"
    fi
fi
[ -n "$APP_SRC" ] && [ -d "$APP_SRC" ] || {
    echo "!!! Xosvi.app not found" >&2
    echo "    set APP_SRC=<path> or run scripts/build-ipa.sh first" >&2
    exit 1
}
VERSION="${RELEASE_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Support/Info.plist")}"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MINVER="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$ROOT/Support/Info.plist" 2>/dev/null || echo 15.0)"
CFLAGS=(-arch arm64 -O2 -isysroot "$SDK" -miphoneos-version-min="$MINVER"
        -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -framework Foundation)

echo ">>> version=$VERSION sdk=$SDK min=$MINVER"
echo ">>> app=$APP_SRC"
echo ">>> arches=$ARCHS"

# ── 1. 中立产物：一次编译，两种 bootstrap 复用 ──────────────────────────
rm -rf "$WORK"
NEUTRAL="$WORK/neutral"
mkdir -p "$NEUTRAL/usr/libexec/xosvi" "$NEUTRAL/usr/bin"

echo ">>> compiling xosvid + helpers"
clang "${CFLAGS[@]}" -o "$NEUTRAL/usr/libexec/xosvid"                  "$DEB/src/xosvid.c"
clang "${CFLAGS[@]}" -o "$NEUTRAL/usr/libexec/xosvi/xosvi-build"       "$DEB/src/xosvi-build.c"
clang "${CFLAGS[@]}" -o "$NEUTRAL/usr/libexec/xosvi/xosvi-install"     "$DEB/src/xosvi-install.c"
clang "${CFLAGS[@]}" -o "$NEUTRAL/usr/libexec/xosvi/xosvi-symbolicate" "$DEB/src/xosvi-symbolicate.c"
clang "${CFLAGS[@]}" -o "$NEUTRAL/usr/bin/xosvi-cli"                   "$DEB/src/xosvi-cli.c"

echo ">>> signing (ldid -Cadhoc)"
APP_ENT="$ROOT/Support/Xosvi.entitlements"
[ -f "$APP_ENT" ] || { echo "!!! Support/Xosvi.entitlements missing" >&2; exit 1; }
ldid -Cadhoc -S"$APP_ENT" "$APP_SRC/Xosvi"
ldid -Cadhoc -S"$DEB/Support/xosvid.entitlements" "$NEUTRAL/usr/libexec/xosvid"
for h in build install symbolicate; do
    ldid -Cadhoc -S"$DEB/Support/helper.entitlements" "$NEUTRAL/usr/libexec/xosvi/xosvi-$h"
done
ldid -Cadhoc -S"$DEB/Support/cli.entitlements" "$NEUTRAL/usr/bin/xosvi-cli"

echo ">>> assert CS_ADHOC"
python3 "$DEB/scripts/check-adhoc.py" \
    "$APP_SRC/Xosvi" \
    "$NEUTRAL/usr/libexec/xosvid" \
    "$NEUTRAL/usr/libexec/xosvi/xosvi-build" \
    "$NEUTRAL/usr/libexec/xosvi/xosvi-install" \
    "$NEUTRAL/usr/libexec/xosvi/xosvi-symbolicate" \
    "$NEUTRAL/usr/bin/xosvi-cli"

# 名字只有一处真源：src/xosvi_config.h
LABEL="$(sed -n 's/^#define XOSVI_LABEL *"\(.*\)"/\1/p' "$DEB/src/xosvi_config.h")"
SVC="$(sed -n 's/^#define XOSVI_SERVICE_NAME *"\(.*\)"/\1/p' "$DEB/src/xosvi_config.h")"
IDLE="$(sed -n 's/^#define XOSVI_IDLE_SECONDS *\([0-9]*\).*/\1/p' "$DEB/src/xosvi_config.h")"
[ -n "$LABEL" ] && [ -n "$SVC" ] && [ -n "$IDLE" ] || { echo "!!! cannot parse xosvi_config.h" >&2; exit 1; }
echo ">>> label=$LABEL service=$SVC idle=${IDLE}s"

# ── 2. 每种架构各装一次 ────────────────────────────────────────────────
for ARCH in $ARCHS; do
    case "$ARCH" in
        iphoneos-arm64e)   PREFIX="" ;;          # roothide：dpkg 重定向进 jbroot
        iphoneos-arm64)    PREFIX="/var/jb" ;;   # rootless：payload 显式落 jbroot
        *) echo "!!! unsupported arch: $ARCH" >&2; exit 1 ;;
    esac
    echo
    echo "=== $ARCH (payload prefix '${PREFIX:-<none>}')"

    STAGE="$WORK/stage-$ARCH"
    mkdir -p "$STAGE/DEBIAN"

    if [ -n "$PREFIX" ]; then
        DEST="$STAGE$PREFIX"
    else
        DEST="$STAGE"
    fi
    mkdir -p "$DEST/Applications" "$DEST/usr/libexec/xosvi" "$DEST/usr/bin" \
             "$DEST/Library/LaunchDaemons"
    cp -R "$APP_SRC" "$DEST/Applications/Xosvi.app"
    cp "$NEUTRAL/usr/libexec/xosvid" "$DEST/usr/libexec/xosvid"
    cp "$NEUTRAL/usr/libexec/xosvi/"* "$DEST/usr/libexec/xosvi/"
    cp "$NEUTRAL/usr/bin/xosvi-cli" "$DEST/usr/bin/xosvi-cli"

    # plist：roothide 不加前缀（launchctl 每次加载时自己加），rootless 必须写全
    sed -e "s#__XOSVID_LABEL__#$LABEL#g" \
        -e "s#__XOSVID_SERVICE__#$SVC#g" \
        -e "s#__IDLE__#$IDLE#g" \
        -e "s#@PREFIX@#$PREFIX#g" \
        "$DEB/Library/LaunchDaemons/xosvid.plist" \
        > "$DEST/Library/LaunchDaemons/$LABEL.plist"
    plutil -lint "$DEST/Library/LaunchDaemons/$LABEL.plist" >/dev/null

    for f in control postinst prerm postrm; do
        sed -e "s#@VERSION@#$VERSION#g" \
            -e "s#@ARCH@#$ARCH#g" \
            -e "s#__XOSVID_LABEL__#$LABEL#g" \
            -e "s#__XOSVID_SERVICE__#$SVC#g" \
            "$DEB/DEBIAN/$f" > "$STAGE/DEBIAN/$f"
    done
    chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"
    chmod 644 "$STAGE/DEBIAN/control"
    SIZE_KB="$(du -sk "$STAGE" | awk '{print $1}')"
    sed -i.bak "s/^Installed-Size: .*/Installed-Size: $SIZE_KB/" "$STAGE/DEBIAN/control"
    rm -f "$STAGE/DEBIAN/control.bak"

    find "$STAGE" -type d -exec chmod 755 {} \;
    find "$DEST/usr" -type f -exec chmod 755 {} \;
    chmod 755 "$DEST/Applications/Xosvi.app/Xosvi"
    chmod 644 "$DEST/Library/LaunchDaemons/$LABEL.plist"
    chown -R root:wheel "$STAGE" 2>/dev/null || true

    OUT="$ROOT/xosvi_${VERSION}_${ARCH}.deb"
    dpkg-deb -b --root-owner-group "$STAGE" "$OUT" >/dev/null
    echo ">>> DONE: $OUT ($(du -h "$OUT" | cut -f1))"
    dpkg-deb -f "$OUT" Package Version Architecture
done

echo
echo ">>> 全部产物"
ls -lh "$ROOT"/xosvi_*.deb
