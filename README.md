# tg-bridge: Telegram ↔ Hatch 双向桥 (纯本人链路)

Telegram Bot API 到 Hatch 的桥：用户在 Telegram 发消息，桥捡起来唤醒 Hatch 里的本人处理，回复再经 Telegram 发回去。Worker 只当触发器，不冒名、不占位。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/a-scc/tg-bridge/main/install.sh | bash
```

安装脚本会：克隆仓库到 `~/workspace/tg-bridge-deploy/` → 建 `inbox/`、`state/` 目录 → 提示安装 systemd 服务。

**安装完还需手动配置 (不在仓库里)：**
1. **Bot Token**：走连接器配置，绝不写进文件、不进日志 (见 `HANDLING.md` 红线)
2. **Hatch hook**：在 Hatch 里配置每 5 秒唤醒的 hook (`tg-bridge-wake`)
3. **生产环境变量**：按需修改 `systemd/tg-bridge-poller.service` 中的 `Environment` 行

## 处理流程 (两步)

当前 `HANDLING.md` 是 2 步流程，整条链只有 2 次工具调用：

1. **认领**：`tg_claim.sh --uid <update_id>` (单条) 或 `tg_claim.sh` (批唤醒)
   - 幂等检查 (`closed/`) → 原子认领到 `inbox/processing/` → 扫全量 → 附件下载 → 一次输出 JSON
   - 状态：`claimed` / `already_processed` / `overlapped` / `nothing_to_do` / `bad_args`

2. **回复 + 收尾**：`tg_finish.sh --chat-id <chat_id> --stdin <<'TGEOF'`
   - 发送 (超 3900 字自动分片) → 归档到 `inbox/done/closed/` → 附件一起搬 → 删 `state/typing_active.json`
   - 状态：`closed` / `send_failed` / `nothing_to_do` / `bad_args` / `dry_run`

**保护 (已内置，不需手动做)：**
- 幂等：以 `inbox/done/closed/<update_id>.json` 为准，重复唤醒不二次回复
- 重叠唤醒：`processing/` 里有活文件 = 上一个 handler 还在跑，新消息并进去，本进程直接退
- 死 handler 接管：`processing/` 滞留超 `TG_PROC_STALE_SECS` (默认 300 秒) 视为已死，接管这批
- 发送失败不归档：消息留在 `processing/`，可重跑，不丢
- 发送成功先落哨兵 `state/sent/<batch_key>.json` 再归档：归档失败重跑只补归档，不重复发

## 文件清单

| 文件 | 说明 |
|---|---|
| `poller.py` | 长轮询 Telegram Bot API，写 `inbox/<update_id>.json`，启动 typing |
| `tg_bridge_check.sh` | Checker，每 5 秒由 hook 运行，分组、投递、S1 压制、写 `wake_time` |
| `typing_loop.py` | 每约 4 秒发 typing，根据 `inbox/`、`done/`、marker 判断 pending |
| `tg_claim.sh` | 第 1 步：认领 (幂等 + 原子 + 扫全量 + 附件下载) |
| `tg_finish.sh` | 第 2 步：发送 + 归档 + 删 marker |
| `HANDLING.md` | 处理清单 (2 步流程) |
| `systemd/tg-bridge-poller.service` | systemd 服务单元 |
| `install.sh` | 一键安装脚本 |

## 红线

- Token 经连接器代换，绝不落盘、不进日志。
- 只处理 `claimed` 里给你的那批，不碰 `closed/`。
- 下载只用 `tg.py download` (已由 `tg_claim.sh` 代劳)，不手拼 `/file/` URL。
- 主聊天保持安静：只有 `send_failed`、`over_cap` 需用户知情、deadletter 时才说话。
