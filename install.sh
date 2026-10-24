#!/usr/bin/env bash
# tg-bridge 一键安装
#
#   交互: curl -fsSL https://raw.githubusercontent.com/a-scc/tg-bridge/main/install.sh | bash
#   非交互(自动装服务):
#         curl -fsSL .../install.sh | TG_OWNER_ID=<你的数字id> TG_INSTALL_SYSTEMD=1 bash
#   本地: bash install.sh
#
# 可用环境变量:
#   TG_BRIDGE_DIR        安装目录       (默认 <home>/workspace/tg-bridge-deploy)
#   TG_BRIDGE_USER       服务运行用户   (默认 $SUDO_USER, 否则当前用户)
#   TG_BRIDGE_BRANCH     分支           (默认 main)
#   TG_HELPER            tg.py 连接器   (默认 <home>/workspace/custom-connectors/custom.telegram/bin/tg.py)
#   TG_OWNER_ID          你的 TG 数字 id (装 systemd 服务时必填)
#   TG_INSTALL_SYSTEMD   1=装 0=不装    (默认 auto: 终端下询问, 管道下不装)
#
# 参数:
#   --force   自检没过也继续装(只该在"只装代码、先不启用服务"时用)
#
# 安装前会真验一遍 helper(不是只看文件在不在): 离线查 5 个子命令认不认,
# 没有桥在跑时再真打一次 getUpdates。不通过直接中止、什么都不装 ——
# 否则会装出一个 systemd 显示 active、实际一条消息都捡不到的"活死人"。
#
# 本脚本只装代码 + 服务单元。Bot Token 由连接器提供, Hatch hook 在 Hatch 侧配置, 都不在仓库里。
set -euo pipefail

REPO_URL="${TG_BRIDGE_REPO:-https://github.com/a-scc/tg-bridge.git}"
BRANCH="${TG_BRIDGE_BRANCH:-main}"
RUN_USER="${TG_BRIDGE_USER:-${SUDO_USER:-$(id -un)}}"
RUN_HOME="$(getent passwd "$RUN_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "${RUN_HOME:-}" ] || RUN_HOME="$HOME"
INSTALL_DIR="${TG_BRIDGE_DIR:-$RUN_HOME/workspace/tg-bridge-deploy}"
TG_HELPER="${TG_HELPER:-$RUN_HOME/workspace/custom-connectors/custom.telegram/bin/tg.py}"
UNIT_NAME="tg-bridge-poller.service"
UNIT_DST="/etc/systemd/system/$UNIT_NAME"

die() { printf '错误: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force)    FORCE=1; shift ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *)          die "未知参数: $1 (可用: --force)" ;;
  esac
done

say "=== tg-bridge 安装 ==="
say "  安装目录: $INSTALL_DIR"
say "  运行用户: $RUN_USER (home=$RUN_HOME)"
say "  连接器  : $TG_HELPER"
say ""

# --- 1/5 依赖 -------------------------------------------------------------
# 注意: tg.py 连接器不在本仓库里(它持有 Bot Token, 走 Secure Vault)。缺了它
# poller 会无限重试、claim/finish 会失败, 所以这里直接顶回去, 不让它装成半残。
for c in git python3; do
  command -v "$c" >/dev/null 2>&1 || die "缺少依赖: $c"
done
PYTHON="$(command -v python3)"
[ -f "$TG_HELPER" ] || die "找不到连接器: $TG_HELPER
  本仓库不含 tg.py (Bot Token 不落盘, 由 Secure Vault 提供)。
  请先配好 custom.telegram 连接器, 或用 TG_HELPER=/path/to/tg.py 指定。"
# ---- helper 自检: 两道探针, 目的只有一个 —— 别装出一个"活死人" ----
# 症状: systemd 看是 active, 日志里全是 poll error, 一条消息都捡不到。
# 原因: helper 不认 getupdates/send 这些子命令, 而只查"文件在不在"是查不出来的。
#
# 探针 1 (离线, 必做): 给每个子命令塞一个不存在的参数。
#   argparse 对"子命令不存在"报 invalid choice; 对"子命令存在但参数不认识"报
#   unrecognized arguments。所以看到 invalid choice 就是缺这个命令。
#   不联网、不发消息、不和 poller 抢 getUpdates。
# 探针 2 (联网, 有条件): 真打一次 getupdates --timeout 1 --offset 0。
#   只有当前没有桥在跑时才做 —— 否则会和它抢同一个 bot, 把正在跑的那个打成 409。
#   offset=0 不会确认任何待处理消息, 真 poller 之后照拿不误。
# 找真正的旧 listener 进程。不能只 pgrep -f 'listener\.py':
# 那样连"命令行里提到 listener.py"的 shell/pgrep 自己都会命中, 造成误判。
# 这里要求命令的第一个 token 是 python* —— 真进程长这样: python3 /path/listener.py
_legacy_listeners() {
  command -v pgrep >/dev/null 2>&1 || return 0
  pgrep -af 'listener\.py' 2>/dev/null | awk '$2 ~ /^[^ ]*python[0-9.]*$/ {print $1}' | tr '\n' ' '
}

_py() {   # 带超时跑 helper: 有些 argparse 用 parse_known_args, 塞假参数它不报错而是真去
          # 长轮询(默认 50 秒)。这里封顶 10 秒, 免得自检自己卡住。
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 python3 "$@"
  else
    python3 "$@"
  fi
}

_helper_offline() {
  _bad=""
  for _v in getupdates react typing download send; do
    _out="$(_py "$TG_HELPER" "$_v" --__tg_probe__ 1 2>&1)" || true
    case "$_out" in
      *"invalid choice"*) _bad="$_bad $_v" ;;
    esac
  done
  [ -z "$_bad" ]
}

_helper_live() {
  _rc=0
  _out="$(_py "$TG_HELPER" getupdates --timeout 1 --offset 0 2>&1)" || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    say "      rc=$_rc  $(printf '%s' "$_out" | tail -2 | tr '\n' ' ')"
    return 1
  fi
  if ! printf '%s' "$_out" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
    say "      输出: $(printf '%s' "$_out" | tail -2 | tr '\n' ' ')"
    return 1
  fi
  return 0
}

_probe_fail() {   # $1 = 说明
  if [ "$FORCE" = "1" ]; then
    say "  ⚠️  $1"
    say "      --force: 继续安装, 但桥很可能起不来。"
  else
    die "$1

  helper 不通 = poller 卡在 getUpdates 空转 / finish 永远 send_failed / claim 附件全失败。
  先自查:  python3 $TG_HELPER getupdates --timeout 1 --offset 0
  返回 {\"ok\": true} 才算通。路径不对就改 TG_HELPER 重跑。

  如果本机 helper 的 CLI 是另一套词表(例如 get-updates / send-message / chat-action),
  用仓库自带的适配器, 不用改桥也不用改 helper:
      TG_HELPER=<安装目录>/bin/tg_adapter.py  TG_HELPER_REAL=<真实 helper 路径>
  适配器只翻译动词/参数/返回 JSON。先 --force 把代码装下来, 再按上面两个变量重跑。

  明知不可用仍要装(只装代码不启用服务):  bash install.sh --force"
  fi
}

if ! _helper_offline; then
  _probe_fail "helper 不认这些子命令:$_bad"
fi

# 当前有桥在跑就跳过联网探针, 避免抢 getUpdates
_bridge_live=0
systemctl is-active --quiet tg-bridge-poller.service >/dev/null 2>&1 && _bridge_live=1
[ -n "$(_legacy_listeners)" ] && _bridge_live=1
if [ "$_bridge_live" = "1" ]; then
  say "      跳过联网自检: 检测到桥还在跑, 现在打 getUpdates 会让它 409"
else
  if ! _helper_live; then
    _probe_fail "helper 的 getupdates 没通过(见上)"
  fi
fi

say "[1/5] 依赖检查通过"

# --- 2/5 代码 -------------------------------------------------------------
if [ -d "$INSTALL_DIR/.git" ]; then
  say "[2/5] 更新已有安装"
  git -C "$INSTALL_DIR" fetch -q origin "$BRANCH" || die "git fetch 失败, 检查网络与仓库权限"
  # 不用 pull || true 吞错: 本地有改动时必须停下来, 否则会带着混合状态继续装
  git -C "$INSTALL_DIR" merge --ff-only "origin/$BRANCH" \
    || die "无法快进更新(${INSTALL_DIR} 有本地改动或分支分歧)
  处理完再重跑: git -C $INSTALL_DIR status"
elif [ -e "$INSTALL_DIR" ]; then
  die "$INSTALL_DIR 已存在但不是 git 仓库。请先移走, 或用 TG_BRIDGE_DIR 指定其他目录。"
else
  say "[2/5] 克隆 $REPO_URL (分支 $BRANCH)"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone -q --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi
cd "$INSTALL_DIR"

# --- 3/5 目录与可执行位 ---------------------------------------------------
# checker 会被 Hatch hook 调用; 给 +x 后 ./ 与 bash 两种调用方式都能用
mkdir -p inbox/done/closed inbox/processing inbox/files state/sent
chmod +x tg_claim.sh tg_finish.sh tg_bridge_check.sh
git config core.fileMode false          # ← 新增: 权限位变化不再算本地改动
say "[3/5] 运行时目录与可执行位就绪"

# --- 4/5 systemd ----------------------------------------------------------
want="${TG_INSTALL_SYSTEMD:-auto}"
install_service=0
case "$want" in
  1|yes|true)  install_service=1 ;;
  0|no|false)  install_service=0 ;;
  auto)
    if [ -t 0 ] && [ -t 1 ]; then
      ans=""
      read -r -p "现在安装并启动 systemd 服务? [y/N] " ans || ans=""
      [[ "$ans" =~ ^[Yy] ]] && install_service=1
    else
      # curl | bash 时 stdin 是脚本本身, 绝不能 read(会把脚本文本当答复吃掉)。
      # 这里显式说明为什么跳过, 而不是静默走 else。
      say "[4/5] 检测到非交互执行(管道), 跳过服务安装。"
      say "      需要自动安装请重跑: TG_OWNER_ID=<你的数字id> TG_INSTALL_SYSTEMD=1 bash install.sh"
    fi
    ;;
  *) die "TG_INSTALL_SYSTEMD 只接受 1 / 0 / auto" ;;
esac

if [ "$install_service" = 1 ]; then
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
  else
    command -v sudo >/dev/null 2>&1 || die "安装 systemd 服务需要 root 或 sudo"
    SUDO="sudo"
  fi

  owner="${TG_OWNER_ID:-}"
  case "$owner" in
    ''|*[!0-9]*)
      die "TG_OWNER_ID 必填, 且必须是你自己的 Telegram 数字 id。
  查 id: 给 @userinfobot 发一条消息即可。
  例: curl -fsSL .../install.sh | TG_OWNER_ID=123456789 TG_INSTALL_SYSTEMD=1 bash" ;;
  esac

  [ -f "systemd/$UNIT_NAME" ] || die "仓库里缺少 systemd/$UNIT_NAME"
  _unit="$(mktemp)"
  sed -e "s|__RUN_USER__|$RUN_USER|g" \
      -e "s|__RUN_HOME__|$RUN_HOME|g" \
      -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
      -e "s|__PYTHON__|$PYTHON|g" \
      -e "s|__TG_OWNER_ID__|$owner|g" \
      -e "s|__TG_HELPER__|$TG_HELPER|g" \
      "systemd/$UNIT_NAME" > "$_unit"
  # 有占位符没替换掉就拒绝安装 —— 半填的 unit 起不来, 还会把错误藏进 journal
  if grep -q '__[A-Z_]*__' "$_unit"; then
    rm -f "$_unit"
    die "服务单元里还有未替换的占位符, 拒绝安装"
  fi
  $SUDO install -m 0644 "$_unit" "$UNIT_DST"
  rm -f "$_unit"
  # 同一个 bot 两个长轮询 → 409 → 新 poller exit 2(且 RestartPreventExitStatus=2 不再重启)
  if $SUDO systemctl is-active --quiet "$UNIT_NAME"; then
    say "      检测到 $UNIT_NAME 已在运行 → 先停再起(避免同一 bot 双轮询 409)"
    $SUDO systemctl stop "$UNIT_NAME" || true
  fi
  _legacy="$(_legacy_listeners)"
  # 只认第一列的单元名: 描述列里出现 "tg-bridge" 不算
  _other="$($SUDO systemctl list-units --type=service --all --no-legend 2>/dev/null \
            | awk '{print $1}' | grep -E '^tg-bridge[^ ]*\.service$' \
            | grep -v "^${UNIT_NAME}$" | tr '\n' ' ' || true)"
  if [ -n "$_legacy$_other" ] && [ "$FORCE" != "1" ]; then
    say ""
    [ -n "$_legacy" ] && say "  ⚠️  检测到旧 listener 进程: $_legacy"
    [ -n "$_other" ]  && say "  ⚠️  检测到其他 tg-bridge* 单元: $_other"
    die "旧桥还在跑。同一个 bot 双轮询会 409, 且新 poller 会 exit 2 停住。
  先停旧桥: systemctl stop <旧单元>  /  kill <旧 PID>
  确认已停、仍要继续: bash install.sh --force"
  fi
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now "$UNIT_NAME"
  say "[4/5] 服务已安装并启动: $UNIT_DST"
  sleep 1
  if ! $SUDO systemctl is-active --quiet "$UNIT_NAME"; then
    say ""
    say "⚠️  服务未处于 active 状态。看日志:"
    say "     journalctl -u $UNIT_NAME -n 50 --no-pager"
    say "     常见原因: 连接器路径不对 / TG_OWNER_ID 填错 / 出口代理配置"
  fi
else
  say "[4/5] 未安装 systemd 服务。手动安装:"
  say "      sudo cp systemd/$UNIT_NAME /etc/systemd/system/"
  say "      sudo systemctl daemon-reload && sudo systemctl enable --now $UNIT_NAME"
  say "     (手工 cp 前记得把 unit 里的 __RUN_USER__ / __INSTALL_DIR__ 等占位符换成实际值)"
fi

# --- 5/5 后续 -------------------------------------------------------------
say ""
say "[5/5] 还需手动完成:"
say "  1. Bot Token: 由 custom.telegram 连接器提供, 本仓库不接触、不落盘"
say "  2. Hatch hook: 每 5 秒调用一次  bash $INSTALL_DIR/tg_bridge_check.sh"
say "     —— 必须用 bash 调用(或用 chmod +x 后的路径), 它自己不常驻"
say "  3. 可选环境变量(改 hook 命令行或 unit 后对应重载):"
say "     TG_DEFER_WHILE_BUSY_SECS  忙时压制秒数, 默认 0(关闭); 设在 hook 命令行上, 不是 unit"
say "     TG_BATCH_GROUP_SECS       批量分组窗口, 默认 150; 只影响 batch_id 命名, 不影响投递时刻"
say "     TG_LONGPOLL_TIMEOUT       长轮询秒数, 默认 20(出口代理会掐 20-30s 的连接)"
say "     TG_PROC_STALE_SECS        processing/ 里的批全部超过这个时长才判死接管, 默认 1800"
say ""
say "=== 安装完成 ==="
say "处理流程见 HANDLING.md (tg_claim.sh + tg_finish.sh, 两步)"
say ""
say "如果用了 bin/tg_adapter.py, 这三处都要能看到 TG_HELPER 和 TG_HELPER_REAL:"
say "  a) systemd unit (install.sh 已注入 TG_HELPER, TG_HELPER_REAL 需自行加一行 Environment=)"
say "  b) Hatch hook 的命令行"
say "  c) agent 调用 tg_claim/tg_finish 的环境"
