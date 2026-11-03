# debsrc —— Xosvi 的越狱 deb 封装

把 `build/Xosvi.app` 装进 `/Applications`，并带一个按需启动的 root 守护进程
`xosvid`（XPC `wiki.qaq.xosvi.service`）。设计原则全部来自《OwnGoal Studio
iOS 越狱生态六件套静态分析报告》，逐条对应关系见下表。

## 目录

```
debsrc/
├── DEBIAN/{control,postinst,prerm,postrm}
├── Support/{xosvid,helper,cli}.entitlements
├── Library/LaunchDaemons/xosvid.plist
├── src/            xosvid.c / xosvi-build.c / xosvi-install.c / xosvi-symbolicate.c / xosvi-cli.c
└── scripts/        build-deb.sh / check-adhoc.py / verify-daemon.sh
```

## 本地构建

```sh
bash scripts/build-ipa.sh          # 先出 build/Xosvi.app
bash debsrc/scripts/build-deb.sh   # 再出 xosvi_<版本>_iphoneos-arm64.deb
```

Deb 版本号取 `RELEASE_VERSION`（CI 注入 `7.17.0-b<run>`），本地则回落到
`Support/Info.plist` 的 `CFBundleShortVersionString`。

## 报告条款 → 实现落点

| 报告条目 | 落点 |
|---|---|
| 4.2 按需启动（无 RunAtLoad/KeepAlive） | `Library/LaunchDaemons/xosvid.plist`；`xosvid.c` 自己管空闲退出 |
| 4.2 `DISABLE_TWEAKS=1` / `Umask=0022` / `SoftResourceLimits` | 同上 plist |
| 4.2 逐域 bootout + 卸载等待重试 | `DEBIAN/postinst` 第 2–4 段、`prerm` |
| 4.2 双 bootstrap 前缀 + 拒软链接 | `postinst` 第 0–1 段（`PREFIX` 探测、逐文件 `-L` 检查） |
| 5.3 特权分离（守护只给 6 键，重活下放 helper） | `Support/xosvid.entitlements`（5 键，不含 client 凭证） |
| 6.1.4 构建步骤 argv 化、无自由 shell 串 | `src/xosvi-build.c`（`execv`，script 必须落在 project root 内） |
| 7.1 `ldid -Cadhoc` 硬门禁 | `scripts/build-deb.sh` 第 6 步 + `scripts/check-adhoc.py` |
| 7.3 XPC + `xpc_copy_entitlement_for_token` | `src/xosvid.c` `peer_is_authorized()` |
| 7.2 「不要照抄 143 键」 | `Support/helper.entitlements` 仅 10 键 |
| 9 装完自检清单 | `scripts/verify-daemon.sh` |

## 与报告的**有意偏离**

1. **`xosvi-install` 不自己解析 ar/tar，也不手写 dpkg status。**
   报告里 Irisin 那么做是因为它要取代 dpkg；Xosvi 的诉求只是「用 root 装个包」。
   环境里 dpkg 本来就在，自己重写一遍会把依赖解析、conffiles、triggers、版本比较
   全部变成待修 bug，还会在 status 数据库里留下两套写法的冲突。所以这里只做：
   校验 deb 魔数 → `dpkg -i` → 回读退出码。没有 dpkg 就明确报错，让上层改用
   Irisin / Sileo / Zebra。
2. **`helper` 不以 `setuid(501)` 运行。**
   报告原文是「扩展强制降权到 mobile」，但那针对的是**第三方开发扩展**；
   这里的 build/install helper 是 Xosvi 自己的可信组件，构建要写系统路径、
   装包必须 root。`xosvi-build` 保留 `--as-mobile` 开关给「只跑项目脚本」的场景。
3. **不做 tipa 数据搬迁的「找 Bundle 目录」猜测。**
   只用「App 容器 Documents/wiki.qaq.xosvi」这一条确定路径，且仅当目标为空时搬，
   并落 `.migrated` 标记，避免覆盖用户数据。

## 安装与验证

```sh
dpkg -i xosvi_<ver>_iphoneos-arm64.deb
bash /path/to/debsrc/scripts/verify-daemon.sh   # 服务注册 / 属主 / adhoc / ping / 空闲自退
xosvi-cli ping
xosvi-cli install list
xosvi-cli symbolicate info /Applications/Xosvi.app/Xosvi
```

卸载保留数据目录 `/var/mobile/Documents/wiki.qaq.xosvi`；`purge` 也不删。

## 已知边界

- `xosvi-symbolicate` 只做 **UUID 匹配**（回答「该用哪个 dSYM」），
  地址→符号的解析留给 App 侧的 MachOKit，避免在 helper 里再实现一套 DWARF 解析。
- XPC 请求目前是同步的（App 侧 `DispatchSemaphore`）。长任务（构建）建议后续
  改成「立刻回 ack + 订阅进度事件」，`xosvid` 的 `handle_message` 已经按这个方向
  留了 `g_active` 计数，改动只需要加一条 event 通道。
- CI 只跑 `macos-latest`；Linux runner 上 `ldid` / `dpkg-deb` 都缺，无法出包。
