# TG 消息本人处理清单 v2（工具轮次 6 → 2）

触发：hook worker 上报 reason + payload（标题"TG 消息待汐汐本人处理"）。

## 核心机制

1. **机会式合并**（不变）：被唤醒处理某条时，先扫一遍有没有新到的，一并回了。
2. **v2 改动**：把原来 6 步串行 shell 收成 2 个脚本。理由是每次 shell 往返都要过一次模型，
   6 次往返就是 6 次串行推理延迟（实测这条链 11–26 秒，大半花在这里）。

## 步骤（只剩两步）

### 第 1 步：认领

单条唤醒（payload 里有 `update_id`）：

```bash
bash ~/workspace/tg-bridge-deploy/tg_claim.sh --uid <update_id>
```

批唤醒（`WAKE tg-batch`，payload 里是 `batch_id` + `records`）：不带 `--uid`。

```bash
bash ~/workspace/tg-bridge-deploy/tg_claim.sh
```

读它输出的那一行 JSON，按 `status` 分支：

| status | 含义 | 你该做什么 |
|---|---|---|
| `claimed` | 已原子认领，可以回复 | 继续第 2 步 |
| `already_processed` | `closed/` 里已有 → 这是被压掉后迟到的唤醒 | **nothing_to_do**，主聊天保持安静 |
| `nothing_to_do` | 没东西可处理 | 安静 |
| `bad_args` | 参数错 | 安静（记进日志） |

`claimed` 时 JSON 里有你要的全部信息：`claim_id`（**第 2 步必须带上**，它标记这批归你）、
`records`（每条消息的 `text`/`kind`/`file_size`/`quoted`）、`attachments`（**已下好**，带
`local_path`，直接查看）、`over_cap`（超 20MB，没下）、`attachment_errors`（下载失败，但消息不丢）、
`chat_id`、`claimed_uids`。

`claim_id` 是这批的归属凭证：`tg_finish.sh` 只归档这个 id 名下的 uid，`processing/` 里别人的
记录一个字都不动。**两个 handler 同时跑也不会互相吞掉对方的消息。**

### 第 2 步：回复 + 收尾（一条命令）

正文用 heredoc 直给，**不要**再经过 shell 参数传文本（避免转义事故）：

```bash
bash ~/workspace/tg-bridge-deploy/tg_finish.sh \
  --chat-id <chat_id> --claim-id <claim_id> --stdin <<'TGEOF'
（这里是回复正文，简体中文、亲昵自然、简短，一批只回一条）
TGEOF
```

它一次完成：发送（>3900 字自动分片）→ 归档到 `inbox/done/closed/` → 附件一起搬 →
删 `state/typing_active.json`。所以**整条链只有 2 次工具调用**：claim + finish。

（heredoc 用带引号的 `'TGEOF'`，正文里的引号、反引号、`$`、反斜杠都会原样送出——已实测。
唯一禁忌：正文里不要出现单独一行的 `TGEOF`。）

| status | 含义 | 你该做什么 |
|---|---|---|
| `closed` | 已发已归档 | 结束，安静 |
| `send_failed` | 发送失败，记录仍留在 `processing/`，marker 未动 | 修好后**原样重跑同一条命令**；不要重写回复，不要手动 mv |
| `nothing_to_do` | 没先 claim，或这批已收尾 | 安静 |

## 已内置的保护（不需要你手动做）

- **幂等**：以 `inbox/done/closed/<update_id>.json` 为准。重复唤醒不会二次回复。
- **归属隔离**：`claim` 把本批 uid 写进 `state/claim/<claim_id>.json`，`finish` 只归档这批。
  别人的批（包括同时跑着的另一个 handler）**完全不碰**。新消息不会被塞进别人的批里一起归档掉。
- **死 handler 接管**：`processing/` 里的批**全部**超过 `TG_PROC_STALE_SECS`（默认 1800 秒）
  视为 handler 已死，下一次 claim 接管。`processing/` 不在 poller / checker / typing_loop 任何
  扫描路径里，没有这条兜底，handler 一崩消息就永久失踪。
  运维要立刻接管用 `tg_claim.sh --takeover`（只抢**没有归属记录**的孤儿文件；
  有 fresh 归属记录的活批即使加了 --takeover 也不会被抢）。
- **发送失败不归档**：避免"发出去了但没记录"或"记录没了但没发出去"。
- **分片可续发**：哨兵 `state/sent/<claim_id>.json` 里记着 `sent` 分片下标，每成功一片就落盘。
  中途失败重跑**从断点续发**，已成功的片不会重发。
- **超长分片**：单条 >3900 字自动切分（优先切在换行处），避免 TG 4096 上限直接拒收导致整段回复丢失。

## 竞态说明

- checker 可能在 `claim` 的 listdir 与 mv 之间把文件从 `inbox/` 搬到 `done/`（或反向）。
  `tg_claim.sh` 会重试另一个位置；两边都没有就记 `vanished`，不阻塞后面的消息。
- **两个 handler 并行**：各拿各的 `claim_id`，各归档各的批，互不影响。万一你手上没有
  `claim_id` 而 `state/claim/` 里有多份，`finish` 会拒绝执行并列出待收尾的 id —— 这是故意的，
  不猜比猜错安全。
- **不要**手动 `mv` / `rm` 这三个目录里的文件。要重试就原样重跑命令。

## 红线

- token 经连接器代换，绝不落盘、不进日志。
- 只处理 `claimed` 里给你的那批，不碰 `closed/`。
- 下载只用 `tg.py download`（已由 `tg_claim.sh` 代劳），不手拼 `/file/` URL。
- 主聊天保持安静：只有 `send_failed`、`over_cap` 需用户知情、deadletter 时才说话。
