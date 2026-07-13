#!/bin/bash

#================================================================================
# Komari Monitor RS 一键安全卸载脚本
#
# 功能:
#   - 检查 Root 权限 & systemd
#   - 自动检测并安全停止运行中的监控服务
#   - 禁用开机自启并清理 systemd 配置文件
#   - 清理二进制可执行文件
#================================================================================

set -euo pipefail

# --- 配置 ---

# 安装路径
INSTALL_PATH="/usr/local/bin/komari-monitor-rs"

# systemd 服务名称
SERVICE_NAME="komari-monitor-rs"

# systemd 服务文件路径
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# --- 日志函数 ---
log_info() {
    echo -e "${GREEN}[信息] $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[警告] $1${NC}"
}

log_error() {
    echo -e "${RED}[错误] $1${NC}"
}

# --- 基础检查 ---

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "此脚本需要 root 权限，请使用 'sudo bash uninstall.sh' 运行。"
        exit 1
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "未检测到 systemctl，此脚本仅支持使用 systemd 的发行版（如 Debian/Ubuntu 等）。"
        exit 1
    fi
}

# --- 卸载主逻辑 ---

uninstall() {
    log_info "开始安全卸载 Komari Monitor RS..."

    # 1. 停止并禁用服务
    if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        log_info "正在停止运行中的服务..."
        systemctl stop "${SERVICE_NAME}" || log_warn "停止服务失败，可能已经停止。"
    fi
    
    if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
        log_info "正在禁用开机自启..."
        systemctl disable "${SERVICE_NAME}" || true
    fi

    # 2. 删除 systemd 服务文件并重载
    if [ -f "${SERVICE_FILE}" ]; then
        rm -f "${SERVICE_FILE}"
        systemctl daemon-reload
        log_info "已清理服务配置文件: ${SERVICE_FILE}"
    else
        log_info "未找到服务配置文件，跳过清理: ${SERVICE_FILE}"
    fi

    # 3. 删除二进制可执行文件
    if [ -f "${INSTALL_PATH}" ]; then
        rm -f "${INSTALL_PATH}"
        log_info "已清理二进制可执行文件: ${INSTALL_PATH}"
    else
        log_info "未找到二进制可执行文件，跳过清理: ${INSTALL_PATH}"
    fi

    log_info "卸载完成！系统环境中已无 Komari Monitor RS 残留。"
}

# --- 主程序 ---

main() {
    check_root
    uninstall
}

main "$@"