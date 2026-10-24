#!/usr/bin/env bash
# tg_finish.sh — TG 桥：一次调用完成 HANDLING.md 步骤 3 / 4 / 5
#
#   发送(分片) → 归档到 inbox/done/closed/ → 删 state/typing_active.json → 一次输出 JSON
#
# 设计原则:
#   * 文本走 --text-file 传入, 绝不经 shell 插值 → 彻底消灭转义/引号/换行事故
#   * 发送失败就不归档、不删 marker → 消息还在 processing/, 可以重试, 不丢
#   * 发送成功先写哨兵 state/sent/<batch_key>.json, 再归档 → 归档失败重跑不会重复发
#   * >4096 字自动分片(优先进制符边界), 避免 TG 拒收导致整段回复丢失
#   * 任何情况都 exit 0, 第一行是 JSON
#
# 用法:
#   ./tg_finish.sh --chat-id 8439335803 --text-file /tmp/reply.txt
#   ./tg_finish.sh --chat-id 8439335803 --stdin <<'EOF'     # 推荐: 正文直给, 一次调用搞定
#   回复正文
#   EOF
#   ./tg_finish.sh --chat-id 8439335803 --text-file /tmp/reply.txt --dry-run
#   ./tg_finish.sh --chat-id 8439335803 --text-file /tmp/reply.txt --batch-key 12345
#
# 输出 status:
#   closed          已发送并归档(正常收尾)
#   send_failed     发送失败: 消息保留在 processing/, marker 未动, 可重试
#   nothing_to_do   processing/ 空且无哨兵 → 说明没先 claim, 或已收尾过
#   bad_args        参数错 / 文本为空
#   dry_run         只演示, 不发不归档
set -uo pipefail

BASE="${TG_BRIDGE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
export TG_BRIDGE_DIR="$BASE"

CHAT_ID=""
TEXT_FILE=""
BATCH_KEY=""
DRY=0
USE_STDIN=0
_TMP_TEXT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --chat-id)    CHAT_ID="${2:-}"; shift 2 ;;
    --chat-id=*)  CHAT_ID="${1#*=}"; shift ;;
    --text-file)  TEXT_FILE="${2:-}"; shift 2 ;;
    --text-file=*) TEXT_FILE="${1#*=}"; shift ;;
    --stdin)      USE_STDIN=1; shift ;;
    --batch-key)  BATCH_KEY="${2:-}"; shift 2 ;;
    --batch-key=*) BATCH_KEY="${1#*=}"; shift ;;
    --dry-run)    DRY=1; shift ;;
    -h|--help)    sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "{\"status\":\"bad_args\",\"error\":\"unknown arg: $1\"}"; exit 0 ;;
  esac
done

# --stdin: 正文直接吃 heredoc, 少一次"写临时文件"的工具往返。
# 注意必须在这里先落盘: 下面的 python3 用的是它自己的 heredoc, 会占用 stdin。
if [ "$USE_STDIN" = "1" ]; then
  if [ -n "$TEXT_FILE" ]; then
    echo '{"status":"bad_args","error":"--stdin 与 --text-file 只能二选一"}'; exit 0
  fi
  _TMP_TEXT="$(mktemp "${TMPDIR:-/tmp}/tg_reply.XXXXXX")" || {
    echo '{"status":"bad_args","error":"mktemp 失败"}'; exit 0; }
  trap 'rm -f "$_TMP_TEXT"' EXIT
  cat > "$_TMP_TEXT"
  TEXT_FILE="$_TMP_TEXT"
fi

python3 - "$BASE" "$CHAT_ID" "$TEXT_FILE" "$BATCH_KEY" "$DRY" <<'PYEOF'
import json, os, re, subprocess, sys, time

BASE      = sys.argv[1]
CHAT_ID   = (sys.argv[2] or "").strip()
TEXT_FILE = (sys.argv[3] or "").strip()
BATCH_KEY = (sys.argv[4] or "").strip()
DRY       = sys.argv[5] == "1"

INBOX  = os.path.join(BASE, "inbox")
DONE   = os.path.join(INBOX, "done")
CLOSED = os.path.join(DONE, "closed")
PROC   = os.path.join(INBOX, "processing")
FILES  = os.path.join(INBOX, "files")
STATE  = os.path.join(BASE, "state")
SENT   = os.path.join(STATE, "sent")
MARKER = os.path.join(STATE, "typing_active.json")

TG_HELPER = os.path.expanduser(os.environ.get(
    "TG_HELPER", "~/workspace/custom-connectors/custom.telegram/bin/tg.py"))
CHUNK = 3900          # TG 单条上限 4096, 留余量
VALID = re.compile(r"^(\d+)\.json$")
T0 = time.time()


def log(msg):
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(os.path.join(STATE, "finish.log"), "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


def out(status, **kw):
    kw["status"] = status
    kw["elapsed_ms"] = int((time.time() - T0) * 1000)
    log("finish %s %s" % (status, " ".join(
        f"{k}={kw[k]}" for k in ("batch_key", "closed_count", "chunks", "sent")
        if k in kw)))
    print(json.dumps(kw, ensure_ascii=False))
    raise SystemExit(0)


def listing(d):
    res = []
    try:
        names = os.listdir(d)
    except OSError:
        return res
    for n in names:
        m = VALID.match(n)
        if m:
            res.append((int(m.group(1)), os.path.join(d, n)))
    res.sort()
    return res


def split_text(text, limit=CHUNK):
    """优先在换行处切, 其次硬切。保证每片 <= limit。"""
    text = text.strip()
    if len(text) <= limit:
        return [text] if text else []
    chunks, cur = [], ""
    for line in text.splitlines(keepends=True):
        while len(line) > limit:                 # 单行超长: 硬切
            if cur:
                chunks.append(cur); cur = ""
            chunks.append(line[:limit])
            line = line[limit:]
        if len(cur) + len(line) > limit:
            chunks.append(cur)
            cur = ""
        cur += line
    if cur.strip():
        chunks.append(cur)
    return [c for c in (c.strip() for c in chunks) if c]


for d in (PROC, CLOSED, FILES, STATE, SENT):
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        pass

if not CHAT_ID.isdigit():
    out("bad_args", error=f"--chat-id 必须是数字, 收到 {CHAT_ID!r}")
if not TEXT_FILE:
    out("bad_args", error="缺少 --text-file")
try:
    with open(TEXT_FILE, encoding="utf-8") as f:
        raw = f.read()
except Exception as e:
    out("bad_args", error=f"读不到 --text-file: {e}")

chunks = split_text(raw)
if not chunks:
    out("bad_args", error="回复文本为空, 不发不归档")

# ---------- 认批: 处理中的记录 ----------
proc = listing(PROC)
if not BATCH_KEY:
    BATCH_KEY = str(proc[-1][0]) if proc else "0"
try:
    sentinel_path = os.path.join(SENT, f"{int(BATCH_KEY)}.json")
except ValueError:
    sentinel_path = os.path.join(SENT, f"{BATCH_KEY}.json")

already_sent = False
try:
    with open(sentinel_path, encoding="utf-8") as f:
        already_sent = bool(json.load(f).get("ok"))
except Exception:
    already_sent = False

if not proc and not already_sent:
    out("nothing_to_do",
        note="processing/ 为空且无发送哨兵: 没先跑 tg_claim.sh, 或这批已收尾")

if DRY:
    out("dry_run", batch_key=BATCH_KEY, chunks=len(chunks),
        chars=sum(len(c) for c in chunks),
        would_send=chunks, would_archive=[os.path.basename(p) for _, p in proc])

# ---------- 步骤 3: 发送 ----------
if already_sent:
    sent = True            # 上次发成功了但归档没落: 这次只补归档, 绝不重复发
    send_err = None
else:
    sent, send_err, sent_ids = True, None, []
    for i, ch in enumerate(chunks, 1):
        ok = False
        for attempt in (1, 2):
            try:
                p = subprocess.run(
                    [sys.executable, TG_HELPER, "send", CHAT_ID, ch],
                    capture_output=True, text=True, timeout=60)
                try:
                    resp = json.loads((p.stdout or "").strip())
                    ok = bool(resp.get("ok"))
                except Exception:
                    ok = False
                if ok:
                    try:
                        sent_ids.append(resp.get("result", {}).get("message_id"))
                    except Exception:
                        sent_ids.append(None)
                    break
                send_err = ((p.stdout or "").strip()
                            or (p.stderr or "").strip())[-300:]
            except Exception as e:
                send_err = f"{type(e).__name__}: {e}"
            time.sleep(1)
        if not ok:
            sent = False
            break
    if sent:                                     # 先落哨兵, 再归档
        try:
            with open(sentinel_path + ".tmp", "w", encoding="utf-8") as f:
                json.dump({"ok": True, "time": time.time(), "batch_key": BATCH_KEY,
                           "chunks": len(chunks), "message_ids": sent_ids},
                          f, ensure_ascii=False)
            os.replace(sentinel_path + ".tmp", sentinel_path)
        except OSError:
            pass

if not sent:
    # 不归档、不删 marker: 消息留在 processing/, 下一个 handler 或重跑会接上
    out("send_failed", batch_key=BATCH_KEY, chunks=len(chunks),
        error=send_err,
        note="发送失败: 记录仍在 processing/, marker 未动; 修好 tg.py 后重跑本命令即可")

# ---------- 步骤 4: 归档 (含附件) ----------
closed_count, att_moved, closed_recs = 0, 0, []
for uid, p in proc:
    try:
        r = json.load(open(p, encoding="utf-8"))
        if isinstance(r, dict):
            closed_recs.append(r)
    except Exception:
        pass
    try:
        os.replace(p, os.path.join(CLOSED, os.path.basename(p)))
        closed_count += 1
    except OSError:
        pass

for r in closed_recs:                            # 下载的附件一起搬进 closed/
    fn = r.get("file_name")
    if not fn:
        continue
    src = os.path.join(FILES, fn)
    if not os.path.isfile(src):
        src = os.path.join(FILES, f"{r.get('update_id')}_{fn}")
    try:
        if os.path.isfile(src):
            os.replace(src, os.path.join(CLOSED, os.path.basename(src)))
            att_moved += 1
    except OSError:
        pass

# ---------- 步骤 5: 停 typing (一批只删一次) ----------
marker_cleared = False
if closed_count or already_sent:
    try:
        os.remove(MARKER)
        marker_cleared = True
    except OSError:
        pass

out("closed",
    batch_key=BATCH_KEY,
    closed_count=closed_count,
    attachments_moved=att_moved,
    chunks=len(chunks),
    sent=True,
    replayed_archive_only=already_sent,
    marker_cleared=marker_cleared,
    note="这批已收尾; 主聊天保持安静, 不要额外汇报技术细节")
PYEOF
