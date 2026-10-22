#!/usr/bin/env python3
"""Telegram bridge listener (inbox-first).

Long-polls the Bot API for ONE owner's private chat, persists each message
to the inbox on disk BEFORE advancing the update offset, drops everything
from anyone else silently, and leaves a 👀 reaction as the receipt.
A separate hook checker wakes the main agent; this process never replies
with content.

Token: read from .bot_token (600) next to this file; if the file is absent
the listener idles until it appears. Proxy: HTTPS_PROXY env (set in unit).
Bot API base: TG_API_BASE_URL env, default https://api.telegram.org.
Set it to a local Bot API server (e.g. http://localhost:PORT via an SSH
tunnel, or http://<api-server>:PORT via private network) to use that server
instead; local servers are http, so they bypass the egress proxy.
"""
import fcntl
import json
import os
import shutil
import ssl
import sys
import time
import urllib.request
import urllib.error

# Simplified flow (do not revert to pulling large files to the main-agent host):
# Large files above the threshold: TG -> local Bot API once to Bot API host disk -> record path ->
# Bot API host metadata small notification -> Bot API host local direct send back to TG,
# never via the main-agent host. The main-agent host only receives the notification
# (what, size, Bot API host path), no bytes, no content check, no relay.
# Small files at or below the threshold: TG -> Bot API host disk -> main-agent host via tunnel pull -> verify
# size -> update record -> main chat attachment, kept.
# Text: TG -> listener poll -> main chat, as usual.
# Large-file notifications still go through listener, so deadletter,
# batching and watchdog still apply to text, small files and
# notifications; tg_pull fixes still apply to small files.
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TOKEN_FILE = os.path.join(BASE_DIR, ".bot_token")
INBOX_DIR = os.path.join(BASE_DIR, "inbox")
FILES_DIR = os.path.join(INBOX_DIR, "files")
STATE_DIR = os.path.join(BASE_DIR, "state")
OFFSET_FILE = os.path.join(STATE_DIR, "offset.txt")
HEARTBEAT_FILE = os.path.join(STATE_DIR, "heartbeat")
HISTORY_FILE = os.path.join(STATE_DIR, "tg_history.jsonl")
# Archive: append-only, one line per user message, rotated at 2000 -> 1000.
# No token, no file bytes, large files only path/size.
def _append_history(rec):
    try:
        line = {"ts": rec.get("date"), "role": "user", "kind": rec.get("kind"),
                "text": rec.get("text"), "message_id": rec.get("message_id"),
                "update_id": rec.get("update_id")}
        if rec.get("vps_path"):
            line["vps_path"] = rec["vps_path"]
            line["file_size"] = rec.get("file_size")
        with open(HISTORY_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(line, ensure_ascii=False) + "\n")
        # rotate: if >2000 lines, keep last 1000
        try:
            with open(HISTORY_FILE, encoding="utf-8") as f:
                lines = f.readlines()
            if len(lines) > 2000:
                with open(HISTORY_FILE, "w", encoding="utf-8") as f:
                    f.writelines(lines[-1000:])
        except OSError:
            pass
    except OSError:
        pass

def _spawn_typing_refresher(chat_id):
    # Typing refresher, separate process, NOT in tg_send.
    # Best-effort, never blocks poll loop. Refresher itself is singleton
    # via flock and stops when work is cleared (see typing_refresher.py).
    try:
        import subprocess
        script = os.path.join(BASE_DIR, "typing_refresher.py")
        if os.path.isfile(script):
            _logf = open(os.path.join(STATE_DIR, "typing_spawn.log"), "a", encoding="utf-8")
            subprocess.Popen([sys.executable, script, "--chat-id", str(chat_id)],
                             stdout=_logf, stderr=_logf,
                             start_new_session=True)
    except Exception:
        pass

def _spawn_predownload(inbox_path, rec):
    # Predownload: photo/document, at or below the auto-pull threshold.
    # Detached, best-effort, failure leaves the Bot API host marker unchanged.
    # Large files above the threshold are NOT predownloaded, Bot API host direct send only.
    try:
        import subprocess
        sz = rec.get("file_size")
        if rec.get("kind") not in ("photo", "document"):
            return
        _max = rec.get("auto_pull_max") or TG_AUTO_PULL_MAX
        if sz is None or sz > _max:
            return
        script = os.path.join(BASE_DIR, "predownload.py")
        if os.path.isfile(script):
            _logf = open(os.path.join(STATE_DIR, "predownload_spawn.log"), "a", encoding="utf-8")
            subprocess.Popen([sys.executable, script, inbox_path],
                             stdout=_logf, stderr=_logf,
                             start_new_session=True)
    except Exception:
        pass
# Owner ID: TG_OWNER_ID env var is REQUIRED.
# No hardcoded fallback: a missing env must fail fast, not silently
# send to a wrong owner.
# Env required at runtime, not at import, so --help works.
# main() validates before any send/poll.
try:
    OWNER_ID = int(os.environ.get("TG_OWNER_ID", "") or 0)
except ValueError:
    OWNER_ID = 0

# Batch grouping: same chat, within 20s, max 10 messages share a batch_id.
# Listener does NOT wait 20s for a single message (grace / drain is a
# checker / agent concern, listener only groups what it already has,
# so a single message is delivered immediately with batch_count=1).
# batch_count is ARRIVAL count, not unique message count:
# an edited message counts again (hook dedups by message_id). Batch
# state is in-memory only: listener restart resets it, so grouping is
# best-effort, not a strict guarantee. batch_id now carries a
# monotonically increasing seq to avoid same-second collisions
# (11th message in the same second previously reused the same id).
_BATCH = {"id": None, "start": 0, "count": 0, "seq": 0}

def _batch_id(chat_id, now):
    if (_BATCH["id"] is None or now - _BATCH["start"] > 20
            or _BATCH["count"] >= 10):
        _BATCH["seq"] += 1
        _BATCH["id"] = f"{chat_id}-{int(now)}-{_BATCH['seq']}"
        _BATCH["start"] = now
        _BATCH["count"] = 0
    _BATCH["count"] += 1
    return _BATCH["id"], _BATCH["count"]

# Auto-pull threshold, in bytes. Default 50MB, aligns with send cap.
# This constant is now real, not just a comment: tg_pull.py uses the same
# default, and handle_update records it in the inbox record.
try:
    TG_AUTO_PULL_MAX = int(os.environ.get("TG_AUTO_PULL_MAX_MB", "50")) * 1024 * 1024
except ValueError:
    TG_AUTO_PULL_MAX = 50 * 1024 * 1024

for d in (INBOX_DIR, FILES_DIR, STATE_DIR):
    os.makedirs(d, exist_ok=True)


def load_token():
    try:
        if os.stat(TOKEN_FILE).st_mode & 0o077:
            print("warning: .bot_token permissions too open, should be 600",
                  file=sys.stderr, flush=True)
        with open(TOKEN_FILE, encoding="utf-8") as f:
            tok = f.read().strip()
        return tok or None
    except OSError:
        return None


def make_opener():
    proxy = (os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
             or os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy"))
    if proxy:
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({"https": proxy, "http": proxy}))
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def api_base():
    return (os.environ.get("TG_API_BASE_URL") or "https://api.telegram.org").rstrip("/")


def is_local():
    # Explicit flag wins: a local API server can be https, so
    # sniffing "http://" alone misclassifies https local servers
    # as cloud. http:// is kept as an implicit local for back-compat.
    return os.environ.get("TG_API_LOCAL") == "1" or api_base().startswith("http://")


def api_url(token, method):
    return f"{api_base()}/bot{token}/{method}"


def file_url(token, path):
    return f"{api_base()}/file/bot{token}/{path}"


def get_opener():
    # Local Bot API servers (SSH tunnel / Tailscale, http or https)
    # must NOT go through the egress proxy, which only forwards TLS.
    # For https local servers, same unverified-context reasoning as
    # tg_send: private network, http local is already plain text.
    if is_local():
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(
                context=ssl._create_unverified_context()))
    return make_opener()


def api(token, method, params=None, timeout=70):
    url = api_url(token, method)
    data = None
    if params is not None:
        data = json.dumps(params).encode()
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/json"})
    with get_opener().open(req, timeout=timeout) as r:
        resp = json.loads(r.read().decode("utf-8", "replace"))
    if not resp.get("ok"):
        raise RuntimeError(f"Telegram API {method} failed: {resp.get('description')}")
    return resp


def read_offset():
    try:
        return int(open(OFFSET_FILE, encoding="utf-8").read().strip())
    except FileNotFoundError:
        return 0
    except Exception:
        print("warning: offset file corrupt, restarting from 0",
              file=sys.stderr, flush=True)
        return 0


def write_offset(value):
    tmp = OFFSET_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(str(value))
    os.replace(tmp, OFFSET_FILE)


def heartbeat():
    try:
        with open(HEARTBEAT_FILE, "w", encoding="utf-8") as f:
            f.write(str(int(time.time())))
    except OSError:
        pass


def download_file(token, file_id, dest):
    """Download a file. Local branch:
    - Cloud mode: getFile -> /file/ HTTP download (unchanged, 20MB cap).
    - Local mode: getFile returns an ABSOLUTE path on the local API
      server (e.g. /var/lib/telegram-bot-api/.../videos/file_0.mp4).
      If that server is on the same machine, read it directly.
      If it is on a different machine (main-agent host + remote Bot API host),
      do NOT try /file/ HTTP (local mode returns 404 for it in practice).
      Instead record the Bot API host path + size in the inbox record and
      return a special marker so the caller does NOT fail the message:
      the file is already on the Bot API host disk, and an on-demand SFTP
      pull (root, via the existing tunnel) can fetch it later.
      Small files (<=TG_AUTO_PULL_MAX, default 50MB) are NOT pulled by
      this function. They are pulled on demand by tg_pull.py, which
      the operator (or the hook, after delivery) runs against the
      inbox record. Large files need tg_pull.py --force. This keeps
      listener free of SFTP credentials and keeps the pull decision
      explicit, not silent.
    """
    info = api(token, "getFile", {"file_id": file_id}, timeout=30)
    result = info["result"]
    path = result["file_path"]
    size = result.get("file_size")
    if is_local() and isinstance(path, str) and path.startswith("/"):
        # Same-machine first: if the absolute path actually exists
        # on THIS machine (listener + local API on one box, or a
        # same-machine deploy), copy it directly and return.
        # Only if it does NOT exist here do we treat it as a remote
        # Bot API host path and signal handle_update to record vps_path instead of
        # trying /file/ HTTP (which returns 404 in local mode).
        if os.path.isfile(path):
            # File is verifiably local here. A copy failure is a
            # real failure, NOT a remote Bot API host case: do not fall through
            # to the Bot API host marker below, clean tmp and raise directly.
            import shutil as _sh
            _tmp = dest + ".tmp"
            try:
                _sz = os.path.getsize(path)
                _free = _sh.disk_usage(os.path.dirname(dest) or ".").free
                if _free < _sz + 10 * 1024 * 1024:
                    raise RuntimeError(f"not enough disk space for {_sz} bytes")
                _sh.copyfile(path, _tmp)
                os.replace(_tmp, dest)
                return dest
            except Exception as _ce:
                try:
                    os.remove(_tmp)
                except OSError:
                    pass
                raise RuntimeError(f"local copy failed for {path}: {_ce}")
        err = RuntimeError(f"local file on API server: {path} size={size}")
        err.vps_path = path
        err.file_size = size
        raise err
    if size:
        free = shutil.disk_usage(os.path.dirname(dest) or ".").free
        if free < size + 10 * 1024 * 1024:
            raise RuntimeError(f"not enough disk space for {size} bytes")
    url = file_url(token, path)
    tmp = dest + ".tmp"
    try:
        with get_opener().open(url, timeout=300) as r, open(tmp, "wb") as f:
            while True:
                chunk = r.read(1024 * 1024)
                if not chunk:
                    break
                f.write(chunk)
        os.replace(tmp, dest)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise
    return dest


def react(token, chat_id, message_id):
    try:
        api(token, "setMessageReaction", {
            "chat_id": chat_id,
            "message_id": message_id,
            "reaction": [{"type": "emoji", "emoji": "👀"}],
        }, timeout=15)
    except Exception:
        pass  # receipt is best-effort


def safe_file_name(uid, raw, default):
    r"""Sanitize a sender-supplied file name to a single file under
    inbox/files/: basename first, then replace separators and control chars.
    A name that collapses to . / .. / empty falls back to default."""
    base = os.path.basename(raw) if raw else default
    base = "".join("_" if c in "/\\" or ord(c) < 32 or ord(c) == 127 else c
                   for c in base).strip()
    if not base or base in (".", ".."):
        base = default
    return f"{uid}_{base}"


def handle_update(token, upd):
    edited = bool(upd.get("edited_message"))
    msg = upd.get("message") or upd.get("edited_message")
    if not msg:
        return True
    chat = msg.get("chat") or {}
    sender = msg.get("from") or {}
    if chat.get("type") != "private" or sender.get("id") != OWNER_ID or chat.get("id") != OWNER_ID:
        return True  # strangers and groups: dropped silently, offset still advances
    uid = upd["update_id"]
    rec = {
        "update_id": uid,
        "message_id": msg.get("message_id"),
        "chat_id": chat.get("id"),
        "from_id": sender.get("id"),
        "date": msg.get("date"),
        "kind": "other",
        "text": msg.get("text") or msg.get("caption") or "",
        "file_local": None,
        "file_name": None,
        "edited": edited,
        "media_group_id": msg.get("media_group_id"),
        "entities": msg.get("entities") or msg.get("caption_entities"),
    }
    file_id = None
    if msg.get("text"):
        rec["kind"] = "text"
    elif msg.get("photo"):
        rec["kind"] = "photo"
        file_id = msg["photo"][-1]["file_id"]
        rec["file_name"] = f"{uid}.jpg"
    elif msg.get("document"):
        rec["kind"] = "document"
        file_id = msg["document"]["file_id"]
        rec["file_name"] = safe_file_name(uid, msg["document"].get("file_name"), "file")
    elif msg.get("voice"):
        rec["kind"] = "voice"
        file_id = msg["voice"]["file_id"]
        rec["file_name"] = f"{uid}.ogg"
    elif msg.get("video"):
        rec["kind"] = "video"
        file_id = msg["video"]["file_id"]
        rec["file_name"] = f"{uid}.mp4"
    elif msg.get("audio"):
        rec["kind"] = "audio"
        file_id = msg["audio"]["file_id"]
        rec["file_name"] = safe_file_name(uid, msg["audio"].get("file_name"), "audio.mp3")
    elif msg.get("video_note"):
        rec["kind"] = "video_note"
        file_id = msg["video_note"]["file_id"]
        rec["file_name"] = f"{uid}.mp4"
    elif msg.get("animation"):
        rec["kind"] = "animation"
        file_id = msg["animation"]["file_id"]
        rec["file_name"] = f"{uid}.mp4"
    elif msg.get("sticker"):
        rec["kind"] = "sticker"
        rec["text"] = (msg["sticker"].get("emoji") or "") + " [sticker]"
    elif msg.get("location"):
        rec["kind"] = "location"
        loc = msg["location"]
        rec["text"] = f"[location {loc.get('latitude')},{loc.get('longitude')}]"
    elif msg.get("contact"):
        rec["kind"] = "contact"
        rec["text"] = f"[contact {msg['contact'].get('first_name', '')}]"
    elif msg.get("poll"):
        rec["kind"] = "poll"
        rec["text"] = msg["poll"].get("question", "")
    elif msg.get("venue"):
        rec["kind"] = "venue"
        rec["text"] = msg["venue"].get("title", "")
    rtm = msg.get("reply_to_message")
    if isinstance(rtm, dict):
        qfrom = rtm.get("from") or {}
        rec["quoted"] = {
            "message_id": rtm.get("message_id"),
            "from_name": qfrom.get("first_name") or qfrom.get("username"),
            "from_is_bot": bool(qfrom.get("is_bot")),
            "kind": ("text" if rtm.get("text")
                     else "photo" if rtm.get("photo")
                     else "document" if rtm.get("document")
                     else "video" if rtm.get("video")
                     else "audio" if rtm.get("audio")
                     else "video_note" if rtm.get("video_note")
                     else "animation" if rtm.get("animation") else "other"),
            "text": rtm.get("text") or rtm.get("caption") or "",
        }
    else:
        rec["quoted"] = None
    if file_id:
        dest = os.path.join(FILES_DIR, rec["file_name"])
        try:
            download_file(token, file_id, dest)
            rec["file_local"] = dest
        except Exception as e:
            # Local branch: file already on Bot API host disk, not a failure
            # of the message itself. Record Bot API host path/size, keep message.
            vps_path = getattr(e, "vps_path", None)
            if vps_path:
                rec["file_local"] = None
                rec["vps_path"] = vps_path
                rec["file_size"] = getattr(e, "file_size", None)
                rec["auto_pull_max"] = TG_AUTO_PULL_MAX
                _sz = getattr(e, "file_size", None)
                if _sz is not None and _sz <= TG_AUTO_PULL_MAX:
                    _note = f"\n[attachment on VPS: {vps_path} - run tg_pull.py to pull (<={int(TG_AUTO_PULL_MAX//1024//1024)}MB)]"
                else:
                    _note = f"\n[attachment on VPS: {vps_path} - large file, run tg_pull.py --force to pull]"
                rec["text"] = (rec["text"] + _note).strip()
            else:
                rec["text"] = (rec["text"] + f"\n[attachment download failed: {e}]").strip()
    tmp = os.path.join(INBOX_DIR, f"{uid}.json.tmp")
    final = os.path.join(INBOX_DIR, f"{uid}.json")
    _bid, _bcnt = _batch_id(rec.get("chat_id"), time.time())
    rec["batch_id"] = _bid
    rec["batch_count"] = _bcnt
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False)
    os.replace(tmp, final)
    _append_history(rec)
    _spawn_typing_refresher(rec["chat_id"])
    _spawn_predownload(final, rec)
    react(token, rec["chat_id"], rec["message_id"])
    return True


def acquire_singleton():
    # One listener only: a second process must exit, not fight over
    # getUpdates and end in a permanent 409 loop.
    lock_path = os.path.join(STATE_DIR, "listener.lock")
    f = open(lock_path, "a+")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("fatal: another listener is already running, exiting",
              file=sys.stderr, flush=True)
        sys.exit(2)
    return f


def _cleanup_tmp_after_lock():
    # Sweep stale tmp files ONLY after acquiring the singleton lock,
    # otherwise we could delete a running instance's tmp files.
    for d in (INBOX_DIR, FILES_DIR):
        try:
            for n in os.listdir(d):
                if n.endswith(".tmp"):
                    try:
                        os.remove(os.path.join(d, n))
                    except OSError:
                        pass
        except OSError:
            pass


def main():
    if not OWNER_ID:
        raise SystemExit("TG_OWNER_ID env var is required (numeric Telegram user id)")
    print("tg-bridge listener starting", flush=True)
    _lock = acquire_singleton()
    _cleanup_tmp_after_lock()
    failures = {}  # update_id -> consecutive failures (poison-message guard)
    while True:
        token = load_token()
        if not token:
            heartbeat()
            time.sleep(10)
            continue
        # Backpressure: if the agent is down, stop downloading more
        # instead of filling the disk with unprocessed inbox items.
        try:
            pending = sum(1 for n in os.listdir(INBOX_DIR)
                          if n.endswith(".json"))
        except OSError:
            pending = 0
        if pending >= 200:
            heartbeat()
            time.sleep(10)
            continue
        try:
            offset = read_offset()
            resp = api(token, "getUpdates", {
                "offset": offset,
                "timeout": 50,
                "allowed_updates": ["message", "edited_message"],
            }, timeout=70)
            for upd in resp.get("result", []):
                uid = upd.get("update_id")
                # Stale guard: if bot changed, Telegram may re-send
                # oldest pending update with update_id < offset. Skip it
                # instead of re-queueing forever.
                if uid is not None and uid < offset:
                    # A stale-only batch was re-fetched every poll with no
                    # log and no sleep. Log it and back off 2s. Do NOT
                    # auto-advance offset here: guard is NOT a bot-change
                    # solution, changing bot requires manual offset reset.
                    try:
                        with open(os.path.join(STATE_DIR, "stale.log"), "a", encoding="utf-8") as _sf:
                            _sf.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} stale update_id={uid} offset={offset}\n")
                    except OSError:
                        pass
                    print(f"stale update_id={uid} < offset={offset}, backing off (manual offset reset required if bot changed)",
                          file=sys.stderr, flush=True)
                    time.sleep(2)
                    continue
                try:
                    handle_update(token, upd)
                    failures.pop(uid, None)
                except Exception as e:
                    # Do NOT advance past a failed update, but do NOT
                    # block forever on a poison message either: after
                    # 3 failures, log it, skip it, and move on.
                    failures[uid] = failures.get(uid, 0) + 1
                    print(f"handle_update {uid} failed "
                          f"({failures[uid]}/3): {e}",
                          file=sys.stderr, flush=True)
                    if failures[uid] >= 3:
                        # Deadletter: write ONCE to state/deadletter.jsonl,
                        # NOT to inbox/claims (so it cannot re-trigger itself),
                        # then advance offset. This is the ONLY record left
                        # after offset advances, so it must carry the message
                        # content, not just update_id: message_id, kind,
                        # text/caption, vps_path, file_size, error, time.
                        # No token is ever written here.
                        # Checker consumption (required, not in this file):
                        # the checker must read state/deadletter.jsonl, report once,
                        # then move it to an archive file
                        # (or truncate it) - otherwise every round reading
                        # it again will repeat the alarm.
                        try:
                            _msg = upd.get("message") or upd.get("edited_message") or {}
                            _dl_rec = {
                                "update_id": uid,
                                "message_id": _msg.get("message_id"),
                                "kind": ("edited" if "edited_message" in upd else "message"),
                                "text": _msg.get("text") or _msg.get("caption"),
                                "vps_path": None,
                                "file_size": None,
                                "error": str(e),
                                "time": time.time(),
                            }
                            _dl = os.path.join(STATE_DIR, "deadletter.jsonl")
                            os.makedirs(STATE_DIR, exist_ok=True)
                            with open(_dl, "a", encoding="utf-8") as _f:
                                _f.write(json.dumps(_dl_rec, ensure_ascii=False) + "\n")
                        except OSError as _de:
                            # Deadletter write failure must NOT be silent:
                            # offset still advances, but log to stderr so the
                            # loss is visible in journalctl.
                            print(f"deadletter write failed for {uid}: {_de}", file=sys.stderr, flush=True)
                        failures.pop(uid, None)
                        write_offset(uid + 1)
                        continue
                    time.sleep(2)
                    break
                write_offset(upd["update_id"] + 1)
            heartbeat()
        except urllib.error.HTTPError as e:
            if e.code in (401, 409):
                print(f"fatal: getUpdates {e.code}, config/token error, exiting",
                      file=sys.stderr, flush=True)
                sys.exit(2)
            if e.code == 429:
                try:
                    body = json.loads(e.read().decode("utf-8", "replace"))
                    wait = body.get("parameters", {}).get("retry_after", 5)
                except Exception:
                    wait = 5
                print(f"getUpdates 429, backing off {wait}s",
                      file=sys.stderr, flush=True)
                time.sleep(wait + 1)
            else:
                print(f"getUpdates HTTP {e.code}; backing off",
                      file=sys.stderr, flush=True)
                time.sleep(5)  # 401 already exit(2) above, no 20s branch left
        except Exception as e:
            print(f"poll error: {e}", file=sys.stderr, flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
