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
      "systemd/$UNIT_NAME" > "$_unit"
  # 有占位符没替换掉就拒绝安装 —— 半填的 unit 起不来, 还会把错误藏进 journal
  if grep -q '__[A-Z_]*__' "$_unit"; then
    rm -f "$_unit"
    die "服务单元里还有未替换的占位符, 拒绝安装"
  fi
  $SUDO install -m 0644 "$_unit" "$UNIT_DST"
  rm -f "$_unit"
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
say "  3. 可选环境变量(改 $UNIT_DST 后 daemon-reload):"
say "     TG_DEFER_WHILE_BUSY_SECS  S1 忙时压制秒数, 默认 120; 追求最低延迟可设 30"
say "     TG_BATCH_GROUP_SECS       批量分组窗口, 默认 150; 只影响 batch_id 命名, 不影响投递时刻"
say "     TG_LONGPOLL_TIMEOUT       长轮询秒数, 默认 20(出口代理会掐 20-30s 的连接)"
say "     TG_PROC_STALE_SECS        processing/ 无心跳接管阈值, 默认 300"
say ""
say "=== 安装完成 ==="
say "处理流程见 HANDLING.md (tg_claim.sh + tg_finish.sh, 两步)"
