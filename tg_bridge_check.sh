#!/usr/bin/env bash
# TG bridge inbox checker: decides whether the main agent should be
# woken for a waiting Telegram message. Main-agent mode: deliver ONCE,
# move the inbox record to done/, no lease, no repeat, no head-of-line
# blocking.
#
# Standalone: this script does NOT depend on any host hook runtime.
# It prints two lines to stdout and exits 0, even on a checker
# crash (then: SILENT checker-error + {}):
#   line 1: WAKE tg-message | WAKE deadletter | SILENT <reason>
#   line 2: JSON payload
# Your poller (cron, systemd timer, or a hook system) reads those
# lines and decides what to do. Poll interval is set by your poller,
# not by this script.
#
# Bridge directory: set TG_BRIDGE_DIR to the directory that contains
# poller.py, tg_claim.sh, tg_finish.sh, and the inbox/ and state/ dirs.
# If TG_BRIDGE_DIR is not set, it defaults to the directory that
# contains this script (i.e. put all files in one directory).
set -euo pipefail
if [ -z "${TG_BRIDGE_DIR:-}" ]; then
  TG_BRIDGE_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
export TG_BRIDGE_DIR

OUT="$(python3 - <<'PYEOF'
import json, os, re, time
BASE = os.environ.get("TG_BRIDGE_DIR") or os.path.expanduser("~/tg-bridge")
INBOX = os.path.join(BASE, "inbox")
STATE = os.path.join(BASE, "state")
FAILED = os.path.join(STATE, "failed")
DRY = os.environ.get("TG_BRIDGE_DRY_RUN") == "1"
_VALID = re.compile(r"^\d+\.json$")

def _log_hook(msg):
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(os.path.join(STATE, "hook-errors.log"), "a", encoding="utf-8") as _ef:
            _ef.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass
# Deadletter consumption (per-line tolerant, not all-or-nothing:
# one bad line must not drop the whole file. Good lines wake,
# bad lines go to deadletter-bad-<ts>.jsonl, original is archived.)
_DL = os.path.join(STATE, "deadletter.jsonl")
if os.path.isfile(_DL) and os.path.getsize(_DL) > 0:
    _good, _bad = [], []
    for _l in open(_DL, encoding="utf-8"):
        if not _l.strip():
            continue
        try:
            _good.append(json.loads(_l))
        except Exception:
            _bad.append(_l.rstrip("\n"))
    _arch = os.path.join(STATE, f"deadletter-{int(time.time())}.jsonl")
    if not DRY:
        os.replace(_DL, _arch)
        if _bad:
            with open(os.path.join(STATE, f"deadletter-bad-{int(time.time())}.jsonl"), "w", encoding="utf-8") as _bf:
                _bf.write("\n".join(_bad) + "\n")
    if _good:
        print("WAKE deadletter")
        print(json.dumps({"deadletter": _good, "archived_to": _arch, "bad_lines": len(_bad)}, ensure_ascii=False))
        raise SystemExit
    else:
        print("SILENT deadletter-corrupt")
        print(json.dumps({"archived_to": _arch, "bad_lines": len(_bad)}, ensure_ascii=False))
        raise SystemExit

# Main-agent mode: deliver ONCE, then move to done. No lease,
# no repeat, no head-of-line blocking. The main agent's reply IS the
# handling. tg_finish.sh moves the record to done/closed/; records left in
# done/ get one unclosed-timeout re-wake.
_DONE = os.path.join(INBOX, "done")

# Batch coalescing: group inbox files by batch_id.
# 2026-10-23: BATCH_WINDOW/DRAIN set to 0 for the 本人 flow. The poller
# still tags batch_id (20s/10 window), and the checker still groups by
# it, but there is no wait: every poll wakes immediately with whatever
# is present. The 5s hook poll interval is the only batching now.
# (Before: waited BATCH_WINDOW+BATCH_DRAIN for the batch to close,
# which taxed single messages 25s. The 本人 handler deals messages
# as they arrive, so the wait is pure latency.)
BATCH_WINDOW = 0
BATCH_DRAIN = 0
BATCH_MAX = 10

def _move_to_done(fname):
    """Move inbox/fname to done/, stamping wake_time. Returns (done_path, rec)."""
    _sp = os.path.join(INBOX, fname)
    _dp = os.path.join(_DONE, fname)
    try:
        _rec = json.load(open(_sp, encoding="utf-8"))
        if not isinstance(_rec, dict):
            raise ValueError("not a dict")
    except Exception:
        _rec = {"kind": "unreadable", "text": ""}
    if "update_id" not in _rec:
        try:
            _rec["update_id"] = int(fname.split(".")[0])
        except ValueError:
            pass
    try:                                  # [测量用] 落盘时刻, 与 wake_time 同钟
        _rec["inbox_mtime"] = os.path.getmtime(_sp)
    except OSError:
        pass
    _rec["wake_time"] = time.time()
    _tp = _dp + ".tmp"
    with open(_tp, "w", encoding="utf-8") as _df:
        json.dump(_rec, _df, ensure_ascii=False)
    os.replace(_tp, _dp)
    try:
        os.remove(_sp)
    except OSError:
        pass
    return _dp, _rec

def _wake_marker(update_id, chat_id, batch_id=None):
    try:
        os.makedirs(STATE, exist_ok=True)
        _mk = {"update_id": int(update_id), "chat_id": chat_id, "time": time.time()}
        if batch_id:
            _mk["batch_id"] = batch_id
        with open(os.path.join(STATE, "typing_active.json"), "w", encoding="utf-8") as _mf:
            json.dump(_mk, _mf)
    except Exception:
        pass

def _trunc(text):
    if len(text or "") > 6000:
        return text[:6000] + "\n[truncated; full record in inbox file]"
    return text

def _typing_gone_or_stale(now):
    _mp = os.path.join(STATE, "typing_active.json")
    try:
        _m = json.load(open(_mp, encoding="utf-8"))
        _mt = _m.get("time")
        if isinstance(_mt, (int, float)) and now - _mt <= 120:
            return False
    except Exception:
        pass
    return True

_now = time.time()
files = []
_bad = []
if os.path.isdir(INBOX):
    for _f in os.listdir(INBOX):
        if not _f.endswith(".json"):
            continue
        if _VALID.match(_f):
            files.append(_f)
        else:
            _bad.append(_f)
    files.sort(key=lambda _f: int(_f.split(".")[0]))
# Quarantine the bad ones once: move to state/failed/ so they never
# block delivery again. The move itself is the once-guarantee, so the
# log line is written exactly once per file. Dry run changes nothing.
if _bad and not DRY:
    os.makedirs(FAILED, exist_ok=True)
    for _bf in sorted(_bad):
        try:
            os.replace(os.path.join(INBOX, _bf), os.path.join(FAILED, _bf))
            _log_hook(f"quarantined non-numeric inbox file {_bf}")
        except OSError:
            pass

# Group by batch_id.
_batches = {}
# _singles: records with no/invalid batch_id (e.g. corrupted JSON that failed
# to parse). They go through _move_to_done's {"kind": "unreadable"} fallback
# so a broken file still surfaces as "something is broken" instead of
# getting stuck in inbox forever. Do NOT delete this branch.
_singles = []
for _f in files:
    _p = os.path.join(INBOX, _f)
    try:
        _r = json.load(open(_p, encoding="utf-8"))
        _bid = _r.get("batch_id") if isinstance(_r, dict) else None
    except Exception:
        _bid = None
    if _bid:
        _batches.setdefault(_bid, []).append(_f)
    else:
        _singles.append(_f)

_closed = []  # (min_uid, bid, [fnames])
for _bid, _fs in _batches.items():
    _mts = []
    for _f in _fs:
        try:
            _mts.append(os.path.getmtime(os.path.join(INBOX, _f)))
        except OSError:
            pass
    if not _mts:
        continue
    if len(_fs) >= BATCH_MAX or _now - min(_mts) >= BATCH_WINDOW + BATCH_DRAIN:
        _closed.append((min(int(_f.split(".")[0]) for _f in _fs), _bid, _fs))

# Candidates: singles + closed batches, oldest first.
_cands = [(int(_f.split(".")[0]), None, [_f]) for _f in _singles]
_cands += _closed
if not _cands:
    # No deliverable inbox item. Before going silent, scan done/ for
    # unclosed timeouts (priority: deadletter > new inbox > re-wake).
    if not DRY and os.path.isdir(_DONE):
        _stuck = None
        for _f in os.listdir(_DONE):
            if not _f.endswith(".json"):
                continue
            _p = os.path.join(_DONE, _f)
            if not os.path.isfile(_p):
                continue
            try:
                _r = json.load(open(_p, encoding="utf-8"))
            except Exception:
                continue
            if not isinstance(_r, dict):
                continue
            _wt = _r.get("wake_time")
            if not isinstance(_wt, (int, float)):
                continue
            if _stuck is None or _wt < _stuck[0]:
                _stuck = (_wt, _f, _r)
        if _stuck:
            _wt, _f, _r = _stuck
            if _now - _wt > 600 and _typing_gone_or_stale(_now):
                _rc = _r.get("rewake_count", 0) or 0
                _p = os.path.join(_DONE, _f)
                if _rc < 1:
                    _r["rewake_count"] = _rc + 1
                    _r["wake_time"] = _now
                    _tp = _p + ".tmp"
                    with open(_tp, "w", encoding="utf-8") as _wf:
                        json.dump(_r, _wf, ensure_ascii=False)
                    os.replace(_tp, _p)
                    _wake_marker(_r.get("update_id"), _r.get("chat_id"))
                    print("WAKE unclosed-timeout")
                    print(json.dumps({
                        "kind": "unclosed-timeout",
                        "rewake": True,
                        "rewake_count": _r["rewake_count"],
                        "reason": "record in done/ not closed 10min after wake; typing marker gone/stale",
                        "record": _r,
                        "inbox_file": _p,
                    }, ensure_ascii=False))
                    raise SystemExit
                if not _r.get("rewake_alerted"):
                    _r["rewake_alerted"] = True
                    _tp = _p + ".tmp"
                    with open(_tp, "w", encoding="utf-8") as _wf:
                        json.dump(_r, _wf, ensure_ascii=False)
                    os.replace(_tp, _p)
                    _log_hook(f"unclosed-timeout alert, no re-wake (already re-woken once): {_f}")
    print("SILENT " + ("batch-open" if files else "inbox-empty"))
    print("{}")
    raise SystemExit

_cands.sort(key=lambda _c: _c[0])
_, _bid, _fs = _cands[0]

# --- 忙碌期压制: 上一个 handoff 还在处理时, 不为这批再起一个 worker ---
# 目的: 连发 k 条从 k*C 压成 1*C (C 是 Hatch 派发的固定成本)。
# 兜底: 记录等待超过 TG_DEFER_WHILE_BUSY_SECS 就照常投递, 处理者卡死不会饿死消息。
# 注意: TG_DEFER_WHILE_BUSY_SECS=0 表示关闭压制 (默认)。部署时在 Environment= 里设 120。
try:
    _SUPPRESS_MAX = int(os.environ.get("TG_DEFER_WHILE_BUSY_SECS", "0"))
except ValueError:
    _SUPPRESS_MAX = 0
if not DRY and _SUPPRESS_MAX > 0:
    _busy, _mage = False, None
    try:
        _m = json.load(open(os.path.join(STATE, "typing_active.json"), encoding="utf-8"))
        _mt = _m.get("time")
        if isinstance(_mt, (int, float)):
            _mage = _now - _mt
            _busy = _mage <= _SUPPRESS_MAX      # 只相信 SUPPRESS_MAX 以内的 marker
    except Exception:
        _busy = False
    if _busy:
        # 显式取 _fs, 不依赖前面是否已 unpack (推上游时位置可能不同)
        _fs = _cands[0][2]
        try:
            _wait = _now - min(os.path.getmtime(os.path.join(INBOX, _f)) for _f in _fs)
        except OSError:
            _wait = 0.0                         # 拿不到 mtime 就别压制, 宁可多醒一次
        if _wait < _SUPPRESS_MAX:
            _log_hook(f"handler-busy suppressed batch={_bid} wait={_wait:.1f}s "
                      f"marker_age={_mage:.1f}s")   # 便于事后确认真的压住了
            print("SILENT handler-busy")
            print(json.dumps({"batch_id": _bid,
                              "waiting_secs": round(_wait, 1),
                              "marker_age_secs": round(_mage, 1),
                              "suppress_max": _SUPPRESS_MAX}, ensure_ascii=False))
            raise SystemExit

if not DRY:
    os.makedirs(_DONE, exist_ok=True)

if _bid is None or len(_fs) == 1:
    # Single delivery: unchanged payload format.
    _fname = _fs[0]
    _uid = _fname.split(".")[0]
    if not DRY:
        try:
            _dp, _rec = _move_to_done(_fname)
        except OSError as _me:
            _log_hook(f"move to done failed {_fname}: {_me}")
            print("SILENT move-failed")
            print(json.dumps({"update_id": int(_uid), "error": str(_me)}, ensure_ascii=False))
            raise SystemExit
        _wake_marker(_uid, _rec.get("chat_id"))
        _payload = dict(_rec)
        _payload["text"] = _trunc(_payload.get("text"))
        _payload["inbox_file"] = _dp
    else:
        _payload = {"update_id": int(_uid), "kind": "unreadable", "text": ""}
        try:
            _r = json.load(open(os.path.join(INBOX, _fname), encoding="utf-8"))
            if isinstance(_r, dict):
                _payload = dict(_r)
        except Exception:
            pass
        _payload["text"] = _trunc(_payload.get("text"))
        _payload["inbox_file"] = os.path.join(INBOX, _fname)
    print("WAKE tg-message")
    print(json.dumps(_payload, ensure_ascii=False))
    raise SystemExit

# Batch delivery: move the whole batch, one wake.
_recs = []
_done_files = []
if not DRY:
    try:
        for _f in sorted(_fs, key=lambda x: int(x.split(".")[0])):
            _dp, _rec = _move_to_done(_f)
            _rec["text"] = _trunc(_rec.get("text"))
            _recs.append(_rec)
            _done_files.append(_dp)
    except OSError as _me:
        _log_hook(f"move to done failed batch {_bid}: {_me}")
        print("SILENT move-failed")
        print(json.dumps({"batch_id": _bid, "error": str(_me)}, ensure_ascii=False))
        raise SystemExit
    _wake_marker(max(int(_f.split(".")[0]) for _f in _fs),
                 _recs[0].get("chat_id") if _recs else None, _bid)
else:
    for _f in sorted(_fs, key=lambda x: int(x.split(".")[0])):
        try:
            _r = json.load(open(os.path.join(INBOX, _f), encoding="utf-8"))
            if not isinstance(_r, dict):
                _r = {}
        except Exception:
            _r = {}
        _r["text"] = _trunc(_r.get("text"))
        _recs.append(_r)
        _done_files.append(os.path.join(INBOX, _f))
print("WAKE tg-batch")
print(json.dumps({"batch_id": _bid, "count": len(_recs),
                  "records": _recs, "inbox_files": _done_files},
                 ensure_ascii=False))
raise SystemExit

PYEOF
)" || OUT="SILENT checker-error
{}"
# Standalone output: print exactly two lines, even if the Python
# section crashed. The caller (poller / hook system) interprets
# WAKE vs SILENT. A crash must not produce an empty stdout or a
# non-zero exit, or a poller reading two lines will read nothing.
printf '%s\n' "$OUT"
