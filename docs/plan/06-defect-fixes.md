# 6 项软件缺陷修复（P0-1 ~ P2-6）

> 来源：设备会话日志（env.setup_re 死循环 / python3 bind 失败 / spawn_verdict 误判）。

| 编号 | 缺陷 | 修复 | 验收 |
|---|---|---|---|
| P0-1 | 熔断只置标志、不终止 | 会话循环消费 `RunScope.consumeAbort(runToken)` 后 `return`；停止消息加 `[[RUN_TERMINATED]]`；子代理循环同样消费 | 连续两次同参失败 → 第二轮结束，回复以 `[[RUN_TERMINATED]]` 开头 |
| P0-2 | `env.setup_re` 无参必失败且分类错 | 新增 `action: list / report / setup`；`setup` 缺 `profile` 抛 `classified(PARAM_INVALID)` 并附 `action:list` 的 nextStep | `env.setup_re action:list` 返回批次；无参默认 `report` 只读盘点 |
| P0-3 | `spawn_verdict` 依据 `/usr/bin/true` 误判 | verdict 只看 `bundled_*`；`advice` 仅在有确证（签名器不可用 / 真补签过）时输出 | `diagnose command:toolchain` 的 verdict 与 spawn_probe 自洽 |
| P1-4 | python3 bind 段 `os.write(1)` 未保护、路径不可见、无异常输出 | bind 全程 try/except；回退目录改 `TMPDIR`；失败 `PyErr_Print()`；脚本路径 `realpath` + `/var`↔`/private/var` + errno 原文 | `python3 -c "print(1)"` 输出 1，无 `bind PyRun FAIL` |
| P1-5 | 原生 shell 整串判死、`/var` 前缀不归一 | 新增 `ShellSegmenter`：按 `; \| && \|\|` 切段、剥 `VAR=`、`/var→/private/var`、内建 `id/uname/command -v/echo`、展开简单 `for` 循环；不支持的段单独报错 | `B=/tmp id -u` 输出 uid；`command -v ls` 有结果；`/var/.../bin/jq --version` 与 `/private/var/...` 一致 |
| P2-6 | sqlite3/plutil 被当成「坏了」 | 新增 `ShimDetector`：`--version` 输出 Usage/占位符 → 判定 shim；`diagnose toolchain` 增加 `shims` 字段；SQL 验证改用 `db` 工具只读查询 | `diagnose command:toolchain` 的 `shims` 标出 sqlite3 |

## 验收命令（设备侧）

```
1) python3 -c "print(1)"            → 1
2) env.setup_re action:list          → 批次列表
3) 同一失败调用连按两次              → 第二轮终止（[[RUN_TERMINATED]]）
4) B=/tmp id -u                      → 0/501
5) diagnose command:toolchain        → spawn_verdict 与 spawn_probe 一致；shims 标出 sqlite3
```
