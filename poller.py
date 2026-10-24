#!/usr/bin/env python3
"""TG bridge connector poller (Phase 1, cloud mode).

Replaces listener.py's network layer: instead of holding a bot token,
it shells out to the custom.telegram connector helper (tg.py), whose
credential lives in the Secure Vault and never touches disk.

Record format in inbox/<update_id>.json is byte-compatible with the
open-source tg-bridge listener.py, so tg_bridge_check.sh works unchanged.

Owner: TG_OWNER_ID env (required, no default — 未配置直接退出).
Bridge dir: this file's directory (inbox/, state/ underneath).
"""
import fcntl
import json
import os
import re
import subprocess
import sys
import time

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
INBOX_DIR = os.path.join(BASE_DIR, "inbox")
FILES_DIR = os.path.join(INBOX_DIR, "files")
STATE_DIR = os.path.join(BASE_DIR, "state")
OFFSET_FILE = os.path.join(STATE_DIR, "offset.txt")
HEARTBEAT_FILE = os.path.join(STATE_DIR, "heartbeat")
HISTORY_FILE = os.path.join(STATE_DIR, "tg_history.jsonl")
# 必须可覆盖: 不同机器上 helper 可能不在同一个连接器目录下。
# 默认值指向本机实际在用的那个 (2026-10 起 <home>/workspace/custom-connectors/custom.telegram/bin/tg.py)。
TG_HELPER = os.path.expanduser(os.environ.get(
    "TG_HELPER", "~/workspace/custom-connectors/custom.telegram/bin/tg.py"))

# 不内置默认 id: 配错/未配时必须响亮地失败, 而不是静默只认某一个人的消息。
_RAW_OWNER = (os.environ.get("TG_OWNER_ID") or "").strip()
try:
    OWNER_ID = int(_RAW_OWNER)
except ValueError:
    OWNER_ID = 0          # main() 会据此退出并给出提示

# Long-poll tuning: TG_LONGPOLL_TIMEOUT sets the getUpdates server-side
# wait (default 50, the repo profile's recommended default). The helper
# subprocess timeout is always server timeout + 20s. Override the env var
# in the systemd unit when the network kills long-lived TLS connections
# (this sandbox's egress proxy cuts connections held longer than ~20-30s,
# so the unit sets TG_LONGPOLL_TIMEOUT=20); then recalculate the watchdog
# heartbeat-stale threshold as 2x (server timeout + 20).
try:
    LONGPOLL_TIMEOUT = int(os.environ.get("TG_LONGPOLL_TIMEOUT", "50") or 50)
    if LONGPOLL_TIMEOUT <= 0:
        raise ValueError("non-positive long-poll timeout")
except ValueError:
    LONGPOLL_TIMEOUT = 50

_BATCH = {"id": None, "start": 0, "count": 0, "seq": 0}
# Batch grouping window: messages within this window share a batch_id,
# letting the checker deliver them in one WAKE. Under S1 suppression
# (busy-period), a larger window (120-180s) merges bursts for free —
# grouping window only affects batch_id assignment, not delivery timing.
# NOTE: GROUP_WINDOW=0 disables merging (each msg new id = each WAKE).
try:
    GROUP_WINDOW = max(0, int(os.environ.get("TG_BATCH_GROUP_SECS", "20")))
except ValueError:
    GROUP_WINDOW = 20
try:
    GROUP_MAX = max(1, int(os.environ.get("TG_BATCH_GROUP_MAX", "10")))
except ValueError:
    GROUP_MAX = 10


def _batch_id(chat_id, now):
    if (_BATCH["id"] is None or now - _BATCH["start"] > GROUP_WINDOW
            or _BATCH["count"] >= GROUP_MAX):
        _BATCH["seq"] += 1
        _BATCH["id"] = f"{chat_id}-{int(now)}-{_BATCH['seq']}"
        _BATCH["start"] = now
        _BATCH["count"] = 0
    _BATCH["count"] += 1
    return _BATCH["id"], _BATCH["count"]


def safe_file_name(uid, raw, default):
    base = os.path.basename(raw) if raw else default
    base = "".join("_" if c in "/\\ \"" or ord(c) < 32 or ord(c) == 127 else c
                   for c in base).strip()
    if not base or base in (".", ".."):
        base = default
    return f"{uid}_{base}"


def tg(*args, timeout=70):
    """Run the connector helper; return parsed JSON. Raise on transport error."""
    p = subprocess.run(
        [sys.executable, TG_HELPER, *args],
        capture_output=True, text=True, timeout=timeout)
    out = (p.stdout or "").strip()
    if p.returncode != 0:
        err = (p.stderr or "")[-300:]
        for code in ("401", "409", "429"):
            if f"HTTP Error {code}" in err:
                e = RuntimeError(f"tg.py HTTP {code}")
                e.http_code = int(code)
                if code == "429":
                    m = re.search(r"retry_after=(\d+)", err)
                    e.retry_after = int(m.group(1)) if m else 0
                raise e
        raise RuntimeError(f"tg.py failed rc={p.returncode}: {err}")
    try:
        return json.loads(out)
    except Exception as e:
        raise RuntimeError(f"tg.py bad JSON: {out[:120]}: {e}")


def _spawn_react(chat_id, message_id):
    # S2: the old react() ran inline here and blocked the poll loop for a
    # full helper-subprocess + HTTPS round trip, delaying the next getUpdates
    # (i.e. inflating A for a message arriving right behind). Now detached,
    # mirroring _spawn_typing_loop: fire-and-forget, best-effort, never
    # blocks. Helper stderr lands in typing_spawn.log for diagnosis.
    try:
        _logf = open(os.path.join(STATE_DIR, "typing_spawn.log"),
                     "a", encoding="utf-8")
        try:
            subprocess.Popen([sys.executable, TG_HELPER, "react",
                              str(chat_id), str(message_id)],
                             stdout=_logf, stderr=_logf,
                             start_new_session=True)
        finally:
            _logf.close()
    except Exception:
        pass


def _spawn_typing_loop(chat_id):
    # Typing loop, separate process.
    # Best-effort, never blocks the poll loop. Singleton via flock; stops
    # when work is cleared (see typing_loop.py).
    try:
        script = os.path.join(BASE_DIR, "typing_loop.py")
        if os.path.isfile(script):
            _logf = open(os.path.join(STATE_DIR, "typing_spawn.log"),
                         "a", encoding="utf-8")
            try:
                subprocess.Popen([sys.executable, script, str(chat_id)],
                                 stdout=_logf, stderr=_logf,
                                 start_new_session=True)
            finally:
                _logf.close()
    except Exception:
        pass


def read_offset():
    try:
        return int(open(OFFSET_FILE, encoding="utf-8").read().strip())
    except Exception:
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


def _append_history(rec):
    try:
        line = {"ts": rec.get("date"), "role": "user", "kind": rec.get("kind"),
                "text": rec.get("text"), "message_id": rec.get("message_id"),
                "update_id": rec.get("update_id")}
        with open(HISTORY_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(line, ensure_ascii=False) + "\n")
        try:
            with open(HISTORY_FILE, encoding="utf-8") as f:
                lines = f.readlines()
            if len(lines) > 2000:
                _tmp = HISTORY_FILE + ".tmp"
                with open(_tmp, "w", encoding="utf-8") as f:
                    f.writelines(lines[-1000:])
                os.replace(_tmp, HISTORY_FILE)
        except OSError:
            pass
    except OSError:
        pass


def handle_update(upd):
    edited = bool(upd.get("edited_message"))
    msg = upd.get("message") or upd.get("edited_message")
    if not msg:
        return True
    chat = msg.get("chat") or {}
    sender = msg.get("from") or {}
    if (chat.get("type") != "private" or sender.get("id") != OWNER_ID
            or chat.get("id") != OWNER_ID):
        return True  # strangers and groups: dropped silently
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
    file_size = None
    if msg.get("text"):
        rec["kind"] = "text"
    elif msg.get("photo"):
        rec["kind"] = "photo"
        file_id = msg["photo"][-1]["file_id"]
        file_size = msg["photo"][-1].get("file_size")
        rec["file_name"] = f"{uid}.jpg"
    elif msg.get("document"):
        rec["kind"] = "document"
        file_id = msg["document"]["file_id"]
        file_size = msg["document"].get("file_size")
        rec["file_name"] = safe_file_name(
            uid, msg["document"].get("file_name"), "file")
    elif msg.get("voice"):
        rec["kind"] = "voice"
        file_id = msg["voice"]["file_id"]
        file_size = msg["voice"].get("file_size")
        rec["file_name"] = f"{uid}.ogg"
    elif msg.get("video"):
        rec["kind"] = "video"
        file_id = msg["video"]["file_id"]
        file_size = msg["video"].get("file_size")
        rec["file_name"] = f"{uid}.mp4"
    elif msg.get("audio"):
        rec["kind"] = "audio"
        file_id = msg["audio"]["file_id"]
        file_size = msg["audio"].get("file_size")
        rec["file_name"] = safe_file_name(
            uid, msg["audio"].get("file_name"), "audio.mp3")
    elif msg.get("video_note"):
        rec["kind"] = "video_note"
        file_id = msg["video_note"]["file_id"]
        file_size = msg["video_note"].get("file_size")
        rec["file_name"] = f"{uid}.mp4"
    elif msg.get("animation"):
        rec["kind"] = "animation"
        file_id = msg["animation"]["file_id"]
        file_size = msg["animation"].get("file_size")
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
        rec["file_id"] = file_id
        if file_size is not None:
            rec["file_size"] = file_size
        # Cloud mode: never download synchronously here; tg_claim.sh fetches
        # it via the connector's getFile when the agent claims the batch.
        rec["text"] = (rec["text"]
                       + "\n[attachment pending cloud download]").strip()
    if edited:
        rec["batch_id"] = f"edited-{uid}"
        rec["batch_count"] = 1
    else:
        _bid, _bcnt = _batch_id(rec.get("chat_id"), time.time())
        rec["batch_id"] = _bid
        rec["batch_count"] = _bcnt
    tmp = os.path.join(INBOX_DIR, f"{uid}.json.tmp")
    final = os.path.join(INBOX_DIR, f"{uid}.json")
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False)
    os.replace(tmp, final)
    _append_history(rec)
    if not edited:
        _spawn_react(rec["chat_id"], rec["message_id"])
        _spawn_typing_loop(rec["chat_id"])
    return True


def acquire_singleton():
    lock_path = os.path.join(STATE_DIR, "poller.lock")
    f = open(lock_path, "a+")
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("fatal: another poller is already running, exiting",
              file=sys.stderr, flush=True)
        sys.exit(2)
    return f


def main():
    if not OWNER_ID:
        raise SystemExit("TG_OWNER_ID env var is required and must be numeric "
                         "(your own Telegram user id; get it from @userinfobot)")
    print("tg-bridge connector poller starting", flush=True)
    _lock = acquire_singleton()
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
    failures = {}
    _stale_seen = set()
    while True:
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
            resp = tg("getupdates", "--offset", str(offset),
                      "--timeout", str(LONGPOLL_TIMEOUT),
                      timeout=LONGPOLL_TIMEOUT + 20)
            if not resp.get("ok"):
                raise RuntimeError(f"getUpdates not ok: {resp}")
            for upd in resp.get("result", []):
                uid = upd.get("update_id")
                if uid is not None and uid < offset:
                    _key = (uid, offset)
                    if _key not in _stale_seen:
                        _stale_seen.add(_key)
                        try:
                            with open(os.path.join(STATE_DIR, "stale.log"),
                                      "a", encoding="utf-8") as _sf:
                                _sf.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} "
                                          f"stale update_id={uid} offset={offset}\n")
                        except OSError:
                            pass
                    time.sleep(2)
                    continue
                try:
                    handle_update(upd)
                    failures.pop(uid, None)
                except Exception as e:
                    failures[uid] = failures.get(uid, 0) + 1
                    print(f"handle_update {uid} failed "
                          f"({failures[uid]}/3): {e}", file=sys.stderr, flush=True)
                    if failures[uid] >= 3:
                        try:
                            _msg = (upd.get("message")
                                    or upd.get("edited_message") or {})
                            _dl_rec = {
                                "update_id": uid,
                                "message_id": _msg.get("message_id"),
                                "kind": ("edited" if "edited_message" in upd
                                         else "message"),
                                "text": _msg.get("text") or _msg.get("caption"),
                                "vps_path": None,
                                "file_size": None,
                                "error": str(e),
                                "time": time.time(),
                            }
                            with open(os.path.join(STATE_DIR, "deadletter.jsonl"),
                                      "a", encoding="utf-8") as _f:
                                _f.write(json.dumps(_dl_rec, ensure_ascii=False) + "\n")
                        except OSError:
                            pass
                        failures.pop(uid, None)
                        write_offset(uid + 1)
                        continue
                    time.sleep(2)
                    break
                write_offset(upd["update_id"] + 1)
            heartbeat()
        except RuntimeError as e:
            code = getattr(e, "http_code", None)
            if code in (401, 409):
                print(f"fatal: getUpdates {code}, exiting", file=sys.stderr, flush=True)
                sys.exit(2)
            if code == 429:
                wait = getattr(e, "retry_after", 0) or 5
                print(f"getUpdates 429, backing off {wait}s",
                      file=sys.stderr, flush=True)
                time.sleep(wait + 1)
            else:
                print(f"poll error: {e}; backing off", file=sys.stderr, flush=True)
                time.sleep(5)
        except Exception as e:
            print(f"poll error: {e}", file=sys.stderr, flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
