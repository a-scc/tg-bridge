#!/usr/bin/env python3
"""Small-file predownload (detached, best-effort).

Given an inbox JSON, if it has vps_path and file_size <= auto-pull
threshold (default 50MB, same as tg_pull), try to
pull it now so the main agent sees file_local ready, instead of
waiting for a manual tg_pull. Failure leaves the Bot API host marker unchanged
(record text already has the Bot API host note, file_local stays None).
Large files are NOT predownloaded here: above the threshold goes via Bot API host direct
send, never via the main-agent host. Files <=50MB are predownloaded in the
background (detached, sequential per file, never blocking poll);
a file near the threshold can take minutes over a slow link
in the background, but text handling is not blocked by it.
Transport order: same-machine copy first, then tg_pull.py if present.
All failures are silent (exit 0) - predownload must
never block the poll loop or overwrite a marker with an error.
"""
import json
import os
import shutil
import signal
import subprocess
import sys

# Cap follows the auto-pull threshold, not a separate 5MB guess:
# record auto_pull_max if present, else TG_AUTO_PULL_MAX_MB env, else 50MB.
# This keeps predownload consistent with tg_pull: <=50MB is pullable,
# >50MB is Bot API host direct send, never via main-agent host.

# Writeback race: the checker may move inbox/<uid>.json to inbox/done/<uid>.json while a
# slow pull is still running (files near the threshold via a slow link >> checker poll interval).
# Writing tmp+rename to the ORIGINAL inbox path would recreate
# the file in inbox/ while done/ still held the old copy -> next
# checker poll re-delivered it. Rule: update ONLY the copy that
# still exists (inbox first, then done), never recreate a missing one.
# If neither exists, do NOT write a record at all.
def _resolve_record(inbox_path):
    if os.path.isfile(inbox_path):
        return inbox_path
    done_path = os.path.join(os.path.dirname(inbox_path), "done", os.path.basename(inbox_path))
    if os.path.isfile(done_path):
        return done_path
    return None

def _log(msg):
    try:
        base = os.path.dirname(os.path.abspath(__file__))
        os.makedirs(os.path.join(base, "state"), exist_ok=True)
        with open(os.path.join(base, "state", "predownload.log"), "a", encoding="utf-8") as f:
            import time as _t
            f.write(f"{_t.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except Exception:
        pass


def main():
    if len(sys.argv) < 2:
        return 0
    inbox = sys.argv[1]
    try:
        rec = json.load(open(inbox, encoding="utf-8"))
    except Exception:
        return 0
    vps_path = rec.get("vps_path")
    size = rec.get("file_size")
    try:
        max_bytes = int(rec.get("auto_pull_max") or (int(os.environ.get("TG_AUTO_PULL_MAX_MB", "50")) * 1024 * 1024))
    except Exception:
        max_bytes = 50 * 1024 * 1024
    if not vps_path or size is None or size > max_bytes:
        return 0
    base = os.path.dirname(os.path.abspath(__file__))
    dest = os.path.join(base, "inbox", "files", rec.get("file_name", os.path.basename(vps_path)))
    try:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if os.path.isfile(vps_path):
            shutil.copyfile(vps_path, dest)
        else:
            # Try tg_pull (same-machine / SFTP env)
            pulled = False
            tg_pull = os.path.join(base, "tg_pull.py")
            if os.path.isfile(tg_pull):
                # Timeout scales with file size: near-threshold files can
                # take minutes on slow links (see README). Floor 180s plus
                # headroom for size at 100 KiB/s. Detached, never blocks poll.
                try:
                    _timeout = max(180, int(size / (100 * 1024)) + 60)
                except Exception:
                    _timeout = 180
                # New session: on timeout kill the whole process group.
                # Killing only tg_pull would orphan its sftp child,
                # which would keep writing dest in the background.
                _p = subprocess.Popen(
                    [sys.executable, tg_pull, inbox],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    start_new_session=True)
                try:
                    _p.communicate(timeout=_timeout)
                    pulled = _p.returncode == 0
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(_p.pid, signal.SIGKILL)
                    except Exception:
                        pass
                    _p.wait()
                    _log(f"tg_pull timeout after {_timeout}s {inbox}")
                    return 0
            else:
                pulled = False
            if not pulled:
                _log(f"pull failed {inbox}")
                return 0
            # tg_pull already updated file_local, if it did
            _log(f"pulled via tg_pull {inbox}")
            return 0
        if size is not None and os.path.getsize(dest) != size:
            _log(f"size mismatch {inbox} expected={size} got={os.path.getsize(dest)}")
            return 0
        # Test-only slow-pull hook: PREDOWNLOAD_WRITEBACK_DELAY seconds,
        # default 0. Used to reproduce hook-moves-before-writeback timing.
        try:
            _delay = float(os.environ.get("PREDOWNLOAD_WRITEBACK_DELAY", "0"))
        except ValueError:
            _delay = 0
        if _delay > 0:
            import time as _time
            _time.sleep(_delay)
        # Re-resolve at writeback time, not at read time.
        target = _resolve_record(inbox)
        if target is None:
            _log(f"record gone at writeback, not recreating {inbox}")
            return 0
        # Re-read target in case hook/other writer changed it, then set file_local.
        try:
            rec = json.load(open(target, encoding="utf-8"))
        except Exception:
            pass
        rec["file_local"] = dest
        tmp = target + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(rec, f, ensure_ascii=False)
        os.replace(tmp, target)
        _log(f"pulled {inbox} -> {target} file_local={dest}")
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
