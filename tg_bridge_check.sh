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
# listener.py, tg_send.py, and the inbox/ and state/ directories.
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
# handling.
# If delivery fails, the record is still in done/ for recovery.
_DONE = os.path.join(INBOX, "done")
# Only numeric <update_id>.json files take part in delivery. A stray
# non-numeric .json (hand-placed, test leftovers, another program's)
# must never crash the sort and take the whole bridge down with it.
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
if not files:
    print("SILENT inbox-empty")
    print("{}")
    raise SystemExit

fname = files[0]
uid = fname.split(".")[0]
try:
    rec = json.load(open(os.path.join(INBOX, fname), encoding="utf-8"))
except Exception:
    rec = {"update_id": int(uid), "kind": "unreadable", "text": ""}
payload = dict(rec)
if len(payload.get("text") or "") > 6000:
    payload["text"] = payload["text"][:6000] + "\n[truncated; full record in inbox file]"
# Move to done BEFORE wake, so next poll picks the next file even if
# main chat reply is not via tg_send. Archive copy is in done/.
# Move failure: log + do NOT wake, file stays
# in inbox for next poll to retry the move.
if not DRY:
    os.makedirs(_DONE, exist_ok=True)
    try:
        os.replace(os.path.join(INBOX, fname), os.path.join(_DONE, fname))
    except OSError as _me:
        _log_hook(f"move to done failed {fname}: {_me}")
        print("SILENT move-failed")
        print(json.dumps({"update_id": int(uid), "error": str(_me)}, ensure_ascii=False))
        raise SystemExit
    # Create typing work marker for the refresher (hook wake time).
    # Cleared by tg_send --done / --ack-only when main chat replies.
    try:
        with open(os.path.join(STATE, "typing_active.json"), "w", encoding="utf-8") as _mf:
            json.dump({"update_id": int(uid), "chat_id": rec.get("chat_id"), "time": time.time()}, _mf)
    except OSError:
        pass
    payload["inbox_file"] = os.path.join(_DONE, fname)
else:
    payload["inbox_file"] = os.path.join(INBOX, fname)
print("WAKE tg-message")
print(json.dumps(payload, ensure_ascii=False))
PYEOF
)" || OUT="SILENT checker-error
{}"
# Standalone output: print exactly two lines, even if the Python
# section crashed. The caller (poller / hook system) interprets
# WAKE vs SILENT. A crash must not produce an empty stdout or a
# non-zero exit, or a poller reading two lines will read nothing.
printf '%s\n' "$OUT"
