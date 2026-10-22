> [中文](README.zh-CN.md) | English

# Telegram bridge (inbox-first, once-delivery)

Pure standard-library Python. No external dependencies.

What it does, in one paragraph: a Telegram bot (Bot API) polls for
messages from one owner, writes each message to `inbox/<update_id>.json`
(and downloads its attachment, when there is one), and a checker script
decides when the main agent should be woken. The main agent replies
in its own chat; replies to Telegram go through `tg_send.py`.
Delivery is once, not leased-and-retried: the checker moves a record
from `inbox/` to `inbox/done/` on wake, so the next poll picks the
next record instead of being blocked by the head of the queue.

## Files

- `listener.py` — polls `getUpdates`, reacts, downloads attachments,
  writes inbox records and `state/tg_history.jsonl` (user lines only),
  writes `state/heartbeat`.
- `tg_send.py` — sends text / documents to Telegram, splits long text,
  and closes an inbox item with `--done <update_id>` or
  `--ack-only <update_id>` (close without sending). Closing clears
  the typing work marker; a record already in `inbox/done/` is kept
  as an archive, only its downloaded file is removed.
- `tg_pull.py` — pulls a file recorded as `vps_path` in an inbox
  record, verifies size, and updates the record's `file_local`.
  It updates only the copy that still exists (`inbox/` first, then
  `inbox/done/`); it never recreates a missing record.
- `typing_refresher.py` — separate process, NOT inside `tg_send.py`.
  Sends `sendChatAction` typing while work is active. It is pending
  while inbox files exist, or the work marker
  `state/typing_active.json` exists and is not stale. The checker
  creates the marker on wake; `tg_send.py --done` / `--ack-only`
  clears it. Singleton via `state/typing.lock`.
- `predownload.py` — detached, best-effort predownload for
  photo / document records at or below the auto-pull threshold.
  Failure leaves the VPS marker unchanged. It also updates only
  the copy that still exists (`inbox/` first, then `inbox/done/`).
- `tg_bridge_check.sh` — standalone checker. It prints two lines:
  line 1 `WAKE tg-message` / `WAKE deadletter` / `SILENT <reason>`,
  line 2 JSON payload. Your poller (cron, systemd timer, or a hook
  system) reads those lines. Poll interval is set by your poller,
  not by this script. Even if the checker itself crashes, it still
  prints `SILENT checker-error` + `{}` and exits 0, so a poller
  reading two lines never reads an empty stdout (the traceback,
  if any, goes to stderr for debugging). Non-numeric .json files in
  inbox/ never take part in delivery: they are moved to state/failed/
  once and logged once to state/hook-errors.log.

## Configuration (all via environment, no values are fixed in code)

| Variable | Meaning | Default |
|---|---|---|
| `TG_OWNER_ID` | Numeric Telegram user id of the owner (required) | — |
| `TG_API_BASE_URL` | Bot API base, cloud or local Bot API server | `https://api.telegram.org` |
| `TG_API_LOCAL` | `1` = local Bot API, bypass the egress proxy | unset |
| `TG_AUTO_PULL_MAX_MB` | Auto-pull threshold, in MB | `50` |
| `TG_BRIDGE_DIR` | Directory containing these files, for the checker | directory of the checker script |
| `TG_BRIDGE_DRY_RUN` | `1` = checker dry run, do not move records | unset |
| `TG_TYPING_INTERVAL_SECS` | Typing refresh interval, in seconds | `4` |
| `TG_TYPING_MAX_MINUTES` | Typing hard cap, in minutes | `35` |
| `TG_SFTP_HOST`, `TG_SFTP_PORT`, `TG_SFTP_USER`, `TG_SFTP_KEY` | SFTP pull for `tg_pull.py` | unset |

Defaults above are fallbacks, not fixed caps: set the environment
variables to change them. The auto-pull threshold in a record
(`auto_pull_max`, written by the listener) wins over the environment
for that record, so a record pulled later still uses the threshold
it was recorded with.

## Setup

1. Create a bot with BotFather, get its token.
2. Put all files in one directory, e.g. `~/tg-bridge`.
3. Write the token to `.bot_token` in that directory, mode `600`.
   Never commit this file, never paste the token into code, issues,
   or chat logs. The listener warns (to stderr, and still reads
   the file) if the token file is group/world readable; it does
   not refuse it, so an existing deployment is not broken by
   a loose permission.
4. Set `TG_OWNER_ID` to your own Telegram user id. Only that user,
   in a private chat, is accepted; anyone else is silently dropped.
5. Run the listener, e.g. as a systemd service:
   `ExecStart=/usr/bin/python3 /path/to/tg-bridge/listener.py`
   with `TG_OWNER_ID`, `TG_API_BASE_URL`, and `TG_API_LOCAL`
   in its environment.
6. Poll `tg_bridge_check.sh` from your poller. Example: every
   few seconds, read its two output lines; on `WAKE`, deliver the
   payload to your main agent; on `SILENT`, do nothing.
7. Reply from your main agent with `tg_send.py`, and close the item
   with `--done <update_id>` (after sending) or `--ack-only
   <update_id>` (close without sending, e.g. when you replied only
   in your main chat).

## Large files (simplified rule)

- At or below the auto-pull threshold: the file is pulled to the
  main-agent host (via `tg_pull.py` / `predownload.py`), verified
  by size, and then handled there.
- Above the threshold: the file is NOT pulled through the
  main-agent host. It stays on the Bot API host, is recorded as
  `vps_path` + `file_size`, and is sent back to Telegram directly
  from that host. The main-agent host only receives a short
  notification (what it is, how large, which path on the Bot API
  host). Predownload is background preparation, not instant
  acceleration: a file near the threshold can take minutes over
  a slow link, and at wake time `file_local` is often still empty;
  in that case pull on demand with `tg_pull.py`.

## What is NOT in this package

- No credentials, no owner ids, no bot usernames, no IP addresses,
  no private paths. Everything host-specific is an environment
  variable (see the table above).
- No host-specific pull / tunnel helpers. If your deployment needs
  one, add it outside this package and point `tg_pull.py`'s SFTP
  variables at it; do not hardcode it here.
- No pairing / owner-onboarding flow. The owner is fixed by
  `TG_OWNER_ID`; strangers are silently dropped, which is safer
  than an interactive pairing step for a single-owner bridge.
- No self-healing hook. Use your own supervisor / watchdog for
  that; this package only checks, delivers once, and logs.

## Logs and state (not for commit)

- `state/tg_history.jsonl` — user message archive, rotated at
  2000 lines to the last 1000. Only the listener writes it for now;
  do not add a second writer without a lock.
- `state/typing.log`, `state/predownload.log`,
  `state/typing_spawn.log`, `state/predownload_spawn.log`,
  `state/stale.log`, `state/hook-errors.log` — start/stop and
  failure logs, not every ping.
- `state/deadletter.jsonl` — records that failed handling three
  times. The checker consumes it per line: good lines wake, bad
  lines go to `deadletter-bad-<timestamp>.jsonl`, the original is
  archived either way. If every line is bad, the checker is
  `SILENT` (no wake, but the bad lines are archived).

## License

Use, modify, and redistribute freely. Keep the `.bot_token`
out of every copy you share.
