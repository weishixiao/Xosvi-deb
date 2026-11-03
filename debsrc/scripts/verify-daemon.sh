#!/bin/bash
# verify-daemon.sh —— 装完 deb 之后的自检（报告第 9 节清单）。
# 在仓库里跑：bash debsrc/scripts/verify-daemon.sh
# 在设备上跑：先把本脚本与 check-adhoc.py 放到同一目录，再 bash 它。
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="$HERE/../src/xosvi_config.h"

LABEL=""
IDLE=10
if [ -r "$CFG" ]; then
    LABEL="$(sed -n 's/^#define XOSVI_LABEL *"\(.*\)"/\1/p' "$CFG")"
    IDLE="$(sed -n 's/^#define XOSVI_IDLE_SECONDS *\([0-9]*\).*/\1/p' "$CFG")"
fi
[ -n "$LABEL" ] || LABEL=wiki.qaq.xosvid
[ -n "$IDLE" ] || IDLE=10

PREFIX=""
[ -d /var/jb ] && PREFIX="/var/jb"
LCTL="$PREFIX/usr/bin/launchctl"
[ -x "$LCTL" ] || LCTL=launchctl
APP="$PREFIX/Applications/Xosvi.app"
[ -d "$APP" ] || APP=/Applications/Xosvi.app

FAIL=0
chk() {
    printf '%-34s %s\n' "$1" "$2"
    case "$2" in FAIL*|MISSING*) FAIL=1 ;; esac
}
stat_owner() { stat -f %Su "$1" 2>/dev/null || stat -c %U "$1" 2>/dev/null; }
stat_perm()  { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null; }

echo "== 1. 守护已注册 =="
registered=0
for D in system user/501 gui/501; do
    "$LCTL" print "$D/$LABEL" >/dev/null 2>&1 && registered=1
done
chk "launchd job $LABEL" "$([ $registered -eq 1 ] && echo OK || echo FAIL)"

echo "== 2. 属主 / 权限 =="
for f in "$PREFIX/usr/libexec/xosvid" "$APP/Xosvi"; do
    if [ ! -e "$f" ]; then chk "$(basename "$f")" MISSING; continue; fi
    owner="$(stat_owner "$f")"; perm="$(stat_perm "$f")"
    if [ "$owner" = root ] && [ "$perm" = 755 ]; then
        chk "$(basename "$f")" OK
    else
        chk "$(basename "$f")" "FAIL ($owner $perm)"
    fi
done

echo "== 3. CS_ADHOC（报告 7.1）=="
if [ -r "$HERE/check-adhoc.py" ]; then
    if python3 "$HERE/check-adhoc.py" "$PREFIX/usr/libexec/xosvid" "$APP/Xosvi" >/tmp/xosvi-adhoc.log 2>&1; then
        chk "check-adhoc" OK
    else
        sed 's/^/    /' /tmp/xosvi-adhoc.log
        chk "check-adhoc" FAIL
    fi
else
    chk "check-adhoc.py" "SKIP (not shipped)"
fi

echo "== 4. 数据目录 =="
chk "/var/mobile/Documents/wiki.qaq.xosvi" \
    "$([ -d /var/mobile/Documents/wiki.qaq.xosvi ] && echo OK || echo FAIL)"

echo "== 5. XPC 链路 =="
CLI="$PREFIX/usr/bin/xosvi-cli"
[ -x "$CLI" ] || CLI="$APP/Xosvi-cli"
if [ -x "$CLI" ]; then
    out="$("$CLI" ping 2>&1)"
    printf '%s\n' "$out" | sed 's/^/    /'
    if printf '%s' "$out" | grep -q 'status=ok'; then
        chk "ping wiki.qaq.xosvi.service" OK
    else
        chk "ping wiki.qaq.xosvi.service" "FAIL (unreachable)"
    fi
else
    chk "xosvi-cli" MISSING
fi

echo "== 6. 空闲自退（约 ${IDLE} 秒）=="
sleep $((IDLE + 4))
state="$("$LCTL" print "system/$LABEL" 2>/dev/null | grep -m1 -E 'state = ')"
if printf '%s' "$state" | grep -q 'not running'; then
    chk "idle exit" OK
else
    chk "idle exit" "SKIP (${state:-unknown})"
fi

echo
if [ $FAIL -eq 0 ]; then echo "== ALL OK =="; else echo "== HAS FAILURES =="; fi
exit $FAIL
