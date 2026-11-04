#!/usr/bin/env bash
# 一键构建并安装 Agent 账号管理器（macOS 14+）
#
# 用法：
#   ./install.sh                构建并安装到 /Applications（不可写时回退 ~/Applications）
#   ./install.sh --no-install   只构建，产物在 dist/AgentAccountManager.app
#   ./install.sh --no-open      安装后不自动启动
#   ./install.sh --help         查看帮助
#
# 也支持直接通过管道执行（脚本会自动克隆仓库到临时目录）：
#   curl -fsSL https://raw.githubusercontent.com/lwbhust/AgentAccountManager/main/install.sh | bash
set -euo pipefail

REPO_URL="${AGENT_ACCOUNT_MANAGER_REPO:-https://github.com/lwbhust/AgentAccountManager.git}"
MODE="install"
OPEN_AFTER=true
TMP_CLONE=""

usage() {
    cat <<'EOF'
用法：
  ./install.sh                构建并安装到 /Applications（不可写时回退 ~/Applications）
  ./install.sh --no-install   只构建，产物在 dist/AgentAccountManager.app
  ./install.sh --no-open      安装后不自动启动
  ./install.sh --help         查看帮助
EOF
}

for arg in "$@"; do
    case "$arg" in
        --no-install) MODE="build" ;;
        --no-open) OPEN_AFTER=false ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "未知参数: $arg"
            echo "用法: ./install.sh [--no-install] [--no-open]"
            exit 1
            ;;
    esac
done

cleanup() {
    if [ -n "$TMP_CLONE" ] && [ -d "$TMP_CLONE" ]; then
        rm -rf "$TMP_CLONE"
    fi
}
trap cleanup EXIT

echo "==> 检查运行环境..."

if [ "$(uname -s)" != "Darwin" ]; then
    echo "错误：本应用仅支持 macOS。"
    exit 1
fi

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
if [ "$OS_MAJOR" -lt 14 ]; then
    echo "错误：需要 macOS 14 或更高版本（当前 $OS_VERSION）。"
    exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "错误：未找到 Swift 工具链。"
    echo "请安装完整 Xcode，或执行: xcode-select --install"
    exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
    echo "错误：未找到 Xcode Command Line Tools。"
    echo "请执行: xcode-select --install"
    exit 1
fi

echo "    macOS $OS_VERSION · $(swift --version 2>/dev/null | head -n 1)"

# 支持 curl | bash：不在仓库根目录时自动浅克隆到临时目录
if [ ! -f "Package.swift" ]; then
    if ! command -v git >/dev/null 2>&1; then
        echo "错误：未找到 git，无法自动下载源码。"
        exit 1
    fi
    echo "==> 未检测到源码，克隆 $REPO_URL ..."
    TMP_CLONE="$(mktemp -d "${TMPDIR:-/tmp}/agentaccountmanager.XXXXXX")"
    git clone --depth 1 "$REPO_URL" "$TMP_CLONE/AgentAccountManager"
    cd "$TMP_CLONE/AgentAccountManager"
fi

if [ "$MODE" = "install" ]; then
    echo "==> 构建并安装..."
    ./package.sh --install

    if [ "$OPEN_AFTER" = true ]; then
        echo "==> 启动应用..."
        open -a "Agent 账号管理器" 2>/dev/null || true
    fi
    echo "==> 完成。应用已安装，数据保存在 ~/Library/Application Support/AgentAccountManager。"
else
    echo "==> 仅构建..."
    ./package.sh
    echo "==> 完成：dist/AgentAccountManager.app"
fi
