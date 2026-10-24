#!/usr/bin/env bash
# tg-bridge 一键安装脚本
# 用法: curl -fsSL https://raw.githubusercontent.com/a-scc/tg-bridge/main/install.sh | bash
# 或: bash install.sh
#
# 本脚本会:
# 1. 下载仓库文件到 ~/workspace/tg-bridge-deploy/ (或 $TG_BRIDGE_DIR)
# 2. 创建 inbox/、state/、inbox/done/closed/、inbox/processing/、inbox/files/ 目录
# 3. 安装 systemd 服务 (需要 sudo 或 root)
# 4. 提示配置 Bot Token (走连接器，不进脚本)
#
# 注意: 本脚本安装的是代码，生产配置 (环境变量、Hatch hook、Bot Token) 需另外配置。
# 生产环境变量示例见 systemd/tg-bridge-poller.service 中的注释。
set -euo pipefail

REPO_URL="https://github.com/a-scc/tg-bridge.git"
INSTALL_DIR="${TG_BRIDGE_DIR:-$HOME/workspace/tg-bridge-deploy}"
BRANCH="${TG_BRIDGE_BRANCH:-main}"

echo "=== tg-bridge 一键安装 ==="
echo "安装目录: $INSTALL_DIR"
echo "仓库: $REPO_URL (分支: $BRANCH)"
echo ""

# 检查依赖
for cmd in git python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "错误: 需要 $cmd，请先安装" >&2
    exit 1
  fi
done

# 克隆或更新
if [ -d "$INSTALL_DIR/.git" ]; then
  echo "目录已存在，正在更新..."
  cd "$INSTALL_DIR"
  git pull origin "$BRANCH" || true
else
  echo "正在克隆仓库..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone --branch "$BRANCH" --depth 1 "$REPO_URL" "$INSTALL_DIR"
  cd "$INSTALL_DIR"
fi

# 创建运行时目录
echo "正在创建运行时目录..."
mkdir -p inbox/done/closed inbox/processing inbox/files state/sent

# 设可执行权限
chmod +x tg_claim.sh tg_finish.sh 2>/dev/null || true
chmod +x poller.py 2>/dev/null || true

echo ""
echo "=== 文件已就位 ==="
ls -lh tg_claim.sh tg_finish.sh HANDLING.md poller.py tg_bridge_check.sh typing_loop.py 2>&1 | head -10

echo ""
echo "=== systemd 服务 ==="
if [ -f "systemd/tg-bridge-poller.service" ]; then
  echo "服务文件: systemd/tg-bridge-poller.service"
  echo ""
  echo "安装服务 (需要 sudo):"
  echo "  sudo cp systemd/tg-bridge-poller.service /etc/systemd/system/"
  echo "  sudo systemctl daemon-reload"
  echo "  sudo systemctl enable --now tg-bridge-poller"
  echo ""
  read -p "是否现在安装 systemd 服务? (需要 sudo) [y/N] " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    sudo cp systemd/tg-bridge-poller.service /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl enable --now tg-bridge-poller
    echo "服务已启动: systemctl status tg-bridge-poller"
  else
    echo "跳过 systemd 安装，请手动执行上述命令"
  fi
else
  echo "警告: 未找到 systemd/tg-bridge-poller.service" >&2
fi

echo ""
echo "=== 后续配置 (必须手动完成) ==="
echo "1. Bot Token: 走连接器配置，不写进文件 (见 HANDLING.md 红线)"
echo "2. Hatch hook: 在 Hatch 里配置每 5 秒唤醒的 hook (不在仓库里)"
echo "3. 生产环境变量: 按需修改 systemd/tg-bridge-poller.service 中的 Environment 行"
echo "   - TG_DEFER_WHILE_BUSY_SECS: S1 压制秒数 (生产用 120，补丁 03 改到 30)"
echo "   - TG_BATCH_GROUP_SECS: 150 (生产) vs 基线 20"
echo "   - TG_LONGPOLL_TIMEOUT: 20"
echo ""
echo "=== 安装完成 ==="
echo "处理流程见 HANDLING.md (tg_claim.sh + tg_finish.sh，两步)"
