#!/usr/bin/env python3
"""Pull a file recorded by the listener as vps_path into the bridge files dir.

This is the missing piece in the listener: the listener does NOT do SFTP itself.
It records vps_path + file_size in the inbox record, and this tool
pulls it on demand. That keeps SFTP credentials out of listener and
keeps the pull decision explicit.

Usage:
  tg_pull.py <inbox.json> [--force] [--dry-run]
  tg_pull.py <inbox.json> --dest /path/to/out.mp4

Rules:
- file_size <= TG_AUTO_PULL_MAX (default 50MB, env TG_AUTO_PULL_MAX_MB):
  pull by default.
- file_size > TG_AUTO_PULL_MAX: do NOT pull unless --force is given.
  This is the on-demand large-file path.
- After pull, verify actual size == recorded file_size (when recorded).
  On mismatch, keep the partial file as .partial and exit non-zero.
- SFTP transport: system `sftp` command, BatchMode, with env:
  TG_SFTP_HOST, TG_SFTP_PORT (default 22), TG_SFTP_USER, TG_SFTP_KEY.
  If TG_SFTP_HOST is not set, print the manual sftp command and exit 2
  instead of guessing a host. No host, key, or IP address is hardcoded here.
- Same-machine shortcut: if vps_path exists locally, copy it directly
  (same logic as the listener download_file) instead of SFTP.

This tool does not touch live bridge state except updating the given
inbox record's file_local field on success.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys


def _sftp_quote(p):
    # sftp batch mode splits on whitespace; quote both paths and
    # escape embedded backslashes and double quotes. This is the
    # backstop for old records whose names predate the safe_file_name
    # space/quote sanitizing.
    return '"' + p.replace("\\", "\\\\").replace('"', '\\"') + '"'

DEFAULT_MAX_MB = 50


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inbox", help="inbox JSON record written by listener")
    ap.add_argument("--force", action="store_true",
                    help="pull even if file_size > auto-pull threshold")
    ap.add_argument("--dry-run", action="store_true",
                    help="print what would be pulled, do not transfer")
    ap.add_argument("--dest", help="override destination path")
    ap.add_argument("--strict", action="store_true", help="exit 2 on large-file refusal (for scripts); default exit 0 for manual use")
    args = ap.parse_args()

    try:
        max_mb = int(os.environ.get("TG_AUTO_PULL_MAX_MB", str(DEFAULT_MAX_MB)))
    except ValueError:
        max_mb = DEFAULT_MAX_MB
    max_bytes = max_mb * 1024 * 1024

    with open(args.inbox, encoding="utf-8") as f:
        rec = json.load(f)

    vps_path = rec.get("vps_path")
    if not vps_path:
        print("no vps_path in record: nothing to pull (already local or cloud)",
              file=sys.stderr)
        return 0

    size = rec.get("file_size")
    # Prefer the record's own auto_pull_max (written by listener) over env,
    # so a record pulled later still uses the threshold it was recorded with.
    if rec.get("auto_pull_max"):
        max_bytes = int(rec["auto_pull_max"])
        max_mb = max_bytes // 1024 // 1024
    if size is not None and size > max_bytes and not args.force:
        print(f"large file {size} bytes > {max_bytes} bytes threshold "
              f"({max_mb}MB): not auto-pulled, run with --force for on-demand pull")
        return 2 if args.strict else 0

    # Always makedirs the files dir, do not fall back to inbox/ dir.
    # Derive from the record path, not the script dir: if the record
    # is in inbox/done/, its files dir is still inbox/files/, so
    # mark_done (which only deletes under inbox/files/) can clean it.
    # Using the script dir would put the file in the wrong bridge
    # in multi-bridge or test layouts.
    _inbox_dir = os.path.dirname(os.path.abspath(args.inbox))
    if os.path.basename(_inbox_dir) == "done":
        _inbox_dir = os.path.dirname(_inbox_dir)
    _files_dir = os.path.join(_inbox_dir, "files")
    os.makedirs(_files_dir, exist_ok=True)
    dest = args.dest or os.path.join(
        _files_dir, rec.get("file_name", os.path.basename(vps_path)))

    if args.dry_run:
        print(f"would pull: {vps_path} size={size} -> {dest} "
              f"threshold={max_bytes} force={args.force}")
        return 0

    # A previous size-mismatch run left dest.partial behind. Decide
    # before transferring, not after: a .partial SMALLER than the
    # recorded size is a true partial, move it back so reget resumes
    # it. A .partial at or above the recorded size means the remote
    # file changed after a complete transfer; drop the stale copy and
    # download fresh (it will be re-verified below).
    _partial = dest + ".partial"
    if size is not None and os.path.isfile(_partial):
        try:
            _psz = os.path.getsize(_partial)
        except OSError:
            _psz = -1
        try:
            if 0 <= _psz < size:
                os.replace(_partial, dest)
            elif _psz >= size:
                os.remove(_partial)
        except OSError:
            pass

    # Same-machine shortcut
    if os.path.isfile(vps_path):
        shutil.copyfile(vps_path, dest)
        print(f"copied local file: {vps_path} -> {dest}")
    else:
        host = os.environ.get("TG_SFTP_HOST")
        if not host:
            print("TG_SFTP_HOST not set: cannot SFTP pull. "
                  "Set TG_SFTP_HOST/TG_SFTP_PORT/TG_SFTP_USER/TG_SFTP_KEY, "
                  f"or manually: sftp <user>@<host>:{vps_path} {dest}",
                  file=sys.stderr)
            return 2
        port = os.environ.get("TG_SFTP_PORT", "22")
        user = os.environ.get("TG_SFTP_USER", "root")
        key = os.environ.get("TG_SFTP_KEY")
        cmd = ["sftp", "-b", "-", "-P", port, "-o", "BatchMode=yes"]
        if key:
            cmd += ["-i", key]
        cmd += [f"{user}@{host}"]
        # sftp batch: reget resumes a partial download
        batch = f"reget {_sftp_quote(vps_path)} {_sftp_quote(dest)}\n"
        r = subprocess.run(cmd, input=batch, text=True, capture_output=True)
        if r.returncode != 0:
            print(f"sftp failed: {r.stderr.strip()}", file=sys.stderr)
            return r.returncode or 1
        print(f"sftp pulled: {vps_path} -> {dest}")

    if size is not None:
        actual = os.path.getsize(dest)
        if actual != size:
            partial = dest + ".partial"
            try:
                os.replace(dest, partial)
            except OSError:
                pass
            print(f"size mismatch: expected {size}, got {actual}, "
                  f"kept as {partial}", file=sys.stderr)
            return 1

    # Same race as predownload: update only the copy
    # that still exists (inbox, then done), never recreate a missing one.
    _target = args.inbox
    if not os.path.isfile(_target):
        _done = os.path.join(os.path.dirname(_target), "done", os.path.basename(_target))
        if os.path.isfile(_done):
            _target = _done
        else:
            print("record gone at writeback (checker moved/deleted it), not recreating",
                  file=sys.stderr)
            return 0
    try:
        rec = json.load(open(_target, encoding="utf-8"))
    except Exception:
        pass
    rec["file_local"] = dest
    _tmp = _target + ".tmp"
    with open(_tmp, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False)
    os.replace(_tmp, _target)
    print(f"pulled and verified: {dest} size={size}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
