#!/bin/bash
# build-deb.sh —— 把 build/Xosvi.app 打成越狱 deb。
#
# 只在 macOS 上跑（需要 xcrun / ldid / dpkg-deb）。CI 由
# .github/workflows/build-deb.yml 调用；本地等价于：
#     bash scripts/build-ipa.sh && bash debsrc/scripts/build-deb.sh
#
# 产物：仓库根目录下 xosvi_<版本>_iphoneos-arm64.deb
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEB="$ROOT/debsrc"
STAGE="$ROOT/build-deb/layout"

VERSION="${RELEASE_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Support/Info.plist")}"
APP_SRC="${APP_SRC:-$ROOT/build/Xosvi.app}"
if [ ! -d "$APP_SRC" ]; then
    APP_SRC="$(find "$ROOT" -maxdepth 3 -name 'Xosvi.app' -type d -not -path '*/build-deb/*' | head -1)"
fi
[ -n "$APP_SRC" ] && [ -d "$APP_SRC" ] || { echo "!!! Xosvi.app not found (run scripts/build-ipa.sh first)" >&2; exit 1; }

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MINVER="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$ROOT/Support/Info.plist" 2>/dev/null || echo 15.0)"
CFLAGS=(-arch arm64 -O2 -isysroot "$SDK" -miphoneos-version-min="$MINVER"
        -Wall -Wextra -Wno-unused-parameter -Wno-unused-function -framework Foundation)

echo ">>> version=$VERSION sdk=$SDK min=$MINVER"
echo ">>> app=$APP_SRC"

# ── 1. 暂存目录 ─────────────────────────────────────────────────────────
rm -rf "$ROOT/build-deb"
mkdir -p "$STAGE/Applications" "$STAGE/usr/libexec/xosvi" \
         "$STAGE/usr/bin" "$STAGE/Library/LaunchDaemons"
cp -R "$APP_SRC" "$STAGE/Applications/Xosvi.app"

# ── 2. 编译守护 / helper / CLI ──────────────────────────────────────────
echo ">>> compiling xosvid + helpers"
clang "${CFLAGS[@]}" -o "$STAGE/usr/libexec/xosvid"                  "$DEB/src/xosvid.c"
clang "${CFLAGS[@]}" -o "$STAGE/usr/libexec/xosvi/xosvi-build"       "$DEB/src/xosvi-build.c"
clang "${CFLAGS[@]}" -o "$STAGE/usr/libexec/xosvi/xosvi-install"     "$DEB/src/xosvi-install.c"
clang "${CFLAGS[@]}" -o "$STAGE/usr/libexec/xosvi/xosvi-symbolicate" "$DEB/src/xosvi-symbolicate.c"
clang "${CFLAGS[@]}" -o "$STAGE/usr/bin/xosvi-cli"                   "$DEB/src/xosvi-cli.c"

# ── 3. plist / 控制文件（名字只有一处真源：src/xosvi_config.h）─────────
LABEL="$(sed -n 's/^#define XOSVI_LABEL *"\(.*\)"/\1/p' "$DEB/src/xosvi_config.h")"
SVC="$(sed -n 's/^#define XOSVI_SERVICE_NAME *"\(.*\)"/\1/p' "$DEB/src/xosvi_config.h")"
IDLE="$(sed -n 's/^#define XOSVI_IDLE_SECONDS *\([0-9]*\).*/\1/p' "$DEB/src/xosvi_config.h")"
[ -n "$LABEL" ] && [ -n "$SVC" ] && [ -n "$IDLE" ] || { echo "!!! cannot parse xosvi_config.h" >&2; exit 1; }
echo ">>> label=$LABEL service=$SVC idle=${IDLE}s"

sed -e "s#__XOSVID_LABEL__#$LABEL#g" \
    -e "s#__XOSVID_SERVICE__#$SVC#g" \
    -e "s#__IDLE__#$IDLE#g" \
    "$DEB/Library/LaunchDaemons/xosvid.plist" \
    > "$STAGE/Library/LaunchDaemons/$LABEL.plist"
plutil -lint "$STAGE/Library/LaunchDaemons/$LABEL.plist" >/dev/null

mkdir -p "$STAGE/DEBIAN"
for f in control postinst prerm postrm; do
    sed -e "s#@VERSION@#$VERSION#g" \
        -e "s#__XOSVID_LABEL__#$LABEL#g" \
        -e "s#__XOSVID_SERVICE__#$SVC#g" \
        "$DEB/DEBIAN/$f" > "$STAGE/DEBIAN/$f"
done
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/postrm"
chmod 644 "$STAGE/DEBIAN/control"
SIZE_KB="$(du -sk "$STAGE" | awk '{print $1}')"
sed -i.bak "s/^Installed-Size: .*/Installed-Size: $SIZE_KB/" "$STAGE/DEBIAN/control"
rm -f "$STAGE/DEBIAN/control.bak"

# ── 4. 签名：App 沿用既有 entitlements，其余用 debsrc/Support ───────────
echo ">>> signing (ldid -Cadhoc)"
APP_ENT="$ROOT/Support/Xosvi.entitlements"
[ -f "$APP_ENT" ] || { echo "!!! Support/Xosvi.entitlements missing" >&2; exit 1; }
ldid -Cadhoc -S"$APP_ENT" "$STAGE/Applications/Xosvi.app/Xosvi"
ldid -Cadhoc -S"$DEB/Support/xosvid.entitlements" "$STAGE/usr/libexec/xosvid"
for h in build install symbolicate; do
    ldid -Cadhoc -S"$DEB/Support/helper.entitlements" "$STAGE/usr/libexec/xosvi/xosvi-$h"
done
ldid -Cadhoc -S"$DEB/Support/cli.entitlements" "$STAGE/usr/bin/xosvi-cli"

# ── 5. 权限归一 ─────────────────────────────────────────────────────────
find "$STAGE" -type d -exec chmod 755 {} \;
find "$STAGE/usr" -type f -exec chmod 755 {} \;
chmod 755 "$STAGE/Applications/Xosvi.app/Xosvi"
chmod 644 "$STAGE/Library/LaunchDaemons/$LABEL.plist"
chown -R root:wheel "$STAGE" 2>/dev/null || true

# ── 6. adhoc 硬门禁（报告 7.1）──────────────────────────────────────────
echo ">>> assert CS_ADHOC"
python3 "$DEB/scripts/check-adhoc.py" \
    "$STAGE/Applications/Xosvi.app/Xosvi" \
    "$STAGE/usr/libexec/xosvid" \
    "$STAGE/usr/libexec/xosvi/xosvi-build" \
    "$STAGE/usr/libexec/xosvi/xosvi-install" \
    "$STAGE/usr/libexec/xosvi/xosvi-symbolicate" \
    "$STAGE/usr/bin/xosvi-cli"

# ── 7. 打包 ─────────────────────────────────────────────────────────────
OUT="$ROOT/xosvi_${VERSION}_iphoneos-arm64.deb"
echo ">>> dpkg-deb -b"
dpkg-deb -b --root-owner-group "$STAGE" "$OUT" >/dev/null
echo ">>> DONE: $OUT ($(du -h "$OUT" | cut -f1))"
dpkg-deb -I "$OUT" | sed -n '1,18p'
