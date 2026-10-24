#!/usr/bin/env bash
# tg_claim.sh — TG 桥：一次调用完成 HANDLING.md 步骤 0 / 0.5 / 1 / 2
#
#   幂等检查(closed/) → 原子认领到 inbox/processing/ → 扫全量 → 附件下载 → 一次输出 JSON
#
# 设计原则:
#   * 只有本脚本移动文件; mv/os.replace 同盘原子, 不会出现半写状态
#   * 幂等以 inbox/done/closed/<uid>.json 为准 (与 HANDLING.md 步骤 0 一致)
#   * processing/ 已有文件 = 重叠唤醒 → 把新扫到的一并塞进去, 然后退出, 绝不重复回复
#   * processing/ 滞留超过 TG_PROC_STALE_SECS (默认 300s) = 上一个 handler 死了 → 接管
#     (原 HANDLING 没有这个兜底, 而 processing/ 不在任何扫描路径里, 死了就是永久丢消息)
#   * 任何情况都 exit 0, 第一行是 JSON, 便于 agent 一次读取判分支
#
# 用法:
#   ./tg_claim.sh --uid 12345          # 单条唤醒: 带上 payload 里的 update_id (幂等键)
#   ./tg_claim.sh                      # 批唤醒 (WAKE tg-batch): 不传 uid
#   ./tg_claim.sh --uid 12345 --no-download
#
# 输出 status:
#   claimed            已认领, 去生成回复
#   already_processed  closed/ 已有 → 主聊天保持安静 (nothing_to_do)
#   overlapped         另一个 handler 在跑 → 保持安静
#   nothing_to_do      无待处理
#   bad_args           参数错
set -uo pipefail

BASE="${TG_BRIDGE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
export TG_BRIDGE_DIR="$BASE"

TRIGGER_UID=""
DOWNLOAD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --uid)          TRIGGER_UID="${2:-}"; shift 2 ;;
    --uid=*)        TRIGGER_UID="${1#*=}"; shift ;;
    --no-download)  DOWNLOAD=0; shift ;;
    -h|--help)      sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "{\"status\":\"bad_args\",\"error\":\"unknown arg: $1\"}"; exit 0 ;;
  esac
done

python3 - "$BASE" "$TRIGGER_UID" "$DOWNLOAD" <<'PYEOF'
import json, os, re, subprocess, sys, time

BASE     = sys.argv[1]
TRIGGER  = (sys.argv[2] or "").strip()
DOWNLOAD = sys.argv[3] == "1"

INBOX  = os.path.join(BASE, "inbox")
DONE   = os.path.join(INBOX, "done")
CLOSED = os.path.join(DONE, "closed")
PROC   = os.path.join(INBOX, "processing")
FILES  = os.path.join(INBOX, "files")
STATE  = os.path.join(BASE, "state")

TG_HELPER = os.path.expanduser(os.environ.get(
    "TG_HELPER", "~/workspace/custom-connectors/custom.telegram/bin/tg.py"))
MAX_BYTES = 20971520                     # 与 HANDLING.md / tg.py --max-bytes 一致
try:
    PROC_STALE = int(os.environ.get("TG_PROC_STALE_SECS", "300") or 300)
except ValueError:
    PROC_STALE = 300

VALID = re.compile(r"^(\d+)\.json$")
T0 = time.time()


def log(msg):
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(os.path.join(STATE, "claim.log"), "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


def out(status, **kw):
    """唯一的出口: 打一行 JSON, 永远 exit 0。"""
    kw["status"] = status
    kw["elapsed_ms"] = int((time.time() - T0) * 1000)
    log("claim %s %s" % (status, " ".join(
        f"{k}={kw[k]}" for k in ("batch_key", "count", "handed_over", "vanished")
        if k in kw)))
    print(json.dumps(kw, ensure_ascii=False))
    raise SystemExit(0)


def listing(d):
    """只认 ^\\d+\\.json$, 按 update_id 升序。目录/dotfile/.tmp 一律忽略。"""
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


def safe_name(raw, uid):
    base = os.path.basename(raw or "") or f"{uid}.bin"
    base = "".join("_" if c in "/\\ \"" or ord(c) < 32 or ord(c) == 127 else c
                   for c in base).strip()
    if not base or base in (".", ".."):
        base = f"{uid}.bin"
    return base if base.startswith(str(uid)) else f"{uid}_{base}"


for d in (PROC, CLOSED, FILES, STATE):
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        pass

# ---------- 步骤 0: 幂等检查 ----------
# 被 S1 压掉后迟到的唤醒、重叠唤醒都会走到这里: closed/ 里有 = 已回过, 不许再回。
if TRIGGER:
    if not TRIGGER.isdigit():
        out("bad_args", error=f"--uid 必须是数字, 收到 {TRIGGER!r}")
    if os.path.isfile(os.path.join(CLOSED, f"{TRIGGER}.json")):
        out("already_processed", update_id=int(TRIGGER),
            note="closed/ 已有该 update_id: 这条(或包含它的批)已回复过, 主聊天保持安静")

# ---------- 步骤 0.5: 重叠唤醒检测 / 死 handler 接管 ----------
proc = listing(PROC)
takeover = []                                # 滞留的孤儿批: 接管后直接算已认领
if proc:
    try:
        newest = max(os.path.getmtime(p) for _, p in proc)
    except OSError:
        newest = 0
    age = time.time() - newest
    if age <= PROC_STALE:
        # 上一个 handler 正在跑: 把新到的一并塞进去让它一起回, 本进程直接退出。
        moved = 0
        for _, p in listing(INBOX) + listing(DONE):
            try:
                os.replace(p, os.path.join(PROC, os.path.basename(p)))
                moved += 1
            except OSError:
                pass
        out("overlapped", processing_count=len(proc), handed_over=moved,
            processing_age_secs=round(age, 1),
            note="另一个 handler 正在处理这一批: 新到的已并入 processing/, 本进程不回复不归档")
    log(f"stale processing/ 接管: age={age:.1f}s > {PROC_STALE}s")
    takeover = proc

# ---------- 步骤 1: 全量认领 ----------
cands = listing(INBOX) + listing(DONE)
if not cands and not takeover:
    out("nothing_to_do", items=0, note="inbox/ 与 done/ 都没有待处理记录")

claimed, vanished = list(takeover), 0
for uid, p in cands:
    dst = os.path.join(PROC, os.path.basename(p))
    try:
        os.replace(p, dst)                       # 认领
        claimed.append((uid, dst))
        continue
    except OSError:
        pass
    # checker 可能在 listdir 与 replace 之间把它从 inbox/ 搬到了 done/ (或反向)
    alt = os.path.join(DONE if os.path.dirname(p) == INBOX else INBOX,
                       os.path.basename(p))
    try:
        os.replace(alt, dst)
        claimed.append((uid, dst))
    except OSError:
        vanished += 1                            # 真没了: 不阻塞, 记一笔

if not claimed:
    out("nothing_to_do", items=0, vanished=vanished,
        note="候选文件已被另一条路径取走")

claimed.sort()

# ---------- 步骤 2: 附件分类 + 下载 ----------
recs, to_dl, over_cap = [], [], []
for uid, path in claimed:
    try:
        r = json.load(open(path, encoding="utf-8"))
        if not isinstance(r, dict):
            raise ValueError
    except Exception:
        r = {"update_id": uid, "kind": "unreadable", "text": ""}
    r.setdefault("update_id", uid)
    fs = r.get("file_size") or 0
    if r.get("file_id"):
        item = {"update_id": uid, "file_id": r["file_id"],
                "file_name": r.get("file_name") or f"{uid}.bin", "file_size": fs}
        (over_cap if (fs and fs > MAX_BYTES) else to_dl).append(item)
    r["_claimed_path"] = path
    recs.append(r)

downloaded, dl_errors = [], []
if DOWNLOAD:
    for a in to_dl:
        dst = os.path.join(FILES, safe_name(a["file_name"], a["update_id"]))
        err = None
        try:
            p = subprocess.run(
                [sys.executable, TG_HELPER, "download", a["file_id"], dst,
                 "--max-bytes", str(MAX_BYTES)],
                capture_output=True, text=True, timeout=180)
            try:
                ok = bool(json.loads((p.stdout or "").strip()).get("ok"))
            except Exception:
                ok = False
            if ok and os.path.isfile(dst):
                a["local_path"] = dst
                downloaded.append(a)
                continue
            err = ((p.stdout or "").strip() or (p.stderr or "").strip())[-300:]
        except Exception as e:
            err = f"{type(e).__name__}: {e}"
        a["error"] = err
        dl_errors.append(a)
        try:                                     # 不丢消息: 失败也继续回复文字部分
            with open(os.path.join(STATE, "download-errors.log"), "a",
                      encoding="utf-8") as f:
                f.write(json.dumps({"time": time.time(),
                                    "update_id": a["update_id"],
                                    "file_id": a["file_id"], "error": err},
                                   ensure_ascii=False) + "\n")
        except OSError:
            pass

batch_key = claimed[-1][0]
chat_id = next((r.get("chat_id") for r in recs if r.get("chat_id")), None)

out("claimed",
    batch_key=batch_key,
    count=len(recs),
    chat_id=chat_id,
    records=recs,
    attachments=downloaded,
    attachment_errors=dl_errors,
    over_cap=over_cap,
    processing_dir=PROC,
    next_step=("生成一条回复(一批只回一条, 汐汐口吻), 写到临时文件, 然后: "
               f"tg_finish.sh --chat-id {chat_id} --text-file <path>"))
PYEOF
