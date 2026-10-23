#!/usr/bin/env python3
"""Small-file predownload (detached, best-effort).

Two modes, each with its own cap:
- local mode (record has vps_path): file_size <= auto-pull threshold
  (default 50MB, same as tg_pull). Same-machine copy first, then tg_pull.
- cloud mode (record has file_id, no vps_path): file_size <= 20MB
  (Telegram cloud hard cap). getFile + /file/ HTTP download.

Pulls now so the main agent sees file_local ready, instead of
waiting for a manual tg_pull. Failure leaves the record unchanged
(file_local stays None); the message itself is still delivered, so a
failed download never loses the message. Files near the threshold can
take minutes over a slow link in the background, but text handling is
not blocked by it. All failures are silent (exit 0) - predownload must
never block the poll loop or overwrite a marker with an error.
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import urllib.request

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


def _load_token(base):
    # .bot_token is 600; refuse to read it if permissions are too open.
    p = os.path.join(base, ".bot_token")
    try:
        if os.stat(p).st_mode & 0o077:
            _log("refusing: .bot_token permissions too open, should be 600")
            return None
        with open(p, encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return None


def _cloud_download(base, file_id, dest, size):
    """Cloud-mode download: getFile + /file/ HTTP. Returns True on
    success (size verified), False otherwise. Detached best-effort;
    failures are silent apart from the predownload log."""
    token = _load_token(base)
    if not token:
        return False
    api_base = (os.environ.get("TG_API_BASE_URL") or "https://api.telegram.org").rstrip("/")
    try:
        req = urllib.request.Request(
            f"{api_base}/bot{token}/getFile",
            data=json.dumps({"file_id": file_id}).encode(),
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            info = json.load(r)
        file_path = info["result"]["file_path"]
    except Exception as e:
        _log(f"getFile failed: {e}")
        return False
    url = f"{api_base}/file/bot{token}/{file_path}"
    # Per-operation timeout scales with size; the process is detached,
    # so a slow link just takes longer instead of blocking the poll loop.
    try:
        _to = max(300, int(size / (100 * 1024)) + 120)
    except Exception:
        _to = 300
    tmp = dest + ".tmp"
    try:
        with urllib.request.urlopen(url, timeout=_to) as r, open(tmp, "wb") as f:
            while True:
                chunk = r.read(1024 * 1024)
                if not chunk:
                    break
                f.write(chunk)
        os.replace(tmp, dest)
        return True
    except Exception as e:
        _log(f"cloud /file/ download failed: {e}")
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False


def main():
    if len(sys.argv) < 2:
        return 0
    inbox = sys.argv[1]
    try:
        rec = json.load(open(inbox, encoding="utf-8"))
    except Exception:
        return 0
    vps_path = rec.get("vps_path")
    file_id = rec.get("file_id")
    size = rec.get("file_size")
    base = os.path.dirname(os.path.abspath(__file__))
    if vps_path:
        # Local mode: cap follows the auto-pull threshold.
        try:
            max_bytes = int(rec.get("auto_pull_max") or (int(os.environ.get("TG_AUTO_PULL_MAX_MB", "50")) * 1024 * 1024))
        except Exception:
            max_bytes = 50 * 1024 * 1024
        if size is None or size > max_bytes:
            return 0
        dest = os.path.join(base, "inbox", "files", rec.get("file_name", os.path.basename(vps_path)))
        _cloud_done = False
    elif file_id and not rec.get("file_local"):
        # Cloud mode: 20MB hard cap (Telegram limit), never auto_pull_max.
        if size is None or size > 20 * 1024 * 1024:
            return 0
        dest = os.path.join(base, "inbox", "files", rec.get("file_name", file_id))
        # Directory must exist before _cloud_download opens dest.tmp.
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        _cloud_done = _cloud_download(base, file_id, dest, size)
        if not _cloud_done:
            _log(f"cloud download failed {inbox}")
            return 0
    else:
        return 0
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    try:
        if _cloud_done:
            pass  # cloud already downloaded above; go to size check
        elif os.path.isfile(vps_path):
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
