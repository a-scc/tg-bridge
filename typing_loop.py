#!/usr/bin/env python3
"""Connector-based typing refresher for the TG bridge (separate process).

Sends typing via the custom.telegram connector helper (tg.py) so the
bot token never touches disk.

Sends sendChatAction typing every INTERVAL seconds while work is
active, stops on its own when work is cleared, hard cap MAX_RUNTIME.
Singleton via flock on state/typing.lock: if another loop is already
running, exit immediately.

Pending = any of: inbox/*.json exists (pre-wake window: the poller
spawns this loop on intake, before the hook wakes), inbox/done/*.json
exists (woken, not yet archived to closed/), typing_active.json marker
exists and is fresh. Stale markers are removed. The hook worker deletes
the marker after archiving a reply to done/closed/, so the loop stops
promptly; without that it would run until the marker goes stale.

Interval/cap follow the repo defaults and are overridable via
environment: TG_TYPING_INTERVAL_SECS (default 4),
TG_TYPING_MAX_MINUTES (default 35).
"""
import fcntl
import json
import os
import subprocess
import sys
import time

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
INBOX_DIR = os.path.join(BASE_DIR, "inbox")
DONE_DIR = os.path.join(INBOX_DIR, "done")
STATE_DIR = os.path.join(BASE_DIR, "state")
MARKER_FILE = os.path.join(STATE_DIR, "typing_active.json")
LOG_FILE = os.path.join(STATE_DIR, "typing.log")
TG_HELPER = os.path.expanduser(
    "~/workspace/custom-connectors/custom.telegram/bin/tg.py")

try:
    INTERVAL = int(os.environ.get("TG_TYPING_INTERVAL_SECS", "4"))
    if INTERVAL <= 0:
        raise ValueError
except ValueError:
    INTERVAL = 4
try:
    MAX_RUNTIME = int(os.environ.get("TG_TYPING_MAX_MINUTES", "35")) * 60
    if MAX_RUNTIME <= 0:
        raise ValueError
except ValueError:
    MAX_RUNTIME = 35 * 60


def log(msg):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


def _any_json(d):
    try:
        return any(n.endswith(".json") for n in os.listdir(d))
    except OSError:
        return False


def pending():
    if _any_json(INBOX_DIR):
        return True
    if _any_json(DONE_DIR):
        return True
    try:
        marker = json.load(open(MARKER_FILE, encoding="utf-8"))
        if time.time() - marker.get("time", 0) < MAX_RUNTIME:
            return True
        try:
            os.remove(MARKER_FILE)
        except OSError:
            pass
        log("stale typing marker removed")
    except Exception:
        pass
    return False


def main():
    if len(sys.argv) < 2:
        print("usage: typing_loop.py <chat_id> [max_minutes]", file=sys.stderr)
        return 2
    chat_id = sys.argv[1]
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        lock_f = open(os.path.join(STATE_DIR, "typing.lock"), "a+")
        fcntl.flock(lock_f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except (OSError, BlockingIOError):
        return 0  # another loop already running
    max_run = MAX_RUNTIME
    if len(sys.argv) > 2:
        try:
            max_run = int(float(sys.argv[2]) * 60)
        except ValueError:
            pass
    log(f"typing loop started chat={chat_id}")
    start = time.time()
    try:
        while time.time() - start < max_run:
            if not pending():
                log("typing loop stopped: no pending work")
                return 0
            try:
                subprocess.run(
                    [sys.executable, TG_HELPER, "typing", str(chat_id)],
                    capture_output=True, timeout=20)
            except Exception as e:
                log(f"typing ping failed: {e}")
            time.sleep(INTERVAL)
        log("typing loop stopped: hard cap reached")
        return 0
    finally:
        # Auto-delete marker on exit, so typing indicator never gets stuck
        # even if the handler forgets HANDLING step 5.
        try:
            os.remove(MARKER_FILE)
        except OSError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
