#!/usr/bin/env python3
"""tg_adapter.py — 把桥约定的 5 个动词翻译成本机 helper 的真实 CLI。

桥(poller.py / typing_loop.py / tg_claim.sh / tg_finish.sh)按这个约定调用:

    python3 <TG_HELPER> getupdates --offset N --timeout T   → {"ok":true,"result":[...]}
    python3 <TG_HELPER> react <chat_id> <message_id>
    python3 <TG_HELPER> typing <chat_id>
    python3 <TG_HELPER> download <file_id> <dest_path> --max-bytes N  → {"ok":true}
    python3 <TG_HELPER> send <chat_id> <text>                → {"ok":true,"result":{"message_id":..}}

真实 CLI(2026-10 实测, 见 README):

    get-updates    --offset OFFSET --timeout TIMEOUT
    set-reaction   --chat-id CHAT_ID --message-id MESSAGE_ID [--emoji EMOJI]
    chat-action    --chat-id CHAT_ID [--action ACTION]
    download-file  --file-id FILE_ID --out-dir OUT_DIR
    send-message   --chat-id CHAT_ID --text TEXT
    send-long      --chat-id CHAT_ID [--text TEXT] [--text-file TEXT_FILE] [--dry-run]

适配器负责三件事(这三件正是"改 5 处调用点"会散落在 5 个地方的东西):
  1. 动词改名 + 参数形状转换
  2. 返回 JSON 归一化成桥期望的 {"ok":..,"result":..}
  3. download 的两个真实差异: 真实 CLI 只能给目录(桥要精确路径) + 没有 --max-bytes

用法:
    TG_HELPER=<install_dir>/bin/tg_adapter.py
    TG_HELPER_REAL=/home/hatch/workspace/custom-connectors/custom.telegram/bin/tg.py

退出码与真实 CLI 一致(stderr 原样透传), 这样 poller 的 401/409/429 判断仍然有效。
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

# 用 or 而不是 get 的默认值: unit 里若写成 Environment=TG_HELPER_REAL=
# (变量没配时常见), get 会返回空串把默认值顶掉, 这里兜住。
REAL = os.path.expanduser(os.environ.get("TG_HELPER_REAL")
                          or "~/workspace/custom-connectors/custom.telegram/bin/tg.py")


def _die(msg, extra=None):
    """给桥看的一行 JSON, 同时以非零退出(让 poller 的 rc 分支仍然生效)。"""
    d = {"ok": False, "error": msg}
    if extra:
        d.update(extra)
    print(json.dumps(d, ensure_ascii=False))
    sys.exit(2)


def _run(args, timeout=None):
    """跑真实 CLI。stdout 捕获、stderr 直通(401/409 的文本要留给上层解析)。"""
    p = subprocess.run([sys.executable, REAL] + args,
                       capture_output=True, text=True, timeout=timeout)
    sys.stderr.write(p.stderr or "")      # 原样透传, 不要吞
    return p.returncode, (p.stdout or "")


def _norm(raw, want="result"):
    """把真实 CLI 的输出归一化成 {"ok":..,"result":..}。

    真实 CLI 的输出形状没有文档保证, 所以这里做"能认就认, 认不出就包一层":
      * 已经是 {"ok":..} 的形状 → 原样(必要时把顶层 message_id 挪进 result)
      * 是裸 list        → 当成 result(getupdates 要 list)
      * 是其它 dict      → 当成 result
      * 完全不是 JSON    → 放 raw 里, 仍然算成功(有的 CLI 只打人话)
    """
    text = raw.strip()
    if not text:
        return {"ok": True, "result": [] if want == "list" else {}}
    try:
        d = json.loads(text)
    except Exception:
        return {"ok": True, "raw": text[:500]}
    if isinstance(d, list):
        return {"ok": True, "result": d}
    if isinstance(d, dict):
        if "ok" in d:
            if want == "result" and "result" not in d and "message_id" in d:
                d["result"] = {"message_id": d["message_id"]}
            if want == "list" and not isinstance(d.get("result"), list):
                for k in ("updates", "items", "data"):
                    if isinstance(d.get(k), list):
                        d["result"] = d[k]
                        break
            return d
        if want == "list":
            for k in ("updates", "items", "data", "result"):
                if isinstance(d.get(k), list):
                    return {"ok": True, "result": d[k]}
        return {"ok": True, "result": d}
    return {"ok": True, "result": d}


def cmd_getupdates(argv):
    """getupdates --offset N --timeout T  →  get-updates --offset N --timeout T"""
    offset = timeout = None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--offset" and i + 1 < len(argv):
            offset = argv[i + 1]; i += 2
        elif a.startswith("--offset="):
            offset = a.split("=", 1)[1]; i += 1
        elif a == "--timeout" and i + 1 < len(argv):
            timeout = argv[i + 1]; i += 2
        elif a.startswith("--timeout="):
            timeout = a.split("=", 1)[1]; i += 1
        else:
            i += 1
    args = ["get-updates"]
    if offset is not None:
        args += ["--offset", str(offset)]
    if timeout is not None:
        args += ["--timeout", str(timeout)]
    # 长轮询: 给真实 CLI 留 10 秒余量, 免得它先被外层 timeout 杀掉留孤儿
    t = (int(timeout) + 10) if (timeout and str(timeout).isdigit()) else None
    rc, out = _run(args, timeout=t)
    if rc != 0:
        _die(f"real helper rc={rc}", {"stage": "get-updates"})
    print(json.dumps(_norm(out, want="list"), ensure_ascii=False))
    return rc


def cmd_send(argv):
    """send <chat_id> <text>  →  send-message / 超长退回 send-long"""
    if len(argv) < 2:
        _die("adapter: send 需要 <chat_id> <text>")
    chat, text = argv[0], argv[1]
    rc, out = _run(["send-message", "--chat-id", str(chat), "--text", text], timeout=60)
    if rc != 0:
        # 桥已经按 3900 字切过片, 走到这里多半是单条被拒(太长/含非法字符)。
        # 退回 send-long, 让它自己处理长文本。
        rc2, out2 = _run(["send-long", "--chat-id", str(chat), "--text", text], timeout=90)
        if rc2 == 0:
            print(json.dumps(_norm(out2), ensure_ascii=False))
            return 0
        _die(f"real helper rc={rc} (send-message) / rc={rc2} (send-long)",
             {"stage": "send"})
    print(json.dumps(_norm(out), ensure_ascii=False))
    return 0


def cmd_typing(argv):
    """typing <chat_id>  →  chat-action --chat-id C --action typing"""
    if not argv:
        _die("adapter: typing 需要 <chat_id>")
    rc, out = _run(["chat-action", "--chat-id", str(argv[0]),
                    "--action", "typing"], timeout=20)
    # typing 是尽力而为: 失败也不该影响主链路, 所以永远打 ok
    print(json.dumps({"ok": True, "upstream_rc": rc}, ensure_ascii=False))
    return 0


def cmd_react(argv):
    """react <chat_id> <message_id>  →  set-reaction --chat-id C --message-id M"""
    if len(argv) < 2:
        _die("adapter: react 需要 <chat_id> <message_id>")
    rc, out = _run(["set-reaction", "--chat-id", str(argv[0]),
                    "--message-id", str(argv[1])], timeout=30)
    print(json.dumps({"ok": rc == 0, "upstream_rc": rc}, ensure_ascii=False))
    return 0


def cmd_download(argv):
    """download <file_id> <dest_path> --max-bytes N  →  download-file --file-id F --out-dir D

    真实 CLI 只接受"目录", 且没有 --max-bytes; 桥要的是精确文件路径 + 大小上限。
    这两件事都在适配器里补:
      * 先下到临时目录, 再把下出来的那一个文件搬到桥要的路径
      * 超过上限就删掉并报 over_cap(与 tg_claim.sh 的预期一致)
    """
    file_id = dest = None
    max_bytes = 20971520
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--max-bytes" and i + 1 < len(argv):
            try:
                max_bytes = int(argv[i + 1])
            except ValueError:
                pass
            i += 2
        elif a.startswith("--max-bytes="):
            try:
                max_bytes = int(a.split("=", 1)[1])
            except ValueError:
                pass
            i += 1
        elif file_id is None:
            file_id = a; i += 1
        elif dest is None:
            dest = a; i += 1
        else:
            i += 1
    if not file_id or not dest:
        _die("adapter: download 需要 <file_id> <dest_path>")

    tmp = tempfile.mkdtemp(prefix="tgdl-")
    try:
        rc, out = _run(["download-file", "--file-id", str(file_id), "--out-dir", tmp],
                       timeout=180)
        if rc != 0:
            _die(f"real helper rc={rc}", {"stage": "download-file"})
        files = [os.path.join(tmp, n) for n in os.listdir(tmp)]
        files = [f for f in files if os.path.isfile(f)]
        if not files:
            _die("real helper 没下出文件", {"stage": "download-file", "out_dir": tmp})
        src = max(files, key=os.path.getsize)     # 正常只有一个
        size = os.path.getsize(src)
        if max_bytes and size > max_bytes:
            print(json.dumps({"ok": False, "error": "over_cap", "size": size,
                              "max_bytes": max_bytes}, ensure_ascii=False))
            return 0
        os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
        shutil.move(src, dest)
        print(json.dumps({"ok": True, "size": size, "path": dest}, ensure_ascii=False))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


CMDS = {
    "getupdates": cmd_getupdates,
    "send": cmd_send,
    "typing": cmd_typing,
    "react": cmd_react,
    "download": cmd_download,
}


def main():
    argv = sys.argv[1:]
    if not argv:
        print("tg_adapter: 桥约定的动词是 %s" % " ".join(sorted(CMDS)), file=sys.stderr)
        return 64
    verb, rest = argv[0], argv[1:]

    # install.sh 的离线探针会塞这个假参数: 直接判"参数不认识"而不是"动词不认识",
    # 这样探针能区分"CLI 对不上"和"只是参数不同", 又不会真去联网。
    if "--__tg_probe__" in rest:
        print("usage: tg_adapter.py {%s} ..." % ",".join(sorted(CMDS)),
              file=sys.stderr)
        print("tg_adapter.py: error: unrecognized arguments: --__tg_probe__",
              file=sys.stderr)
        return 2

    fn = CMDS.get(verb)
    if fn is None:
        print("usage: tg_adapter.py {%s} ..." % ",".join(sorted(CMDS)), file=sys.stderr)
        print("tg_adapter.py: error: argument command: invalid choice: %r" % verb,
              file=sys.stderr)
        return 2
    if not os.path.isfile(REAL):
        _die(f"找不到真实 helper: {REAL} (设 TG_HELPER_REAL=...)")
    return fn(rest)


if __name__ == "__main__":
    sys.exit(main())
