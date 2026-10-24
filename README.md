# tg-bridge: Telegram ↔ Hatch 双向桥 (纯本人链路)

Telegram Bot API 到 Hatch 的桥：用户在 Telegram 发消息，桥捡起来唤醒 Hatch 里的本人处理，回复再经 Telegram 发回去。Worker 只当触发器，不冒名、不占位。

## 前置依赖

| 依赖 | 说明 |
|---|---|
| `python3` + `git` | 安装脚本会检查 |
| **`tg.py` 连接器** | **不在本仓库**。实际路径 `~/workspace/custom-connectors/custom.telegram/bin/tg.py`，可用 `TG_HELPER=` 覆盖。`install.sh` 会**真打一次 `getupdates` 验它**，不通过就中止安装。⚠️ 这个文件虽然住在 `custom.telegram`（看着像旧注册目录），但**它是在用的那个，别删目录** |
| Bot Token | 由 `tg.py` 所在的连接器（Secure Vault）持有，**不落盘、不进日志、不进本仓库** |
| systemd | 跑 poller；装服务时才需要 |
| Hatch hook | 每 5 秒调用一次，命令里带上 checker 侧要用的环境变量（见"安装后必须配置"第 4 条）|

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

**安装前的 helper 自检会拦住"活死人"**：只查文件在不在是不够的——helper 不认 `getupdates` 时，
systemd 照样显示 active、日志里刷 `poll error`，但一条消息都捡不到。所以 `install.sh` 会

1. **离线**给 5 个子命令各塞一个假参数：argparse 报 `invalid choice` 就是缺这个命令（不联网、不发消息）；
2. 当前**没有桥在跑**时，再**真打一次** `getupdates --timeout 1 --offset 0`，必须返回 `{"ok": true}`。
   `offset=0` 不会确认任何待处理消息，真 poller 之后照拿不误；有桥在跑时跳过这一步，免得把它打成 409。

任一不通过就中止，**什么都不装**（连 clone 都不做）。确实只想装代码不启用服务时用 `--force`。

⚠️ **`curl | bash` 下无法交互**（stdin 是脚本本身，不是终端）。此时 `install.sh` 会明确打印“跳过服务安装”并给出重跑命令，不会假装问过你。

可用环境变量：`TG_BRIDGE_DIR`（安装目录）、`TG_BRIDGE_USER`（服务运行用户）、`TG_BRIDGE_BRANCH`、`TG_HELPER`、`TG_OWNER_ID`、`TG_INSTALL_SYSTEMD`（`1`/`0`/`auto`）。

安装脚本会：克隆到 `~/workspace/tg-bridge-deploy/` → 建 `inbox/`、`state/`、`inbox/{done/closed,processing,files}`、`state/sent/` → 给三个脚本 `chmod +x` → （可选）注入路径并安装 systemd 单元。

## 安装后必须配置

1. **`TG_OWNER_ID`**：你自己的 Telegram 数字 id（给 `@userinfobot` 发条消息即可）。
   **这是单 owner 设计**：不匹配的消息会被静默丢弃。`poller.py` 没有内置默认值，未配置会直接退出。
2. **Bot Token**：由连接器提供，见上方前置依赖。
3. **Hatch hook**：每 5 秒调用一次。checker 的环境变量**只能写在这里**（它不是 systemd 子进程）：

   ```bash
   TG_DEFER_WHILE_BUSY_SECS=120 bash ~/workspace/tg-bridge-deploy/tg_bridge_check.sh
   ```
   **必须用 `bash` 调用**（它本身不常驻，每次由 hook 起一个新进程）。
4. **环境变量：先分清是谁在读**，放错层等于没配。

   - `poller.py` 是 systemd 服务 → 写在 unit 的 `Environment=` 里**有效**。
   - `tg_bridge_check.sh` 由 Hatch hook 拉起、`tg_claim.sh` / `tg_finish.sh` 由 agent shell 拉起，
     **都不是 systemd 的子进程** → 写进 unit 读不到，必须写在**调用方**的环境里。

| 变量 | 默认 | 读它的 | 该写在哪 |
|---|---|---|---|
| `TG_OWNER_ID` | 必填 | poller | unit |
| `TG_LONGPOLL_TIMEOUT` | 20 | poller | unit |
| `TG_BATCH_GROUP_SECS` | 150 | poller | unit（只影响 `batch_id` 命名，不影响投递时刻）|
| `TG_HELPER` | 见前置依赖 | poller / typing_loop / claim / finish | unit + hook + agent 环境（三处，或不设用默认）|
| `TG_DEFER_WHILE_BUSY_SECS` | 0 | checker | **hook 的命令行**，例：`TG_DEFER_WHILE_BUSY_SECS=120 bash <dir>/tg_bridge_check.sh` |
| `TG_PROC_STALE_SECS` | 1800 | claim | 一般不用改；要改就在调用 claim 的环境里 export |
| `TG_BATCH_GROUP_MAX` | 10 | poller | unit（单批最多消息数，超了立即闭合投递）|
| `TG_TYPING_INTERVAL_SECS` | 4 | typing_loop | typing_loop 环境（每几秒发一次 typing）|
| `TG_TYPING_MAX_MINUTES` | 35 | typing_loop | typing_loop 环境（typing 最长持续分钟数，超时自动停）|

   ⚠️ 注意 `TG_DEFER_WHILE_BUSY_SECS` 的默认是 **0（关闭）**。unit 里以前那行 `=120` 从来没生效过
   （checker 读不到），已删除；想开启必须写在 hook 命令上。

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
| `tg_bridge_check.sh` | Checker，每 5 秒由 hook 以 `bash` 运行，分组、投递、忙时压制、写 `wake_time` |
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
- **心跳 stale 阈值**：按 `2 × (TG_LONGPOLL_TIMEOUT + 20)` 算，`TG_LONGPOLL_TIMEOUT=20` → **80 秒**。
  Hatch 侧 keepalive 若还写着 150 秒（那是按上游默认 50 秒长轮询算的旧值；本仓库代码默认值已改成 20 秒），只是漏检更久、不会误杀；
  建议改成 80–90 秒。`state/heartbeat` 由 `poller.py` 写，读它的在 Hatch 侧。
- **checker 计时常量**：typing-stale 120 秒（marker 超 120 秒没更新视为已消失）；unclosed 重唤 10 分钟（`done/` 里滞留超 600 秒且 typing 已消失时再唤醒一次，防丢消息）。这两个只在 `tg_bridge_check.sh` 代码里，改不了配置。
- **单 owner**：只接受 `TG_OWNER_ID` 一个人的私聊消息，其他发件人和群聊静默丢弃。
- 附件上限 20MB（`tg_claim.sh` 的 `MAX_BYTES`），超限只报尺寸不下载。

## 红线

- Token 经连接器代换，绝不落盘、不进日志。
- 只处理 `claimed` 里给你的那批，不碰 `closed/`。
- 下载只用 `tg.py download` (已由 `tg_claim.sh` 代劳)，不手拼 `/file/` URL。
- 主聊天保持安静：只有 `send_failed`、`over_cap` 需用户知情、deadletter 时才说话。
