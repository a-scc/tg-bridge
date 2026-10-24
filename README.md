# tg-bridge: Telegram ↔ Hatch 双向桥 (纯本人链路)

Telegram Bot API 到 Hatch 的桥：用户在 Telegram 发消息，桥捡起来唤醒 Hatch 里的本人处理，回复再经 Telegram 发回去。Worker 只当触发器，不冒名、不占位。

## 前置依赖

| 依赖 | 说明 |
|---|---|
| `python3` + `git` | 安装脚本会检查 |
| **`tg.py` 连接器** | **不在本仓库**。路径默认 `~/workspace/custom-connectors/custom.telegram/bin/tg.py`，可用 `TG_HELPER=` 覆盖 |
| Bot Token | 由 `tg.py` 所在的连接器（Secure Vault）持有，**不落盘、不进日志、不进本仓库** |
| systemd | 跑 poller；装服务时才需要 |
| Hatch hook | 每 5 秒调用 `bash tg_bridge_check.sh`，在 Hatch 侧配置 |

`poller.py`、`typing_loop.py`、`tg_claim.sh`、`tg_finish.sh` 四个文件全部通过 `tg.py` 收发。**没有连接器，装完是跑不起来的**，所以 `install.sh` 会先检查它，缺了直接退出。

## 安装

```bash
# 交互(会问要不要装 systemd 服务)
curl -fsSL https://raw.githubusercontent.com/a-scc/tg-bridge/main/install.sh | bash

# 非交互, 一次装完(推荐)
curl -fsSL https://raw.githubusercontent.com/a-scc/tg-bridge/main/install.sh \
  | TG_OWNER_ID=<你的数字id> TG_INSTALL_SYSTEMD=1 bash

# 已在仓库目录里
bash install.sh
```

⚠️ **`curl | bash` 下无法交互**（stdin 是脚本本身，不是终端）。此时 `install.sh` 会明确打印“跳过服务安装”并给出重跑命令，不会假装问过你。

可用环境变量：`TG_BRIDGE_DIR`（安装目录）、`TG_BRIDGE_USER`（服务运行用户）、`TG_BRIDGE_BRANCH`、`TG_HELPER`、`TG_OWNER_ID`、`TG_INSTALL_SYSTEMD`（`1`/`0`/`auto`）。

安装脚本会：克隆到 `~/workspace/tg-bridge-deploy/` → 建 `inbox/`、`state/`、`inbox/{done/closed,processing,files}`、`state/sent/` → 给三个脚本 `chmod +x` → （可选）注入路径并安装 systemd 单元。

## 安装后必须配置

1. **`TG_OWNER_ID`**：你自己的 Telegram 数字 id（给 `@userinfobot` 发条消息即可）。
   **这是单 owner 设计**：不匹配的消息会被静默丢弃。`poller.py` 没有内置默认值，未配置会直接退出。
2. **Bot Token**：由连接器提供，见上方前置依赖。
3. **Hatch hook**：每 5 秒调用一次 `bash ~/workspace/tg-bridge-deploy/tg_bridge_check.sh`。
   **必须用 `bash` 调用**（它本身不常驻，每次由 hook 起一个新进程）。
4. **可选环境变量**（改 unit 后 `systemctl daemon-reload && systemctl restart tg-bridge-poller`）：

| 变量 | 默认 | 作用 |
|---|---|---|
| `TG_DEFER_WHILE_BUSY_SECS` | 120 | S1 忙时压制：上一批还在处理时不为新消息再起 worker，最坏可让一条消息多等 120s。`0` = 关闭 |
| `TG_BATCH_GROUP_SECS` | 150 | 批量分组窗口。**只影响 `batch_id` 命名，不影响投递时刻**（checker 的 `BATCH_WINDOW=0` 才是立即投递的开关） |
| `TG_LONGPOLL_TIMEOUT` | 20 | 长轮询秒数。出口代理会掐 20–30s 的连接，所以别按上游默认的 50 |
| `TG_PROC_STALE_SECS` | 1800 | `processing/` 里的批全部超过这个时长才视为 handler 已死并接管（宁可晚救，不抢在跑的批）|

## 处理流程 (两步)

当前 `HANDLING.md` 是 2 步流程，整条链只有 2 次工具调用：

1. **认领**：`tg_claim.sh --uid <update_id>` (单条) 或 `tg_claim.sh` (批唤醒)
   返回 `claim_id`，第 2 步必须带上它
   - 幂等检查 (`closed/`) → 原子认领到 `inbox/processing/` → 扫全量 → 附件下载 → 一次输出 JSON
   - 状态：`claimed` / `already_processed` / `nothing_to_do` / `bad_args`
   - `--no-download` 可跳过附件下载，自己处理

2. **回复 + 收尾**：`tg_finish.sh --chat-id <chat_id> --claim-id <claim_id> --stdin <<'TGEOF'`
   - 发送 (超 3900 字自动分片) → 归档到 `inbox/done/closed/` → 附件一起搬 → 删 `state/typing_active.json`
   - 状态：`closed` / `send_failed` / `nothing_to_do` / `bad_args` / `dry_run`
   - `--dry-run` 只演示不发不归档；发送失败时原样重跑同一条命令即可（不会重复发）

**保护 (已内置，不需手动做)：**

- 幂等：以 `inbox/done/closed/<update_id>.json` 为准，重复唤醒不二次回复
- 归属隔离：`claim` 把本批 uid 写进 `state/claim/<claim_id>.json`，`finish` 只归档这批；两个
  handler 并行也互不吞消息（老版本会把新消息并进别人的批，然后被别人的 finish 顺手归档掉）
- 死 handler 接管：`processing/` 里的批全部超过 `TG_PROC_STALE_SECS` (默认 1800 秒) 视为已死，
  下一次 claim 接管；运维要立刻接管用 `tg_claim.sh --takeover`（只抢没有归属记录的孤儿，
  有 fresh 归属记录的活批不抢）
  —— **这条必须有**：`processing/` 不在 poller/checker/typing 任何扫描路径里，没有它 handler 一崩消息就永久失踪
- 发送失败不归档：消息留在 `processing/`，可重跑，不丢
- 分片可续发：哨兵 `state/sent/<claim_id>.json` 记着 `sent` 分片下标，每成功一片就落盘，
  中途失败重跑从断点续发，已成功的片不重发；全发完但归档失败则只补归档

## 文件清单

| 文件 | 说明 |
|---|---|
| `poller.py` | 长轮询 Telegram Bot API，写 `inbox/<update_id>.json`，启动 typing |
| `tg_bridge_check.sh` | Checker，每 5 秒由 hook 以 `bash` 运行，分组、投递、S1 压制、写 `wake_time` |
| `typing_loop.py` | 每约 4 秒发 typing，根据 `inbox/`、`done/`、marker 判断 pending |
| `tg_claim.sh` | 第 1 步：认领 (幂等 + 原子 + 扫全量 + 附件下载) |
| `tg_finish.sh` | 第 2 步：发送 + 归档 + 删 marker |
| `HANDLING.md` | 处理清单 (2 步流程) |
| `install.sh` | 一键安装 |
| `systemd/tg-bridge-poller.service` | systemd 单元**模板**，占位符由 `install.sh` 注入 |
| `.gitignore` | 忽略 `inbox/`、`state/`、`.bot_token`、日志 |
| `LICENSE` | MIT |

## 已知限制

- **桥内固定开销 0–5 秒**，主要来自 5 秒的 hook 轮询相位（均值 2.5s）。poller 侧检测 ≈0.3–0.5s，checker 自身 ≈0.05s。整体地板约 0.4s，需要改成事件驱动才拿得到，收益上限 2.5s。
- **更大的耗时在 Hatch 侧**（worker 派发 + handoff + 模型生成），不在本仓库里。
- **单 owner**：只接受 `TG_OWNER_ID` 一个人的私聊消息，其他发件人和群聊静默丢弃。
- 附件上限 20MB（`tg_claim.sh` 的 `MAX_BYTES`），超限只报尺寸不下载。

## 红线

- Token 经连接器代换，绝不落盘、不进日志。
- 只处理 `claimed` 里给你的那批，不碰 `closed/`。
- 下载只用 `tg.py download` (已由 `tg_claim.sh` 代劳)，不手拼 `/file/` URL。
- 主聊天保持安静：只有 `send_failed`、`over_cap` 需用户知情、deadletter 时才说话。
