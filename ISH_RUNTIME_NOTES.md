# iSH 运行时实测记录（Xosvi 内置引擎）

> 来源：2026-10-29 真机（rootHide 越狱）一整轮排障的实测结论，不是推测。
> 用途：以后再遇到「iSH 里装不了包 / 看不到文件 / 网络不通」，先按这里对号入座。

## 1. 根文件系统在哪

```
/private/var/mobile/Library/Application Support/ish-rootfs/data   →   iSH 内的 /
```

- 挂载类型是 `fake`（iSH 自己的 fakefs，不是 bind mount）
- **iOS 原生侧可以直接读写这个目录**，这是所有文件通道的基础
- `bind mount` 到 iSH 内会报 `Bad address` —— iSH 不支持，别再试

## 2. fakefs 的语义（最重要的一条）

实测三种情况：

| 操作 | iSH 内是否可见 |
|---|---|
| iOS 侧**新建**文件 | ❌ 看不到（inode 缓存不刷新，`ls`/`cat` 都没有） |
| iSH 侧自己写文件 | ✅ 正常 |
| iSH 先创建 → iOS 侧**覆盖**内容 | ✅ iSH 立刻读到新内容 |

**结论：唯一可靠的双向通道是「iSH 建占位文件 → iOS 覆盖写入」。**
iOS 侧无中生有地放文件进 rootfs，iSH 是不认的。

## 3. 网络：半通

| 层 | 现象 |
|---|---|
| ICMP | `ping` 100% 丢包（被拦，不代表断网） |
| ioctl | `SIOCGIFCONF` / `SIOCSIFFLAGS` 报 `Not a tty`（越狱 hook 拦 ioctl） |
| DNS | ✅ 解析成功 |
| TCP | ✅ 握手成功（`nc` rc=0） |
| HTTP | ✅ 正常，200 + 完整字节 |
| **HTTPS / TLS** | ❌ **握手挂死**（这是之前所有超时的真正原因） |
| `eth0` 统计 | 收发恒为 0（控制面走宿主，数据面不计入网卡） |

**结论：iSH 里只走 `http://` 源，不要用 `https://`。**
`apk` 源改成 http 后 `apk update` 一次成功。

## 4. apk 装包

两个坑：

1. **残留锁**：`/lib/apk/db/lock` 里 0 字节的锁文件会让所有 `apk` 命令报
   `Unable to lock database: Operation not permitted`（不是权限，是死锁）。删掉即可。
2. **源必须是 http**：见上一节。

实测结果：
- `apk update` → **25265 个包可用**
- 安装 **221 个包 / 334 MiB**，含 python3 / gcc / make / git / node / curl / sqlite 等

## 5. spawn 仍然被拦（与 iSH 无关）

- 现象：`posix_spawn failed (85)`，`errno 85 = EBADEXEC`
- 原因：rootHide 拒绝执行 App 容器内的第三方二进制，`ldid` 自己也在被拦之列
- 影响：依赖子进程的工具（原生 python3 / r2 / bsdtar）不可用；**iSH 内的进程不受影响**
- 排查：`diagnose toolchain`（看 `spawn_probe` 四类对照 + `spawn_verdict`）

## 6. 排查命令清单

```sh
# 网络真实连通性（别看 ping）
wget -q -O /dev/null http://mirrors.aliyun.com/alpine/v3.21/main/x86_64/APKINDEX.tar.gz && echo HTTP_OK
nc -z 155.102.1.28 443 && echo TCP_OK

# apk 死锁
rm -f /lib/apk/db/lock
apk update --no-progress

# 确认根挂载
cat /proc/mounts | grep ' / '
```
