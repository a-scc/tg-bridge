#!/usr/bin/env python3
"""Typing refresher for TG bridge (separate process, NOT tg_send).

Sends sendChatAction typing every 4 seconds while work is active,
stops on its own when work is cleared, hard cap 35 minutes.
Singleton via flock on state/typing.lock: if another refresher is
already running, exit immediately (do not stack refreshers).

Stop condition: an independent work marker
state/typing_active.json, created by hook on wake, cleared by
tg_send --done / --ack-only when main chat replies. Refresher is
pending if ANY of: inbox files exist, claims exist, OR marker exists
and is not stale (>35 min). Inbox/claims alone cover the pre-wake
window (listener spawns refresher at intake, before hook wake);
marker alone covers the post-wake long-thinking window.
If marker is stale, refresher exits and removes it.

Local API proxy bypass (same rule as listener): if TG_API_LOCAL=1
or base starts with http://, use ProxyHandler({}) + unverified
context, NOT plain urlopen through the egress proxy. When the API base is a local server,
plain urlopen would go through the egress proxy and fail silently.
Errors are logged to state/typing.log (start/stop/error, not every
typing ping), not swallowed to DEVNULL.
Token is read from the bridge .bot_token file (600), never logged.
"""
import argparse
import fcntl
import json
import os
import ssl
import time
import urllib.request

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
INBOX_DIR = os.path.join(BASE_DIR, "inbox")
STATE_DIR = os.path.join(BASE_DIR, "state")
TOKEN_FILE = os.path.join(BASE_DIR, ".bot_token")
MARKER_FILE = os.path.join(STATE_DIR, "typing_active.json")
LOG_FILE = os.path.join(STATE_DIR, "typing.log")
# Defaults are overridable via environment, not fixed to one deployment:
# TG_TYPING_INTERVAL_SECS (default 4), TG_TYPING_MAX_MINUTES (default 35).
try:
    INTERVAL = int(os.environ.get("TG_TYPING_INTERVAL_SECS", "4"))
except ValueError:
    INTERVAL = 4
try:
    MAX_RUNTIME = int(os.environ.get("TG_TYPING_MAX_MINUTES", "35")) * 60
except ValueError:
    MAX_RUNTIME = 35 * 60


def log(msg):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except Exception:
        pass


def api_base():
    return (os.environ.get("TG_API_BASE_URL") or "https://api.telegram.org").rstrip("/")


def is_local():
    return os.environ.get("TG_API_LOCAL") == "1" or api_base().startswith("http://")


def make_opener():
    if is_local():
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            urllib.request.HTTPSHandler(context=ssl._create_unverified_context()))
    proxy = (os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
             or os.environ.get("HTTP_PROXY") or os.environ.get("http_proxy"))
    if proxy:
        return urllib.request.build_opener(
            urllib.request.ProxyHandler({"https": proxy, "http": proxy}))
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def pending():
    try:
        if any(n.endswith(".json") for n in os.listdir(INBOX_DIR)):
            return True
    except OSError:
        pass
    try:
        claims = json.load(open(os.path.join(STATE_DIR, "claims.json"), encoding="utf-8"))
        if claims:
            return True
    except Exception:
        pass
    try:
        marker = json.load(open(MARKER_FILE, encoding="utf-8"))
        ts = marker.get("time", 0)
        if time.time() - ts < MAX_RUNTIME:
            return True
        # Stale marker: remove it so a later refresher does not revive it.
        try:
            os.remove(MARKER_FILE)
        except OSError:
            pass
        log("stale typing marker removed")
    except Exception:
        pass
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chat-id", required=True)
    args = ap.parse_args()
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        lock_f = open(os.path.join(STATE_DIR, "typing.lock"), "a+")
        fcntl.flock(lock_f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, BlockingIOError):
        return 0
    try:
        token = open(TOKEN_FILE, encoding="utf-8").read().strip()
    except OSError:
        log("no token file, exiting")
        return 0
    base = api_base()
    url = f"{base}/bot{token}/sendChatAction"
    opener = make_opener()
    log(f"typing refresher started chat={args.chat_id} local={is_local()} base={base}")
    start = time.time()
    while time.time() - start < MAX_RUNTIME:
        if not pending():
            log("typing refresher stopped: no pending work / marker cleared")
            return 0
        try:
            data = json.dumps({"chat_id": int(args.chat_id), "action": "typing"}).encode()
            req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
            opener.open(req, timeout=10).read()
        except Exception as e:
            log(f"sendChatAction failed: {e}")
        time.sleep(INTERVAL)
    log("typing refresher stopped: 35 min hard cap")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
