#!/bin/bash

#================================================================================
# Komari Monitor RS 安装脚本（修正版）
#
# 功能:
#   - 检查 Root 权限 & systemd
#   - 自动安装依赖 (wget 或 curl)
#   - 自动检测系统架构并下载对应程序
#   - 根据命令行参数或交互配置 Agent
#   - 创建 / 更新 systemd 服务实现后台保活和开机自启
#
# 重要说明:
#   - 默认在 HTTPS / WSS 场景下 自动开启 --tls
#   - 若 WS 使用 wss:// 且你忘了写 --tls，会自动补上，解决常见 wss 连接问题
#
# GitHub 仓库: https://github.com/GenshinMinecraft/komari-monitor-rs
#================================================================================

set -euo pipefail

# --- 配置 ---

# GitHub 仓库信息
GITHUB_REPO="GenshinMinecraft/komari-monitor-rs"

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
        log_error "此脚本需要 root 权限，请使用 'sudo bash install.sh' 运行。"
        exit 1
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "未检测到 systemctl，此脚本仅支持使用 systemd 的发行版（如 Debian/Ubuntu 等）。"
        exit 1
    fi
}

# --- 依赖安装 ---

install_dependencies() {
    if command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then
        return 0
    fi

    log_info "未检测到 wget / curl，尝试安装 'wget'..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && apt-get install -y wget
    elif command -v yum >/dev/null 2>&1; then
        yum install -y wget
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y wget
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm wget
    else
        log_error "未找到支持的包管理器 (apt/yum/dnf/pacman)。请手动安装 wget 或 curl 后再运行此脚本。"
        exit 1
    fi

    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        log_error "安装 'wget' 失败，且系统中不存在 curl。请检查系统环境。"
        exit 1
    fi

    log_info "依赖安装完成。"
}

# 实际下载逻辑 (wget 优先，其次 curl)
_do_download() {
    local url="$1"
    local dest="$2"

    if command -v wget >/dev/null 2>&1; then
        wget -O "$dest" "$url"
    else
        curl -fL "$url" -o "$dest"
    fi
}

# --- 架构检测 ---

get_arch() {
    local arch
    arch=$(uname -m)

    case "$arch" in
        x86_64)
            # 优先选择 gnu，因为通用性更强
            echo "komari-monitor-rs-linux-x86_64-gnu"
            ;;
        i686|i386)
            echo "komari-monitor-rs-linux-i686-gnu"
            ;;
        aarch64)
            echo "komari-monitor-rs-linux-aarch64-gnu"
            ;;
        armv7l)
            # armv7l 通常对应 armv7-gnueabihf
            echo "komari-monitor-rs-linux-armv7-gnueabihf"
            ;;
        armv5*|armv6l)
            echo "komari-monitor-rs-linux-armv5te-gnueabi"
            ;;
        *)
            log_error "不支持的系统架构: $arch"
            log_error "请从以下地址手动选择并下载对应文件:"
            log_error "  https://github.com/${GITHUB_REPO}/releases/latest"
            exit 1
            ;;
    esac
}

# --- 下载并安装二进制 ---

download_binary() {
    install_dependencies

    local arch_file
    arch_file=$(get_arch)

    # 官方直连地址
    local base_url="https://github.com/${GITHUB_REPO}/releases/download/latest/${arch_file}"
    local download_url="${base_url}"

    # 如果设置了 GITHUB_PROXY（例如 https://ghfast.top/），优先走代理
    if [ -n "${GITHUB_PROXY:-}" ]; then
        local proxy_prefix
        proxy_prefix="${GITHUB_PROXY%/}/"
        download_url="${proxy_prefix}https://github.com/${GITHUB_REPO}/releases/download/latest/${arch_file}"
    fi

    log_info "检测到系统架构: $(uname -m)"
    log_info "优先下载地址: ${download_url}"

    local tmp_file
    tmp_file=$(mktemp -t komari-monitor-rs.XXXXXX)

    # 如果服务正在运行，先尝试停掉，方便覆盖安装
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_info "检测到正在运行的服务 ${SERVICE_NAME}，尝试先停止以便覆盖安装..."
        systemctl stop "${SERVICE_NAME}" || log_warn "停止服务失败，将继续尝试覆盖安装。"
    fi

    # 先用（可能带代理的）地址下载，不行再回退直连
    if ! _do_download "${download_url}" "${tmp_file}"; then
        log_warn "通过 ${download_url} 下载失败。"
        if [ "${download_url}" != "${base_url}" ]; then
            log_info "尝试回退到直连 GitHub: ${base_url}"
            if ! _do_download "${base_url}" "${tmp_file}"; then
                log_error "下载失败！请检查网络连接或确认该架构的文件是否存在。"
                rm -f "${tmp_file}"
                exit 1
            fi
        else
            log_error "下载失败！请检查网络连接或确认该架构的文件是否存在。"
            rm -f "${tmp_file}"
            exit 1
        fi
    fi

    # 使用 install 原子覆盖，解决“不能覆盖安装”的问题
    install -m 755 "${tmp_file}" "${INSTALL_PATH}"
    rm -f "${tmp_file}"

    log_info "程序已成功下载并安装到: ${INSTALL_PATH}"
}

# --- 创建 / 更新 systemd 服务 ---

create_or_update_service() {
    local http_server="$1"
    local ws_server="$2"
    local token="$3"
    local fake="$4"
    local interval="$5"
    local tls_flag="$6"
    local ignore_cert_flag="$7"
    local terminal_enabled="$8"
    local terminal_entry="$9"

    log_info "正在创建 / 更新 systemd 服务: ${SERVICE_NAME}"

    # 使用 --option=value 形式，避免 ExecStart 引号转义问题
    local exec_start_cmd="${INSTALL_PATH}"
    exec_start_cmd="${exec_start_cmd} --http-server=${http_server}"
    exec_start_cmd="${exec_start_cmd} --ws-server=${ws_server}"
    exec_start_cmd="${exec_start_cmd} --token=${token}"
    exec_start_cmd="${exec_start_cmd} --fake=${fake}"
    exec_start_cmd="${exec_start_cmd} --realtime-info-interval=${interval}"

    if [ -n "${tls_flag}" ]; then
        exec_start_cmd="${exec_start_cmd} ${tls_flag}"
    fi
    if [ -n "${ignore_cert_flag}" ]; then
        exec_start_cmd="${exec_start_cmd} ${ignore_cert_flag}"
    fi
    if [ "${terminal_enabled}" = "1" ]; then
        exec_start_cmd="${exec_start_cmd} --terminal --terminal-entry=${terminal_entry}"
    fi

    # 若已有服务，先尝试停止（为覆盖安装铺路）
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_info "检测到已有运行中的服务 '${SERVICE_NAME}'，正在停止以便更新..."
        systemctl stop "${SERVICE_NAME}" || log_warn "停止服务失败，将继续尝试更新。"
    fi

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Komari Monitor RS Agent Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=${exec_start_cmd}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    log_info "systemd 服务文件已写入: ${SERVICE_FILE}"

    log_info "正在重载 systemd 配置并启用服务..."
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1 || log_warn "启用服务时出现提示（通常是已启用），可以忽略。"
    systemctl restart "${SERVICE_NAME}"

    sleep 2
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
        log_info "服务 '${SERVICE_NAME}' 已成功启动并正在运行！"
        log_info "查看状态: systemctl status ${SERVICE_NAME}"
        log_info "查看日志:  journalctl -u ${SERVICE_NAME} -f"
    else
        log_error "服务 '${SERVICE_NAME}' 启动失败！"
        log_error "请使用 'systemctl status ${SERVICE_NAME}' 和 'journalctl -u ${SERVICE_NAME}' 检查错误详情。"
        exit 1
    fi
}

# --- 主程序 ---

main() {
    check_root
    log_info "Komari Monitor RS 安装程序已启动。"

    # 参数初始化
    local HTTP_SERVER=""
    local WS_SERVER=""
    local TOKEN=""
    local FAKE="1"
    local INTERVAL="1000"

    # TLS 默认行为：
    #  - TLS_FLAG: 最终是否传 --tls
    #  - TLS_AUTO: 是否允许自动根据 https/wss 推断
    local TLS_FLAG=""
    local TLS_AUTO=1
    local IGNORE_CERT_FLAG=""

    # Web Terminal (webssh) 相关
    local TERMINAL_ENABLED=0
    local TERMINAL_ENTRY_VALUE="default"

    # 解析命令行参数
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --http-server)
                HTTP_SERVER="$2"; shift 2;;
            --ws-server)
                WS_SERVER="$2"; shift 2;;
            -t|--token)
                TOKEN="$2"; shift 2;;
            -f|--fake)
                FAKE="$2"; shift 2;;
            --realtime-info-interval)
                INTERVAL="$2"; shift 2;;
            --tls)
                TLS_FLAG="--tls"
                TLS_AUTO=0
                shift 1;;
            --no-tls)
                # 脚本自带开关，不传给程序，用于强制关闭自动 TLS
                TLS_FLAG=""
                TLS_AUTO=0
                shift 1;;
            --ignore-unsafe-cert)
                IGNORE_CERT_FLAG="--ignore-unsafe-cert"
                shift 1;;
            --terminal)
                TERMINAL_ENABLED=1
                shift 1;;
            --terminal-entry)
                TERMINAL_ENTRY_VALUE="$2"
                shift 2;;
            *)
                log_warn "未知的参数: $1"
                shift 1;;
        esac
    done

    # 交互式输入必要参数
    if [ -z "${HTTP_SERVER}" ]; then
        read -p "请输入主控 Http 地址 (例如 https://your.domain:25774): " HTTP_SERVER
    fi
    if [ -z "${WS_SERVER}" ]; then
        read -p "请输入主控 WebSocket 地址 (例如 wss://your.domain:25774 或 ws://your.domain:25774): " WS_SERVER
    fi
    if [ -z "${TOKEN}" ]; then
        read -p "请输入 Token: " TOKEN
    fi

    if [ -z "${HTTP_SERVER}" ] || [ -z "${WS_SERVER}" ] || [ -z "${TOKEN}" ]; then
        log_error "Http 地址、WebSocket 地址和 Token 不能为空。"
        exit 1
    fi

    # 交互启用 Web Terminal（若未通过参数开启）
    if [ "${TERMINAL_ENABLED}" -eq 0 ]; then
        read -p "是否启用 Web Terminal 功能（webssh）? (y/N): " enable_terminal
        enable_terminal=$(echo "${enable_terminal}" | tr '[:upper:]' '[:lower:]')
        if [[ "${enable_terminal}" == "y" || "${enable_terminal}" == "yes" ]]; then
            TERMINAL_ENABLED=1
            read -p "可选：自定义 Terminal Entry (默认 default，直接回车跳过): " entry
            if [ -n "${entry}" ]; then
                TERMINAL_ENTRY_VALUE="${entry}"
            fi
        fi
    fi

    # --- 自动 TLS 逻辑：修复常见 wss 问题 ---
    # 若用户没有强制指定 --tls / --no-tls，则根据 URL 自动启用 TLS
    if [ "${TLS_AUTO}" -eq 1 ]; then
        if [[ "${HTTP_SERVER}" == https://* ]] || [[ "${WS_SERVER}" == wss://* ]]; then
            TLS_FLAG="--tls"
            log_info "检测到使用 HTTPS/WSS，已自动启用 TLS (--tls)。"
        fi
    fi

    # 若 WS 为 wss:// 但最终没有启用 TLS，给出警告（通常是用户显式 --no-tls 的情况）
    if [[ "${WS_SERVER}" == wss://* ]] && [ -z "${TLS_FLAG}" ]; then
        log_warn "WS 地址以 wss:// 开头但未启用 TLS，这通常会导致连接失败，请确认这是你刻意的配置。"
    fi

    log_info "配置信息确认:"
    echo "  - Http Server:   ${HTTP_SERVER}"
    echo "  - WS Server:     ${WS_SERVER}"
    echo "  - Token:         ********"
    echo "  - 虚假倍率:      ${FAKE}"
    echo "  - 上传间隔:      ${INTERVAL} ms"
    echo "  - 启用 TLS:      ${TLS_FLAG:-未启用}"
    echo "  - 忽略证书校验:  ${IGNORE_CERT_FLAG:-未启用}"
    if [ "${TERMINAL_ENABLED}" -eq 1 ]; then
        echo "  - Web Terminal:  启用 (entry = ${TERMINAL_ENTRY_VALUE})"
    else
        echo "  - Web Terminal:  未启用"
    fi
    echo ""

    # 下载 / 覆盖安装二进制
    download_binary

    # 创建 / 更新 systemd 服务
    create_or_update_service \
        "${HTTP_SERVER}" \
        "${WS_SERVER}" \
        "${TOKEN}" \
        "${FAKE}" \
        "${INTERVAL}" \
        "${TLS_FLAG}" \
        "${IGNORE_CERT_FLAG}" \
        "${TERMINAL_ENABLED}" \
        "${TERMINAL_ENTRY_VALUE}"
}

main "$@"