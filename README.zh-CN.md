> 中文 | [English](README.md)

# Telegram bridge（收件箱优先，单次投递）

纯 Python 标准库，无外部依赖。

一句话介绍：一个 Telegram bot（Bot API）轮询**某一位**所有者的消息，把每条消息写成 `inbox/<update_id>.json`（有附件的顺手下载），检查脚本决定何时唤醒主 agent。主 agent 在自己的聊天里回复；回 TG 的消息走 `tg_send.py`。投递是**单次**的，不是"租约 + 重试"：唤醒时检查器把记录从 `inbox/` 搬到 `inbox/done/`，下一轮直接取下一条，不会被队头卡住。

## 文件

- `listener.py` —— 轮询 `getUpdates`、发表情回执、下载附件、写收件箱记录和 `state/tg_history.jsonl`（只记用户消息），写 `state/heartbeat` 心跳。
- `tg_send.py` —— 发文本 / 文件到 Telegram，长文本自动分段，用 `--done <update_id>` 或 `--ack-only <update_id>` 关闭一条收件箱记录（后者只关闭不发送）。关闭时会清掉打字中标记；已经在 `inbox/done/` 的记录保留作归档，只删它下载下来的文件。
- `tg_pull.py` —— 把收件箱记录里记为 `vps_path` 的文件拉回来，校验大小，并更新记录的 `file_local`。只更新还存在的副本（先找 `inbox/`，再找 `inbox/done/`），绝不复活已删除的记录。
- `typing_refresher.py` —— 独立进程，**不在** `tg_send.py` 里。有活干时每隔几秒发 `sendChatAction` 打字中。满足任一条件即视为有活：收件箱有文件、claims 有未结，或 `state/typing_active.json` 工作标记存在且未过期。唤醒时检查器创建标记；`tg_send.py --done` / `--ack-only` 清除标记。用 `state/typing.lock` 保证单例。
- `predownload.py` —— 分离式、尽力而为的小文件预下载：自动拉取阈值内（含）的 photo / document 记录。失败不改变 VPS 标记。同时只更新还存在的副本（先 `inbox/` 后 `inbox/done/`）。
- `tg_bridge_check.sh` —— 独立检查器。输出两行：第一行 `WAKE tg-message` / `WAKE deadletter` / `SILENT <原因>`，第二行 JSON。你的轮询器（cron、systemd timer 或 hook 系统）读这两行。轮询间隔由你的轮询器定，不是这个脚本。即使检查器自己崩了，也会输出 `SILENT checker-error` + `{}` 并以 0 退出，所以读两行的轮询器永远不会读到空输出（traceback 走 stderr，留着调试用）。

## 配置（全走环境变量，代码里不写死任何值）

| 变量 | 含义 | 默认值 |
|---|---|---|
| `TG_OWNER_ID` | 所有者的 Telegram 数字 ID（必填） | —— |
| `TG_API_BASE_URL` | Bot API 地址，云端或本地 Bot API 服务器 | `https://api.telegram.org` |
| `TG_API_LOCAL` | `1` = 本地 Bot API，绕过出口代理 | 未设置 |
| `TG_AUTO_PULL_MAX_MB` | 自动拉取阈值，单位 MB | `50` |
| `TG_BRIDGE_DIR` | 桥目录（检查器用） | 检查器脚本所在目录 |
| `TG_BRIDGE_DRY_RUN` | `1` = 检查器试运行，不搬记录 | 未设置 |
| `TG_TYPING_INTERVAL_SECS` | 打字中刷新间隔，秒 | `4` |
| `TG_TYPING_MAX_MINUTES` | 打字中硬上限，分钟 | `35` |
| `TG_SFTP_HOST`、`TG_SFTP_PORT`、`TG_SFTP_USER`、`TG_SFTP_KEY` | `tg_pull.py` 的 SFTP 拉取 | 未设置 |

默认值只是兜底，不是写死的上限：改环境变量即可。记录里的自动拉取阈值（`auto_pull_max`，listener 写入）优先于环境变量，同一条记录以后拉取时沿用当初记录的阈值。

## 部署

1. 去 BotFather 建 bot，拿到 token。
2. 把所有文件放进同一个目录，比如 `~/tg-bridge`。
3. 把 token 写进该目录下的 `.bot_token`，权限 `600`。**永远不要提交这个文件**，也不要把 token 粘进代码、issue 或聊天记录。token 文件如果组 / 其他可读，listener 会往 stderr 告警但照读不误——松权限不应该把线上部署搞挂。
4. 把 `TG_OWNER_ID` 设成你自己的 Telegram 数字 ID。只有这个人、且是私聊，消息才会被接收；其他人一律静默丢弃。
5. 跑 listener，比如做成 systemd 服务：`ExecStart=/usr/bin/python3 /path/to/tg-bridge/listener.py`，环境里带上 `TG_OWNER_ID`、`TG_API_BASE_URL`、`TG_API_LOCAL`。
6. 用你的轮询器定时跑 `tg_bridge_check.sh`。比如每隔几秒跑一次，读它输出的两行：`WAKE` 就把 payload 交给主 agent，`SILENT` 就什么都不做。
7. 主 agent 用 `tg_send.py` 回复，完事用 `--done <update_id>` 关闭（发完关）或 `--ack-only <update_id>` 关闭（只在主聊天回了，TG 这边不发）。

## 大文件（简化规则）

- 小于等于自动拉取阈值：文件拉到主 agent 这台机器（经 `tg_pull.py` / `predownload.py`），按大小校验，然后正常处理。
- 大于阈值：**不**经过主 agent 机器。文件留在 Bot API 那台机器上，记录为 `vps_path` + `file_size`，从那台机器直接发回 TG。主 agent 这边只收到一条短通知（是什么、多大、在 Bot API 机器上的哪条路径）。预下载是后台准备，不是即时加速：接近阈值的文件在慢链路上可能要几分钟，唤醒时 `file_local` 经常还是空的，这时用 `tg_pull.py` 按需拉。

## 这个包里没有的东西

- 无凭据、无 owner id、无 bot 用户名、无 IP 地址、无私有路径。所有跟机器相关的都是环境变量（见上表）。
- 无机器相关的拉取 / 隧道 helper。你的部署如果需要，自己在包外面加，把 `tg_pull.py` 的 SFTP 变量指过去；不要 hardcode 进来。
- 无配对 / owner 引导流程。owner 由 `TG_OWNER_ID` 定死；陌生人静默丢弃——对单 owner 的桥来说，比交互式配对更安全。
- 无自愈 hook。用你自己的 supervisor / watchdog；这个包只负责检查、单次投递、记日志。

## 日志和状态（不提交）

- `state/tg_history.jsonl` —— 用户消息归档，超过 2000 行时轮转保留最后 1000 行。目前只有 listener 写；不要在不加锁的情况下再加第二个写者。
- `state/typing.log`、`state/predownload.log`、`state/typing_spawn.log`、`state/predownload_spawn.log`、`state/stale.log`、`state/hook-errors.log` —— 启动 / 停止和失败日志，不记每次心跳。
- `state/deadletter.jsonl` —— 处理 3 次失败的记录。检查器按行消费：好的行唤醒，坏的行进 `deadletter-bad-<时间戳>.jsonl`，原文件无论如何都归档。如果整份都是坏行，检查器报 `SILENT`（不唤醒，但坏行已归档）。

## 许可证

自由使用、修改、再分发。分享任何副本时都别带上 `.bot_token`。
