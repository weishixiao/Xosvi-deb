// xosvi_config.h —— 服务名 / entitlement 名的唯一来源。
// debsrc/scripts/build-deb.sh 会把这里的字面量同步写进 plist、entitlements
// 与 App 侧 Support/Xosvi.entitlements；改这里等于改全部。
#ifndef XOSVI_CONFIG_H
#define XOSVI_CONFIG_H

#define XOSVI_SERVICE_NAME "wiki.qaq.xosvi.service"
#define XOSVI_CLIENT_ENT   "wiki.qaq.xosvi.client"
#define XOSVI_LABEL        "wiki.qaq.xosvid"
#define XOSVI_IDLE_SECONDS 10
#define XOSVI_HELPER_DIR   "/usr/libexec/xosvi"
#define XOSVI_SPILL_DIR    "/var/mobile/Documents/wiki.qaq.xosvi/spill"
#define XOSVI_DATA_ROOT    "/var/mobile/Documents/wiki.qaq.xosvi"

#endif
