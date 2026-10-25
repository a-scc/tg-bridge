#!/usr/bin/env bash
# tg_claim.sh — TG 桥：一次调用完成 HANDLING.md 步骤 0 / 0.5 / 1 / 2
#
#   幂等检查(closed/) → 认领到 inbox/processing/ → 扫全量 → 附件下载 → 一次输出 JSON
#
# 设计原则:
#   * 只有本脚本移动文件; os.replace 同盘原子, 不会出现半写状态
#   * 幂等以 inbox/done/closed/<uid>.json 为准 (与 HANDLING.md 步骤 0 一致)
#   * **每批归属显式化**: 本脚本把这次认领的 uid 写进 state/claim/<claim_id>.json,
#     并把 claim_id 输出给你; tg_finish.sh 只归档这个 claim_id 名下的 uid。
#     → 两个 handler 同时跑也不会互相吞掉对方的消息
#   * **绝不把新消息塞进别人正在处理的批**: 那会让别人的 finish 顺手归档掉从未被回复的消息
#   * processing/ 里的批全部超过 TG_PROC_STALE_SECS(默认 1800s) = handler 已死 → 接管
#     想立刻接管(运维手动) 用 --takeover
#   * 任何情况都 exit 0, 第一行是 JSON, 便于 agent 一次读取判分支
#
# 用法:
#   ./tg_claim.sh --uid 12345          # 单条唤醒: 带上 payload 里的 update_id (幂等键)
#   ./tg_claim.sh                      # 批唤醒 (WAKE tg-batch): 不传 uid
#   ./tg_claim.sh --uid 12345 --no-download
#   ./tg_claim.sh --takeover           # 强制接管 processing/ 里滞留的批(运维用)
#
# 输出 status:
#   claimed            已认领, 去生成回复; 记住输出里的 claim_id 传给 tg_finish.sh
#   already_processed  closed/ 已有 → 主聊天保持安静 (nothing_to_do)
#   nothing_to_do      无待处理
#   bad_args           参数错
set -uo pipefail

BASE="${TG_BRIDGE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
export TG_BRIDGE_DIR="$BASE"

TRIGGER_UID=""
DOWNLOAD=1
TAKEOVER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --uid)          TRIGGER_UID="${2:-}"; shift 2 ;;
    --uid=*)        TRIGGER_UID="${1#*=}"; shift ;;
    --no-download)  DOWNLOAD=0; shift ;;
    --takeover)     TAKEOVER=1; shift ;;
    -h|--help)      sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "{\"status\":\"bad_args\",\"error\":\"unknown arg: $1\"}"; exit 0 ;;
  esac
done

python3 - "$BASE" "$TRIGGER_UID" "$DOWNLOAD" "$TAKEOVER" <<'PYEOF'
import json, os, re, shlex, shutil, subprocess, sys, time

BASE     = sys.argv[1]
TRIGGER  = (sys.argv[2] or "").strip()
DOWNLOAD = sys.argv[3] == "1"
TAKEOVER = sys.argv[4] == "1"

INBOX  = os.path.join(BASE, "inbox")
DONE   = os.path.join(INBOX, "done")
CLOSED = os.path.join(DONE, "closed")
PROC   = os.path.join(INBOX, "processing")
FILES  = os.path.join(INBOX, "files")
STATE  = os.path.join(BASE, "state")
CLAIMD = os.path.join(STATE, "claim")        # 每次认领一份归属记录

TG_HELPER = os.path.expanduser(os.environ.get(
    "TG_HELPER", "~/workspace/custom-connectors/custom.telegram/bin/tg.py"))
def _envint(name, default):
    try:
        return int(os.environ.get(name, str(default)) or default)
    except ValueError:
        return default


# 模式与分档阈值。默认云端, 云端的行为与之前完全一致(单档 20MB)。
MODE = (os.environ.get("TG_BRIDGE_MODE") or "cloud").strip().lower()
if MODE not in ("cloud", "local"):
    MODE = "cloud"
MAX_BYTES_CLOUD = _envint("TG_MAX_BYTES_CLOUD", 20971520)          # 20MB, 云端单档
MAX_BYTES_LOCAL = _envint("TG_MAX_BYTES_LOCAL", 2000 * 1024 * 1024)  # 2GB, Telegram 上限
PULL_MAX_BYTES = _envint("TG_PULL_MAX_BYTES", 50 * 1024 * 1024)     # 50MB, 拉回桥本机的政策线
LIMIT_BYTES = MAX_BYTES_LOCAL if MODE == "local" else MAX_BYTES_CLOUD

# 本地模式下 helper 把文件落到"跑 Bot API 那台机器"的哪个目录。
# 不配就沿用 inbox/files 的同一路径串 —— 桥与 Bot API 服务器同机时, 那就是本地路径, 不需要拉回。
STAGE_DIR = (os.environ.get("TG_VPS_STAGING_DIR") or "").strip() or FILES
# 跨机时把文件从 VPS 拉回桥本机用的 SSH/SCP。不配就只能报 vps_path。
VPS_SSH = (os.environ.get("TG_VPS_SSH") or "").strip()
VPS_SSH_PORT = _envint("TG_VPS_SSH_PORT", 22)
VPS_SSH_KEY = (os.environ.get("TG_VPS_SSH_KEY") or "").strip()
VPS_SSH_TIMEOUT = _envint("TG_VPS_SSH_TIMEOUT", 600)
# scp 的 host key: BatchMode 下没有 known_hosts 条目会直接失败(不弹窗)。
# 默认 accept-new(首次接受并存下), 路径可配且必须持久 —— 有的环境重启后 ~/.ssh 会被清掉。
VPS_KNOWN_HOSTS = (os.environ.get("TG_VPS_KNOWN_HOSTS")
                   or os.path.expanduser("~/.ssh/known_hosts"))
VPS_STRICT = (os.environ.get("TG_VPS_STRICT_HOST_KEY") or "accept-new").strip()
# 服务器侧取文件: 让 getFile 落在跑 Bot API 那台机器上, 不把文件先拉进沙箱。
# 模板里可用 {file_id} {name} {dst} {stage_dir}, 值会被 shell 引用(防注入)。
# 命令需输出带 path/file_path/vps_path 的 JSON, 或一行纯路径。
VPS_FETCH_CMD = (os.environ.get("TG_VPS_FETCH_CMD") or "").strip()
VPS_FETCH_TIMEOUT = _envint("TG_VPS_FETCH_TIMEOUT", 3600)
# 1800s: handler 正常 20-40s 就回完, 大附件下载最长 180s。等 30 分钟才判死,
# 是为了宁可晚救孤儿批, 也不要抢走正在处理的批(抢走 = 重复回复)。
try:
    PROC_STALE = int(os.environ.get("TG_PROC_STALE_SECS", "1800") or 1800)
except ValueError:
    PROC_STALE = 1800

VALID = re.compile(r"^(\d+)\.json$")
T0 = time.time()


def log(msg):
    try:
        os.makedirs(STATE, exist_ok=True)
        with open(os.path.join(STATE, "claim.log"), "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")
    except OSError:
        pass


def out(status, **kw):
    """唯一的出口: 打一行 JSON, 永远 exit 0。"""
    kw["status"] = status
    kw["elapsed_ms"] = int((time.time() - T0) * 1000)
    log("claim %s %s" % (status, " ".join(
        f"{k}={kw[k]}" for k in ("claim_id", "batch_key", "count", "takeover")
        if k in kw)))
    print(json.dumps(kw, ensure_ascii=False))
    raise SystemExit(0)


def read_json(p):
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except Exception:
        return None


def listing(d):
    """只认 ^\\d+\\.json$, 按 update_id 升序。目录/dotfile/.tmp 一律忽略。"""
    res = []
    try:
        names = os.listdir(d)
    except OSError:
        return res
    for n in names:
        m = VALID.match(n)
        if m:
            res.append((int(m.group(1)), os.path.join(d, n)))
    res.sort()
    return res


def safe_name(raw, uid):
    base = os.path.basename(raw or "") or f"{uid}.bin"
    base = "".join("_" if c in "/\\ \"" or ord(c) < 32 or ord(c) == 127 else c
                   for c in base).strip()
    if not base or base in (".", ".."):
        base = f"{uid}.bin"
    return base if base.startswith(str(uid)) else f"{uid}_{base}"


for d in (PROC, CLOSED, FILES, STATE, CLAIMD):
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        pass

# ---------- 步骤 0: 幂等检查 ----------
# 被忙时压制后迟到的唤醒、重叠唤醒都会走到这里: closed/ 里有 = 已回过, 不许再回。
if TRIGGER:
    if not TRIGGER.isdigit():
        out("bad_args", error=f"--uid 必须是数字, 收到 {TRIGGER!r}")
    if os.path.isfile(os.path.join(CLOSED, f"{TRIGGER}.json")):
        out("already_processed", update_id=int(TRIGGER),
            note="closed/ 已有该 update_id: 这条(或包含它的批)已回复过, 主聊天保持安静")

# ---------- 步骤 0.5: 孤儿批接管 ----------
# 唯一会碰 processing/ 既有文件的地方。判据: 批里**最新**的文件都比阈值老 ⇒ 全部很老 ⇒ 死了。
# 注意这里不再有 "overlapped 把新消息塞进去" 的分支: 塞进去只会被别人的 finish 归档,
# 而那条消息永远没人回。新消息留在 inbox/ 里, 下一个 handler 正常认领就行。
proc = listing(PROC)
takeover = []
if proc:
    # 谁在跑? 看归属记录 state/claim/<id>.json 的 time。有 fresh 记录 = 活的, 绝不碰。
    # 没有记录(旧版本遗留 / claim 写到一半就死了)才退回看文件 mtime。
    owners = {}
    try:
        cnames = os.listdir(CLAIMD)
    except OSError:
        cnames = []
    for n in cnames:
        if not n.endswith(".json"):
            continue
        d = read_json(os.path.join(CLAIMD, n)) or {}
        ts = d.get("time") or 0
        for u in (d.get("uids") or []):
            try:
                u = int(u)
            except (TypeError, ValueError):
                continue
            owners.setdefault(u, []).append(ts)
    # 顺手清理"文件已经不在 processing/ 了"的归属记录(正常收尾会自己删, 这里兜底),
    # 否则 state/claim/ 越堆越多, 会让"唯一未收尾批"的兼容路径永远失效
    proc_uids_now = set(u for u, _ in proc)
    try:
        for n in cnames:
            if not n.endswith(".json"):
                continue
            d0 = read_json(os.path.join(CLAIMD, n)) or {}
            try:
                u0 = set(int(x) for x in (d0.get("uids") or []))
            except (TypeError, ValueError):
                u0 = set()
            if not (u0 & proc_uids_now):
                try:
                    os.remove(os.path.join(CLAIMD, n))
                except OSError:
                    pass
    except OSError:
        pass

    now = time.time()
    kept = 0
    for uid, pth in proc:
        if owners.get(uid):
            # 有归属记录: 只看记录年龄。fresh = 明确活着, 连 --takeover 都不抢。
            adopt = (now - max(owners[uid])) > PROC_STALE
        else:
            # 没有归属记录(旧版本遗留 / claim 写完文件就死了): --takeover 可立刻抢,
            # 否则要等文件本身够老, 避免抢到"刚搬进来、还没来得及写记录"的那几毫秒。
            try:
                age = now - os.path.getmtime(pth)
            except OSError:
                age = 0
            adopt = TAKEOVER or age > PROC_STALE
        if adopt:
            takeover.append((uid, pth))
        else:
            kept += 1
    log(f"processing/ 在跑={kept} 孤儿={len(takeover)} threshold={PROC_STALE}s force={int(TAKEOVER)}")

# ---------- 步骤 1: 认领 ----------
cands = listing(INBOX) + listing(DONE)
if not cands and not takeover:
    out("nothing_to_do", items=0, note="inbox/ 与 done/ 都没有待处理记录")

claimed, vanished = list(takeover), 0
for uid, p in cands:
    dst = os.path.join(PROC, os.path.basename(p))
    try:
        os.replace(p, dst)                       # 认领
        claimed.append((uid, dst))
        continue
    except OSError:
        pass
    # checker 可能在 listdir 与 replace 之间把它从 inbox/ 搬到了 done/ (或反向)
    alt = os.path.join(DONE if os.path.dirname(p) == INBOX else INBOX,
                       os.path.basename(p))
    try:
        os.replace(alt, dst)
        claimed.append((uid, dst))
    except OSError:
        vanished += 1                            # 真没了: 不阻塞, 记一笔

if not claimed:
    out("nothing_to_do", items=0, vanished=vanished,
        note="候选文件已被另一条路径取走")

claimed.sort()

# ---------- 步骤 2: 附件分类 + 下载 ----------
recs, to_dl, over_cap = [], [], []
for uid, path in claimed:
    try:
        r = json.load(open(path, encoding="utf-8"))
        if not isinstance(r, dict):
            raise ValueError
    except Exception:
        r = {"update_id": uid, "kind": "unreadable", "text": ""}
    r.setdefault("update_id", uid)
    fs = r.get("file_size") or 0
    if r.get("file_id"):
        item = {"update_id": uid, "file_id": r["file_id"],
                "file_name": r.get("file_name") or f"{uid}.bin", "file_size": fs}
        if fs and fs > LIMIT_BYTES:
            item["limit_bytes"] = LIMIT_BYTES
            item["mode"] = MODE
            over_cap.append(item)
        else:
            to_dl.append(item)
    r["_claimed_path"] = path
    recs.append(r)

rec_by_uid = {r["update_id"]: r for r in recs}


_REDACT_PATTERNS = (
    # URL 里的 bot<token>: https://api.telegram.org/file/bot123:ABC.../documents/x.pdf
    (re.compile(r"/bot[^/\s]+"), "/bot<REDACTED>"),
    # 裸 token 形态: <数字>:<35 位左右>
    (re.compile(r"\b\d{6,}:[A-Za-z0-9_-]{25,}"), "<TOKEN>"),
)


def _redact(text, limit=400):
    """把可能夹带令牌的片段换掉。返回 (脱敏后的文本, 是否改动过)。

    为什么要: 本地模式 getFile 的路径可能是带 bot<token> 的 URL; vps_path 会被写进
    processing/*.json、closed/*.json 和 claim 的输出 —— 原样存就等于令牌落盘。
    真实路径只在内存里用于 scp, 落盘/上报一律走这里。
    """
    if not text:
        return text, False
    out, changed = str(text), False
    for rx, repl in _REDACT_PATTERNS:
        out2 = rx.sub(repl, out)
        if out2 != out:
            changed = True
            out = out2
    return out[:limit], changed


def _reported_path(resp):
    """从 helper 的 JSON 里取它真正落盘的路径(本地模式下 getFile 的返回)。
    取不到就返回 None, 由调用方退回自己拼的路径。"""
    if not isinstance(resp, dict):
        return None
    for k in ("path", "file_path", "vps_path", "local_path", "saved_to"):
        v = resp.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    r = resp.get("result")
    if isinstance(r, dict):
        for k in ("path", "file_path", "vps_path", "saved_to"):
            v = r.get(k)
            if isinstance(v, str) and v.strip():
                return v.strip()
    return None


def _vps_fetch(tpl, file_id, name, dst):
    """在服务器侧取文件(不落沙箱)。返回 (vps_path, size, error)。"""
    cmd = tpl
    for k, v in (("{file_id}", file_id), ("{name}", name),
                 ("{dst}", dst), ("{stage_dir}", STAGE_DIR)):
        cmd = cmd.replace(k, shlex.quote(str(v)))
    try:
        p = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True,
                           text=True, timeout=VPS_FETCH_TIMEOUT)
    except Exception as e:
        return None, 0, f"fetch-cmd {type(e).__name__}: {e}"
    out = (p.stdout or "").strip()
    if p.returncode != 0:
        return None, 0, (f"fetch-cmd rc={p.returncode}: "
                         + ((p.stderr or "").strip() or out)[-300:])
    path, size = None, 0
    try:
        d = json.loads(out)
        if isinstance(d, dict):
            path = _reported_path(d)
            size = int(d.get("size") or d.get("file_size") or 0)
    except Exception:
        path = out.splitlines()[-1].strip() if out else None
    if not path:
        return None, 0, f"fetch-cmd 没给出路径: {out[-200:]}"
    if not size:
        try:
            size = os.path.getsize(path)
        except OSError:
            size = 0
    return path, size, None


def _pull_back(vps_path, name, size):
    """把 VPS 上的文件弄到桥本机 inbox/files。返回 (local_path, how, error)。

    how 取值:
      in-place  helper 直接写在了 inbox/files（同机, 无需搬运）
      move      同机/同挂载, 搬进 inbox/files
      scp       跨机, 用 scp 拉回
      remote    VPS 路径在桥本机上不可读, 且没配 TG_VPS_SSH → 只报路径
      scp-failed / scp-error  scp 失败
    """
    target = os.path.join(FILES, name)
    # 1) 先看是不是就在桥本机(同机/同挂载)。在, 就直接用 —— 跟大小无关,
    #    因为没有任何网络搬运发生。政策线只管"要不要跨机拉"。
    if os.path.isfile(vps_path):
        if os.path.abspath(vps_path) == os.path.abspath(target):
            return target, "in-place", None
        try:
            os.makedirs(FILES, exist_ok=True)
            shutil.move(vps_path, target)
            return target, "move", None
        except OSError as e:
            return None, "move-failed", f"{type(e).__name__}: {e}"
    # 2) 跨机: 超过政策线连试都不试
    if size and size > PULL_MAX_BYTES:
        return None, "skipped-too-large", None
    # 3) 跨机且配了 SSH 才 scp
    if not VPS_SSH:
        return None, "remote", "VPS 路径在桥本机不可读, 且未配置 TG_VPS_SSH"
    try:
        kh = os.path.expanduser(VPS_KNOWN_HOSTS)
        os.makedirs(os.path.dirname(kh) or ".", exist_ok=True)
        open(kh, "a").close()
    except OSError:
        kh = ""
    cmd = ["scp", "-P", str(VPS_SSH_PORT),
           "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
           "-o", f"StrictHostKeyChecking={VPS_STRICT}"]
    if kh:
        cmd += ["-o", f"UserKnownHostsFile={kh}"]
    if VPS_SSH_KEY:
        cmd += ["-i", VPS_SSH_KEY]
    cmd += [f"{VPS_SSH}:{vps_path}", target]
    try:
        os.makedirs(FILES, exist_ok=True)
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=VPS_SSH_TIMEOUT)
        if p.returncode == 0 and os.path.isfile(target):
            return target, "scp", None
        return None, "scp-failed", ((p.stderr or "").strip() or f"rc={p.returncode}")[-300:]
    except Exception as e:
        return None, "scp-error", f"{type(e).__name__}: {e}"

downloaded, dl_errors, remote_only = [], [], []
if DOWNLOAD:
    for a in to_dl:
        name = safe_name(a["file_name"], a["update_id"])
        # 云端: 直接下到 inbox/files(与之前完全一致, 不做任何额外判断)
        # 本地: 先落到 STAGE_DIR(跑 Bot API 那台机器的盘), 再按大小/可读性决定拉不拉回
        dst = os.path.join(FILES, name) if MODE == "cloud" else os.path.join(STAGE_DIR, name)
        err = None
        resp, vps_path, p = {}, None, None
        try:
            if MODE == "local" and VPS_FETCH_CMD:
                # 服务器侧取文件: getFile 落在跑 Bot API 那台机器上, 不经沙箱中转,
                # vps_path 用命令回报的真路径(不是我们拼的 STAGE_DIR/name)。
                vps_path, fsize, ferr = _vps_fetch(VPS_FETCH_CMD, a["file_id"], name, dst)
                if ferr:
                    ok = False
                    err = ferr
                else:
                    ok = True
                    if fsize:
                        a["vps_size"] = fsize
            else:
                p = subprocess.run(
                    [sys.executable, TG_HELPER, "download", a["file_id"], dst,
                     "--max-bytes", str(LIMIT_BYTES)],
                    capture_output=True, text=True, timeout=180)
                try:
                    resp = json.loads((p.stdout or "").strip())
                    ok = bool(resp.get("ok"))
                except Exception:
                    resp, ok = {}, False
            if ok and (os.path.isfile(dst) or MODE == "local"):
                r = rec_by_uid.get(a["update_id"])
                if MODE == "cloud":
                    if os.path.isfile(dst):
                        a["local_path"] = dst
                        a["local_name"] = name
                        downloaded.append(a)
                        # 把落盘名写回记录: finish 按这个名字搬, 不用猜 safe_name 怎么改的字符
                        if r is not None:
                            r["_local_name"] = name
                        continue
                    err = "helper 说成功但文件不在"
                else:
                    if not vps_path:
                        # 没走服务器侧取文件时, helper 已经把文件落进 dst(经沙箱);
                        # 但它若回报了真实路径(getFile 的), 以回报为准。
                        vps_path = _reported_path(resp) or dst
                    size = a.get("file_size") or 0
                    if not size:
                        try:
                            size = os.path.getsize(vps_path)
                        except OSError:
                            size = 0
                    # 脱敏只影响"落盘/上报"; _pull_back 仍然用真实路径(scp 要用)
                    shown_path, was_redacted = _redact(vps_path)
                    if r is not None:
                        r["vps_path"] = shown_path
                        r["vps_size"] = size
                        if was_redacted:
                            r["vps_path_redacted"] = True
                        if STAGE_DIR != FILES:
                            r["vps_stage_dir"] = _redact(STAGE_DIR)[0]
                    local, how, perr = _pull_back(vps_path, name, size)
                    a["pull"] = how
                    a["vps_path"] = shown_path
                    if local:
                        a["local_path"] = local
                        a["local_name"] = name
                        if r is not None:
                            r["_local_name"] = name
                        downloaded.append(a)
                    else:
                        # _pull_back 的错误里会带路径(move-failed 的 OSError、scp 的 stderr),
                        # 同样要脱敏后才上报
                        shown_perr, _ = _redact(perr)
                        a["error"] = shown_perr
                        if r is not None:
                            r["remote_only"] = True
                        remote_only.append(a)
                    continue
            if p is not None:      # FETCH_CMD 那条路没有 p, 别覆盖已经拿到的 ferr
                err = ((p.stdout or "").strip() or (p.stderr or "").strip())[-300:]
        except Exception as e:
            err = f"{type(e).__name__}: {e}"
        shown_err, _ = _redact(err)
        a["error"] = shown_err
        dl_errors.append(a)
        try:                                     # 不丢消息: 失败也继续回复文字部分
            with open(os.path.join(STATE, "download-errors.log"), "a",
                      encoding="utf-8") as f:
                f.write(json.dumps({"time": time.time(),
                                    "update_id": a["update_id"],
                                    "file_id": a["file_id"], "error": shown_err},
                                   ensure_ascii=False) + "\n")
        except OSError:
            pass

# 把 _local_name / vps_path / remote_only 持久化进 processing/ 里的记录
# (崩溃重跑时 finish 还能按记录找到文件, 不论是本机还是 VPS 上的)
for r in recs:
    if not (r.get("_local_name") or r.get("vps_path")):
        continue
    pth = r.get("_claimed_path")
    if not pth:
        continue
    try:
        with open(pth + ".tmp", "w", encoding="utf-8") as f:
            json.dump(r, f, ensure_ascii=False)
        os.replace(pth + ".tmp", pth)
    except OSError:
        pass

# ---------- 归属记录: 这一批是谁的 ----------
claim_id = f"{os.getpid()}-{int(time.time() * 1000)}"
claimed_uids = [u for u, _ in claimed]
chat_id = next((r.get("chat_id") for r in recs if r.get("chat_id")), None)
try:
    with open(os.path.join(CLAIMD, claim_id + ".json") + ".tmp", "w",
              encoding="utf-8") as f:
        json.dump({"claim_id": claim_id, "uids": claimed_uids, "chat_id": chat_id,
                   "time": time.time(), "count": len(recs)}, f, ensure_ascii=False)
    os.replace(os.path.join(CLAIMD, claim_id + ".json") + ".tmp",
               os.path.join(CLAIMD, claim_id + ".json"))
except OSError as e:
    log(f"写归属记录失败 {claim_id}: {e}")

# 被本次认领覆盖的旧归属记录一律作废, 避免 state/claim/ 里堆着互相矛盾的归属
try:
    for n in os.listdir(CLAIMD):
        if not n.endswith(".json") or n[:-5] == claim_id:
            continue
        d = read_json(os.path.join(CLAIMD, n)) or {}
        try:
            old = set(int(x) for x in (d.get("uids") or []))
        except (TypeError, ValueError):
            old = set()
        if old & set(claimed_uids):
            try:
                os.remove(os.path.join(CLAIMD, n))
            except OSError:
                pass
except OSError:
    pass

uids_arg = ",".join(str(u) for u in claimed_uids)
out("claimed",
    claim_id=claim_id,
    claimed_uids=claimed_uids,
    uids_arg=uids_arg,
    batch_key=claimed_uids[-1],
    count=len(recs),
    chat_id=chat_id,
    takeover=bool(takeover),
    records=recs,
    mode=MODE,
    attachments=downloaded,
    remote_only=remote_only,
    attachment_errors=dl_errors,
    over_cap=over_cap,
    pull_max_bytes=PULL_MAX_BYTES if MODE == "local" else None,
    warnings=[w for w in (
        ("本地模式未设置 TG_VPS_STAGING_DIR: helper 会直接写进 inbox/files。"
         "桥与 Bot API 服务器不同机时, 这等于把大文件下进沙箱 —— 请设为 VPS 上的目录。")
        if (MODE == "local" and STAGE_DIR == FILES) else None,
        ("本地模式未配置 TG_VPS_FETCH_CMD: 文件会经 helper 先进沙箱, "
         "50MB 政策线无法保证(大文件照样会被拉进来)。"
         "跨机部署请配成 \"在服务器侧执行 getFile\" 的命令。")
        if (MODE == "local" and not VPS_FETCH_CMD) else None,
    ) if w],
    processing_dir=PROC,
    next_step=("生成一条回复(一批只回一条), 然后用 claim_id 收尾:\n"
               f"  bash <bridge>/tg_finish.sh --chat-id {chat_id} "
               f"--claim-id {claim_id} --stdin <<'TGEOF'\n  <回复正文>\n  TGEOF"))
PYEOF
