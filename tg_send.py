#!/usr/bin/env python3
"""Telegram bridge sender + inbox bookkeeping.

Usage:
  tg_send.py --text "..." [--reply-to <message_id>] [--done <update_id>]
  tg_send.py --stdin [--reply-to <message_id>] [--done <update_id>]
  tg_send.py --document <path> [--caption "..."] [--reply-to <message_id>] [--done <update_id>]
  tg_send.py --ack-only <update_id>          # close an inbox item without sending
  tg_send.py --claim-refresh <update_id>     # renew the handling lease

Sends plain text (no parse mode), splitting at 4096 chars on newline
boundaries when possible. On successful send with --done, removes the
inbox file and clears its claim. Token from .bot_token (600).
Bot API base: TG_API_BASE_URL env, default https://api.telegram.org;
set it to a local Bot API server (e.g. http://localhost:PORT via an SSH
tunnel) to send via that server instead. Local uploads stream the file
instead of loading it whole into memory; cloud uploads are capped by
Telegram at 50 MB, local uploads at 2 GB per file.
"""
import argparse
import contextlib
import fcntl
import http.client
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
TOKEN_FILE = os.path.join(BASE_DIR, ".bot_token")
INBOX_DIR = os.path.join(BASE_DIR, "inbox")
FILES_DIR = os.path.join(INBOX_DIR, "files")
STATE_DIR = os.path.join(BASE_DIR, "state")
CLAIMS_FILE = os.path.join(STATE_DIR, "claims.json")
# Owner chat: TG_OWNER_ID env var is REQUIRED.
# Env required at runtime, not at import, so --help works.
# main() validates before any send/poll.
try:
    OWNER_CHAT = int(os.environ.get("TG_OWNER_ID", "") or 0)
except ValueError:
    OWNER_CHAT = 0

os.makedirs(STATE_DIR, exist_ok=True)


def load_token():
    try:
        if os.stat(TOKEN_FILE).st_mode & 0o077:
            print("warning: .bot_token permissions too open, should be 600",
                  file=sys.stderr, flush=True)
        with open(TOKEN_FILE, encoding="utf-8") as f:
            tok = f.read().strip()
    except OSError:
        raise SystemExit("bot token file not found: put .bot_token (600) next to tg_send.py")
    if not tok:
        raise SystemExit("bot token file is empty: put the bot token in .bot_token (600)")
    return tok


def api_base():
    return (os.environ.get("TG_API_BASE_URL") or "https://api.telegram.org").rstrip("/")


def is_local():
    # Explicit flag wins: a local API server can be https, so
    # sniffing "http://" alone misclassifies https local servers
    # as cloud. http:// is kept as an implicit local for back-compat.
    return os.environ.get("TG_API_LOCAL") == "1" or api_base().startswith("http://")


def api_url(token, method):
    return f"{api_base()}/bot{token}/{method}"


def make_opener():
    # Local Bot API servers must NOT go through the egress proxy,
    # which only forwards TLS. For https local servers, use an
    # unverified context: the server is on a private network, and
    # http local is already plain text, so this is not a downgrade.
    if is_local():
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(
                context=ssl._create_unverified_context()))
    proxy = (os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
             or os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy"))
    if proxy:
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({"https": proxy, "http": proxy}))
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def api(token, method, params, timeout=30):
    req = urllib.request.Request(
        api_url(token, method),
        data=json.dumps(params).encode(), method="POST",
        headers={"Content-Type": "application/json"})
    # 429 is safe to retry: the server refused before processing.
    # Other HTTP errors are not retried, because a retry could
    # duplicate a message whose response was lost.
    for attempt in range(3):
        try:
            with make_opener().open(req, timeout=timeout) as r:
                resp = json.loads(r.read().decode("utf-8", "replace"))
            break
        except urllib.error.HTTPError as e:
            if e.code != 429 or attempt == 2:
                body = ""
                try:
                    body = e.read().decode("utf-8", "replace")[:500]
                except Exception:
                    pass
                raise SystemExit(
                    f"Telegram API {method} HTTP {e.code}: {body}")
            try:
                body = json.loads(e.read().decode("utf-8", "replace"))
                wait = body.get("parameters", {}).get("retry_after", 5)
            except Exception:
                wait = 5
            time.sleep(wait + 1)
    # Never trust resp["result"] blindly. On ok:false, fail loudly
    # here, before any --done marking, so a partial send is not
    # silently claimed as complete. Callers that must not stop on
    # failure (typing indicator) already catch Exception.
    if not resp.get("ok"):
        raise SystemExit(f"Telegram API {method} failed: {resp.get('description')}")
    return resp


def send_document(token, path, caption="", reply_to=None, timeout=1200):
    """Send a file via sendDocument. Local (http) uploads stream the
    file in 1 MiB chunks via http.client; cloud (https) uploads go
    through the proxy opener and are therefore built in memory, which
    is acceptable only because cloud caps files at 50 MB."""
    if not os.path.isfile(path):
        raise SystemExit(f"document not found: {path}")
    # Fail fast before reading the file: a cloud upload over 50 MB
    # (or a local one over 2 GB) will be rejected anyway.
    size = os.path.getsize(path)
    limit = 2000 * 1024 * 1024 if is_local() else 50 * 1024 * 1024
    if size > limit:
        raise SystemExit(f"document too large: {size} bytes > {limit} bytes")
    # A quote or newline in the file name would break the multipart
    # header, so sanitize it the same way the listener sanitizes
    # sender-supplied names.
    name = "".join("_" if c in '"\r\n' else c
                   for c in os.path.basename(path)) or "file"
    # Bot API caption limit is 1024 chars; the overflow, if any, is
    # returned to the caller so it can be sent as a follow-up text.
    cap, overflow = caption[:1024], caption[1024:]
    boundary = uuid.uuid4().hex
    if is_local():
        parsed = urllib.parse.urlparse(api_base())
        # Local servers are on a private network (SSH tunnel /
        # Tailscale), where http is already plain text, so an
        # unverified https context is not a downgrade from that.
        if parsed.scheme == "https":
            conn = http.client.HTTPSConnection(
                parsed.hostname, parsed.port or 443, timeout=timeout,
                context=ssl._create_unverified_context())
        else:
            conn = http.client.HTTPConnection(
                parsed.hostname, parsed.port or 80, timeout=timeout)
        try:
            # Real telegram-bot-api rejects Transfer-Encoding: chunked
            # with HTTP 400.
            # Stream with a precomputed Content-Length instead: build
            # the small field parts in memory, add the file size, then
            # send field bytes + file chunks + closing bytes, never
            # loading the file itself into memory.
            def _field_bytes(k, v):
                return (f'--{boundary}\r\n'
                        f'Content-Disposition: form-data; name="{k}"\r\n\r\n'
                        f'{v}\r\n').encode()
            head_parts = [_field_bytes("chat_id", str(OWNER_CHAT))]
            if cap:
                head_parts.append(_field_bytes("caption", cap))
            if reply_to:
                head_parts.append(_field_bytes("reply_parameters", json.dumps({"message_id": reply_to})))
            head_parts.append(f'--{boundary}\r\n'
                              f'Content-Disposition: form-data; name="document"; '
                              f'filename="{name}"\r\n'
                              f'Content-Type: application/octet-stream\r\n\r\n'.encode())
            tail = f'\r\n--{boundary}--\r\n'.encode()
            total = sum(len(p) for p in head_parts) + size + len(tail)
            conn.putrequest("POST", f"/bot{token}/sendDocument")
            conn.putheader("Content-Type",
                           f"multipart/form-data; boundary={boundary}")
            conn.putheader("Content-Length", str(total))
            conn.endheaders()
            for part in head_parts:
                conn.send(part)
            with open(path, "rb") as f:
                while True:
                    data = f.read(1024 * 1024)
                    if not data:
                        break
                    conn.send(data)
            conn.send(tail)
            resp = conn.getresponse()
            body = resp.read().decode("utf-8", "replace")
            if resp.status >= 400:
                raise SystemExit(f"sendDocument HTTP {resp.status}: {body[:500]}")
            parsed = json.loads(body)
            if not parsed.get("ok"):
                raise SystemExit(f"Telegram API sendDocument failed: {parsed.get('description')}")
            return parsed, overflow
        finally:
            conn.close()
    # Cloud path: build the multipart body in memory (<=50 MB by API).
    parts = []
    def _field_bytes(k, v):
        parts.append(f'--{boundary}\r\n'
                     f'Content-Disposition: form-data; name="{k}"\r\n\r\n'
                     f'{v}\r\n'.encode())
    _field_bytes("chat_id", str(OWNER_CHAT))
    if cap:
        _field_bytes("caption", cap)
    if reply_to:
        _field_bytes("reply_parameters", json.dumps({"message_id": reply_to}))
    parts.append(f'--{boundary}\r\n'
                 f'Content-Disposition: form-data; name="document"; '
                 f'filename="{name}"\r\n'
                 f'Content-Type: application/octet-stream\r\n\r\n'.encode())
    with open(path, "rb") as f:
        parts.append(f.read())
    parts.append(f'\r\n--{boundary}--\r\n'.encode())
    req = urllib.request.Request(
        api_url(token, "sendDocument"), data=b"".join(parts), method="POST",
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    with make_opener().open(req, timeout=timeout) as r:
        parsed = json.loads(r.read().decode("utf-8", "replace"))
    if not parsed.get("ok"):
        raise SystemExit(f"Telegram API sendDocument failed: {parsed.get('description')}")
    return parsed, overflow


def split_text(text, limit=4096):
    chunks = []
    rest = text
    while len(rest) > limit:
        cut = rest.rfind("\n", 0, limit)
        if cut < limit // 2:
            cut = limit
            chunks.append(rest[:cut])
            rest = rest[cut:]
        else:
            # Cut at the newline itself: drop only that one newline,
            # not all following blank lines.
            chunks.append(rest[:cut])
            rest = rest[cut + 1:]
    if rest:
        chunks.append(rest)
    return chunks


def load_claims():
    try:
        return json.load(open(CLAIMS_FILE, encoding="utf-8"))
    except Exception:
        return {}


def save_claims(claims):
    tmp = CLAIMS_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(claims, f)
    os.replace(tmp, CLAIMS_FILE)


@contextlib.contextmanager
def claims_lock():
    """Fix 3: serialize load -> modify -> save across processes.
    Without this, two tg_send invocations (agent + hook checker)
    can read the same claims, modify different entries, and the
    second save overwrites the first. flock is per-process on Linux,
    so concurrent callers block here instead of racing."""
    os.makedirs(STATE_DIR, exist_ok=True)
    lock_path = os.path.join(STATE_DIR, "claims.lock")
    with open(lock_path, "a+") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def mark_done(update_id):
    # Clear typing work marker, regardless of where the
    # record lives. Checker wake creates state/typing_active.json, main
    # agent reply (tg_send --done / --ack-only) clears it. This is the
    # refresher stop signal, NOT inbox-empty + claims-clear.
    try:
        _marker = os.path.join(STATE_DIR, "typing_active.json")
        _m = json.load(open(_marker, encoding="utf-8"))
        if str(_m.get("update_id")) == str(update_id):
            os.remove(_marker)
    except Exception:
        pass
    path = os.path.join(INBOX_DIR, f"{update_id}.json")
    # Record may already be in inbox/done/ (checker once-delivery).
    # In that case, keep the done record as archive, but still delete
    # its downloaded file_local to avoid disk fill. Do NOT delete done/.
    _done_path = os.path.join(INBOX_DIR, "done", f"{update_id}.json")
    if os.path.isfile(_done_path) and not os.path.isfile(path):
        try:
            rec = json.load(open(_done_path, encoding="utf-8"))
            file_local = rec.get("file_local") if isinstance(rec, dict) else None
            if file_local:
                real_file = os.path.realpath(file_local)
                real_files = os.path.realpath(FILES_DIR)
                if real_file.startswith(real_files + os.sep):
                    try:
                        os.remove(real_file)
                    except OSError:
                        pass
        except Exception:
            pass
        return
    # Cleanup: deleting the inbox record alone left the
    # downloaded attachment in inbox/files/ forever. A large file
    # would fill the disk, so close the item by removing its file too.
    # Only delete paths that really live under inbox/files/; anything
    # else in the record is left alone as a safety guard.
    try:
        rec = json.load(open(path, encoding="utf-8"))
        file_local = rec.get("file_local") if isinstance(rec, dict) else None
        if file_local:
            # abspath does not resolve symlinks,
            # so a symlink inside inbox/files/ pointing outside would
            # pass the old check. realpath resolves it and blocks it.
            real_file = os.path.realpath(file_local)
            real_files = os.path.realpath(FILES_DIR)
            if real_file.startswith(real_files + os.sep):
                try:
                    os.remove(real_file)
                except OSError:
                    pass
    except Exception:
        pass
    try:
        os.remove(path)
    except OSError:
        pass
    with claims_lock():
        claims = load_claims()
        claims.pop(str(update_id), None)
        save_claims(claims)


def main():
    ap = argparse.ArgumentParser()
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--text")
    mode.add_argument("--document")
    mode.add_argument("--stdin", action="store_true")
    mode.add_argument("--ack-only", type=int)
    mode.add_argument("--claim-refresh", type=int)
    ap.add_argument("--caption", default="")
    ap.add_argument("--reply-to", type=int)
    ap.add_argument("--done", type=int)
    args = ap.parse_args()
    # Validate AFTER parse_args, so --help works without env.
    # Real sends are validated here, before any token/API use.
    if not OWNER_CHAT:
        raise SystemExit("TG_OWNER_ID env var is required (numeric Telegram user id)")
    if args.done is not None and (args.ack_only is not None
                                  or args.claim_refresh is not None):
        ap.error("--done cannot be combined with --ack-only/--claim-refresh")

    if args.ack_only is not None:
        mark_done(args.ack_only)
        print(f"acked {args.ack_only}")
        return
    if args.claim_refresh is not None:
        with claims_lock():
            claims = load_claims()
            # Do not resurrect a claim that mark_done already removed:
            # a late refresh must not recreate a finished item.
            if str(args.claim_refresh) not in claims:
                print(f"claim {args.claim_refresh} not found, not recreating")
                return
            claims[str(args.claim_refresh)]["claimed_at"] = int(time.time())
            save_claims(claims)
        print(f"claim refreshed {args.claim_refresh}")
        return

    if args.document:
        token = load_token()
        resp, overflow = send_document(token, args.document,
                                       caption=args.caption,
                                       reply_to=args.reply_to)
        print("sent document message_id:", resp["result"]["message_id"])
        if overflow:
            for i, chunk in enumerate(split_text(overflow)):
                params = {"chat_id": OWNER_CHAT, "text": chunk}
                if args.reply_to and i == 0:
                    params["reply_parameters"] = {"message_id": args.reply_to}
                r2 = api(token, "sendMessage", params, timeout=30)
                print("sent overflow message_id:", r2["result"]["message_id"])
        if args.done is not None:
            mark_done(args.done)
        return

    text = sys.stdin.read() if args.stdin else (args.text or "")
    if not text.strip():
        print("empty text; nothing sent", file=sys.stderr)
        sys.exit(2)
    token = load_token()
    # typing indicator while the reply goes out; best-effort only, so
    # even an ok:false here must not abort the real send below.
    try:
        api(token, "sendChatAction", {"chat_id": OWNER_CHAT, "action": "typing"}, timeout=10)
    except BaseException:
        pass
    sent_ids = []
    for i, chunk in enumerate(split_text(text)):
        params = {"chat_id": OWNER_CHAT, "text": chunk}
        if args.reply_to and i == 0:
            params["reply_parameters"] = {"message_id": args.reply_to}
        resp = api(token, "sendMessage", params, timeout=30)
        sent_ids.append(resp["result"]["message_id"])
    if args.done is not None:
        mark_done(args.done)
    print("sent message_ids:", sent_ids)


if __name__ == "__main__":
    main()
