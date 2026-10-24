#!/usr/bin/env bash
# tg_finish.sh — TG 桥：一次调用完成 HANDLING.md 步骤 3 / 4 / 5
#
#   发送(分片, 可续发) → 只归档本批 claim_id 名下的记录 → 删 marker → 一次输出 JSON
#
# 设计原则:
#   * 文本走 --stdin / --text-file 传入, 绝不经 shell 插值 → 消灭转义/引号/换行事故
#   * **只归档自己的批**: 按 --claim-id(优先) 或 --uids 确定本批 uid,
#     processing/ 里别人的记录一个字都不动 → 不会把别人没回过的新消息顺手归档掉
#   * 分片进度写进哨兵 state/sent/<claim_id>.json: 每成功一片就落盘
#     → 中途失败重跑从断点续发, 不重发已成功的片
#   * 发送失败就不归档、不删 marker → 消息还在 processing/, 可以重试
#   * 附件按 `_local_name`(claim 落盘时的真实名字) 搬, 不再靠猜 safe_name
#   * 任何情况都 exit 0, 第一行是 JSON
#
# 用法:
#   ./tg_finish.sh --chat-id <chat_id> --claim-id <claim_id> --stdin <<'TGEOF'
#   回复正文
#   TGEOF
#   ./tg_finish.sh --chat-id <chat_id> --uids 400,401 --text-file /tmp/reply.txt
#   ./tg_finish.sh --chat-id <chat_id> --claim-id <id> --text-file /tmp/r.txt --dry-run
#
# 输出 status:
#   closed          已发送并归档(正常收尾)
#   send_failed     发送失败: 消息保留在 processing/, marker 未动, 可重试(会从断点续发)
#   nothing_to_do   本批不在 processing/ 且无哨兵 → 没先 claim, 或已收尾过
#   bad_args        参数错 / 文本为空 / 无法判断本批归属
#   dry_run         只演示, 不发不归档
set -uo pipefail

BASE="${TG_BRIDGE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
export TG_BRIDGE_DIR="$BASE"

CHAT_ID=""
TEXT_FILE=""
CLAIM_ID=""
UIDS_ARG=""
DRY=0
USE_STDIN=0
_TMP_TEXT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --chat-id)     CHAT_ID="${2:-}"; shift 2 ;;
    --chat-id=*)   CHAT_ID="${1#*=}"; shift ;;
    --text-file)   TEXT_FILE="${2:-}"; shift 2 ;;
    --text-file=*) TEXT_FILE="${1#*=}"; shift ;;
    --claim-id)    CLAIM_ID="${2:-}"; shift 2 ;;
    --claim-id=*)  CLAIM_ID="${1#*=}"; shift ;;
    --uids)        UIDS_ARG="${2:-}"; shift 2 ;;
    --uids=*)      UIDS_ARG="${1#*=}"; shift ;;
    --batch-key)   UIDS_ARG="${2:-}"; shift 2 ;;     # 旧参数: 等价于单条 --uids
    --batch-key=*) UIDS_ARG="${1#*=}"; shift ;;
    --stdin)       USE_STDIN=1; shift ;;
    --dry-run)     DRY=1; shift ;;
    -h|--help)     sed -n '2,29p' "$0"; exit 0 ;;
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

python3 - "$BASE" "$CHAT_ID" "$TEXT_FILE" "$CLAIM_ID" "$UIDS_ARG" "$DRY" <<'PYEOF'
import json, os, re, subprocess, sys, time

BASE      = sys.argv[1]
CHAT_ID   = (sys.argv[2] or "").strip()
TEXT_FILE = (sys.argv[3] or "").strip()
CLAIM_ID  = (sys.argv[4] or "").strip()
UIDS_ARG  = (sys.argv[5] or "").strip()
DRY       = sys.argv[6] == "1"

INBOX  = os.path.join(BASE, "inbox")
DONE   = os.path.join(INBOX, "done")
CLOSED = os.path.join(DONE, "closed")
PROC   = os.path.join(INBOX, "processing")
FILES  = os.path.join(INBOX, "files")
STATE  = os.path.join(BASE, "state")
SENT   = os.path.join(STATE, "sent")
CLAIMD = os.path.join(STATE, "claim")
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
        f"{k}={kw[k]}" for k in ("claim_id", "closed_count", "chunks", "sent")
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


def read_json(p):
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except Exception:
        return None


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


for d in (PROC, CLOSED, FILES, STATE, SENT, CLAIMD):
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        pass

if not CHAT_ID.isdigit():
    out("bad_args", error=f"--chat-id 必须是数字, 收到 {CHAT_ID!r}")
if not TEXT_FILE:
    out("bad_args", error="缺少 --stdin 或 --text-file")
try:
    with open(TEXT_FILE, encoding="utf-8") as f:
        raw = f.read()
except Exception as e:
    out("bad_args", error=f"读不到 --text-file: {e}")

chunks = split_text(raw)
if not chunks:
    out("bad_args", error="回复文本为空, 不发不归档")

# ---------- 认批: 必须是"自己的那批" ----------
proc = listing(PROC)
proc_uids = set(u for u, _ in proc)

batch_uids, src = [], None
if UIDS_ARG:
    for x in re.split(r"[,\s]+", UIDS_ARG):
        if x.strip().isdigit():
            batch_uids.append(int(x.strip()))
    src = "--uids"
elif CLAIM_ID:
    d = read_json(os.path.join(CLAIMD, CLAIM_ID + ".json"))
    if d is None:
        out("bad_args", error=f"找不到归属记录 state/claim/{CLAIM_ID}.json",
            hint="claim_id 抄错? 或这批已收尾过。重新 tg_claim.sh 拿新的 claim_id")
    batch_uids = [int(x) for x in (d.get("uids") or [])]
    src = "claim_id"
else:
    # 兼容旧调用(没传 --claim-id): 只有一个未收尾的批时, 就是它
    pend = []
    try:
        pend = sorted(n[:-5] for n in os.listdir(CLAIMD) if n.endswith(".json"))
    except OSError:
        pass
    if len(pend) == 1:
        CLAIM_ID = pend[0]
        d = read_json(os.path.join(CLAIMD, CLAIM_ID + ".json")) or {}
        batch_uids = [int(x) for x in (d.get("uids") or [])]
        src = "唯一未收尾的 claim_id(隐式)"
    elif not proc:
        out("nothing_to_do",
            note="processing/ 为空且无待收尾的批: 没先跑 tg_claim.sh, 或已收尾")
    else:
        out("bad_args",
            error=f"state/claim/ 里有 {len(pend)} 个未收尾的批, 无法判断本批归属",
            pending_claims=pend,
            hint="把 tg_claim.sh 输出里的 claim_id 传给 --claim-id")

if not batch_uids:
    out("bad_args", error="本批 uid 列表为空, 无法归档",
        hint="重新跑 tg_claim.sh 拿新的 claim_id")

batch_set = set(batch_uids)
targets = [(u, p) for u, p in proc if u in batch_set]
leftovers = [u for u, _ in proc if u not in batch_set]

# ---------- 哨兵: 按 claim_id 定位, 含分片进度 ----------
sentinel_path, sentinel = None, None
if CLAIM_ID:
    sentinel_path = os.path.join(SENT, f"{CLAIM_ID}.json")
    sentinel = read_json(sentinel_path)
if sentinel is None:
    # 旧记录/uid 漂移: 按 uid 交集找(哨兵里记了 uids, 早期版本记的是 batch_key)
    try:
        names = sorted(os.listdir(SENT))
    except OSError:
        names = []
    for n in names:
        if not n.endswith(".json"):
            continue
        d = read_json(os.path.join(SENT, n))
        if not d:
            continue
        su = set()
        for x in (d.get("uids") or []):
            try:
                su.add(int(x))
            except (TypeError, ValueError):
                pass
        try:
            su.add(int(d.get("batch_key")))
        except (TypeError, ValueError):
            pass
        if su & batch_set:
            sentinel_path, sentinel = os.path.join(SENT, n), d
            break
if sentinel_path is None:
    sentinel_path = os.path.join(SENT, (CLAIM_ID or str(max(batch_uids))) + ".json")

already_sent = bool((sentinel or {}).get("ok"))
sent_done = set()
for x in ((sentinel or {}).get("sent") or []):
    try:
        sent_done.add(int(x))
    except (TypeError, ValueError):
        pass
sent_ids = list((sentinel or {}).get("message_ids") or [])


def write_sentinel(ok, sent_set):
    try:
        tmp = sentinel_path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"ok": bool(ok), "time": time.time(), "claim_id": CLAIM_ID or None,
                       "uids": sorted(batch_uids), "chunks": len(chunks),
                       "sent": sorted(sent_set), "message_ids": sent_ids},
                      f, ensure_ascii=False)
        os.replace(tmp, sentinel_path)
    except OSError as e:
        log(f"写哨兵失败 {sentinel_path}: {e}")


if not targets and not already_sent:
    out("nothing_to_do", claim_id=CLAIM_ID or None, batch_uids=sorted(batch_uids),
        left_in_processing=leftovers,
        note="本批已不在 processing/ (可能已归档)。processing/ 里的其他记录不属于本批, 未动")

if DRY:
    out("dry_run", claim_id=CLAIM_ID or None, batch_uids=sorted(batch_uids),
        uids_source=src, chunks=len(chunks), chars=sum(len(c) for c in chunks),
        already_sent=already_sent, resume_from=sorted(sent_done),
        would_archive=[os.path.basename(p) for _, p in targets],
        left_in_processing=leftovers, would_send=chunks)

# ---------- 步骤 3: 发送(可断点续发) ----------
if already_sent:
    sent, send_err = True, None      # 上次全发完但归档没落: 只补归档, 绝不重发
    resumed_from = []
else:
    sent, send_err = True, None
    resumed_from = sorted(sent_done)
    for i, ch in enumerate(chunks):
        if i in sent_done:           # 上一轮已经发成功过这一片
            continue
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
                        sent_ids.append((resp.get("result") or {}).get("message_id"))
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
        sent_done.add(i)
        write_sentinel(False, sent_done)      # 每成功一片就落盘 → 重跑从这里续
    if sent:
        write_sentinel(True, sent_done)

if not sent:
    # 不归档、不删 marker: 记录留在 processing/, 重跑会从断点续发
    out("send_failed", claim_id=CLAIM_ID or None, batch_uids=sorted(batch_uids),
        chunks=len(chunks), sent_chunks=sorted(sent_done), error=send_err,
        note="发送失败: 记录仍在 processing/, marker 未动。原样重跑本命令即可, "
             "已成功的分片不会重发")

# ---------- 步骤 4: 只归档本批 ----------
closed_count, att_moved, closed_recs, att_missing = 0, 0, [], []
for uid, p in targets:
    r = read_json(p)
    if r is not None:
        r.setdefault("update_id", uid)
        closed_recs.append(r)
    try:
        os.replace(p, os.path.join(CLOSED, os.path.basename(p)))
        closed_count += 1
    except OSError:
        pass


def find_attachment(r):
    """按记录里记的真实落盘名找, 再退回原名/uid_原名/按 uid 前缀扫。"""
    uid = r.get("update_id")
    cands = []
    if r.get("_local_name"):
        cands.append(os.path.join(FILES, r["_local_name"]))
    fn = r.get("file_name")
    if fn:
        cands.append(os.path.join(FILES, fn))
        cands.append(os.path.join(FILES, f"{uid}_{fn}"))
    for c in cands:
        if os.path.isfile(c):
            return c
    # 兜底: safe_name 会把空格/引号/反斜杠换成下划线, 按 uid 前缀扫一遍
    try:
        names = sorted(os.listdir(FILES))
    except OSError:
        names = []
    for n in names:
        if uid is not None and (n.startswith(f"{uid}_") or n.startswith(f"{uid}.")):
            return os.path.join(FILES, n)
    return None


for r in closed_recs:
    if not r.get("file_id"):
        continue
    src = find_attachment(r)
    if not src:
        att_missing.append(r.get("update_id"))
        continue
    try:
        os.replace(src, os.path.join(CLOSED, os.path.basename(src)))
        att_moved += 1
    except OSError:
        att_missing.append(r.get("update_id"))

# 本批收尾: 删掉归属记录
if CLAIM_ID and closed_count:
    try:
        os.remove(os.path.join(CLAIMD, CLAIM_ID + ".json"))
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
    claim_id=CLAIM_ID or None,
    batch_uids=sorted(batch_uids),
    uids_source=src,
    closed_count=closed_count,
    attachments_moved=att_moved,
    attachments_missing=att_missing,
    left_in_processing=leftovers,
    chunks=len(chunks),
    sent=True,
    resumed_from=resumed_from,
    replayed_archive_only=already_sent,
    marker_cleared=marker_cleared,
    note="本批已收尾; 主聊天保持安静, 不要额外汇报技术细节")
PYEOF
