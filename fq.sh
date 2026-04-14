#!/bin/bash
#=============================================================================
# SOCKS5 一键部署脚本 (Ubuntu / Debian) — 基于 sing-box
#
# 默认账号: unlil  密码: unlil  端口: 61080
# 自动:
#   - 关闭系统防火墙 (ufw / firewalld / iptables) 放行所有端口
#   - 清理端口占用 (包括旧的 danted 残留)
#   - 从 GitHub 官方 Release 下载 sing-box 最新版二进制
#   - 写入 systemd service, 日志走 journald (不依赖 /var/log)
#
# ----------------------------------------------------------------------------
# 使用
# ----------------------------------------------------------------------------
#   bash sk5.sh                                  # 默认 unlil/unlil/61080
#   bash sk5.sh -u admin -p MyPass -P 1080       # 自定义
#   curl -fsSL https://你的地址/sk5.sh | bash
#   curl -fsSL https://你的地址/sk5.sh | bash -s -- -u admin -p MyPass -P 1080
#   bash sk5.sh --uninstall                      # 卸载
#
# ----------------------------------------------------------------------------
# 部署后管理
# ----------------------------------------------------------------------------
#   状态  systemctl status sing-box
#   日志  journalctl -u sing-box -f
#   重启  systemctl restart sing-box
#   配置  /etc/sing-box/config.json
#=============================================================================

set -euo pipefail

#=============================================================================
# 默认配置
#=============================================================================
SOCKS5_USER="unlil"
SOCKS5_PASS="unlil"
SOCKS5_PORT="61080"

SERVICE_NAME="sing-box"
BIN_PATH="/usr/local/bin/sing-box"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_FILE="/etc/systemd/system/sing-box.service"

# Fallback 版本 (GitHub API 不通时使用)
SINGBOX_FALLBACK_VER="1.10.7"

ACTION="install"

#=============================================================================
# 颜色 & 日志
#=============================================================================
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_CYAN='\033[96m'
C_BOLD='\033[1m'
C_RST='\033[0m'

log_info() { echo -e "${C_CYAN}[INFO]${C_RST} $*"; }
log_ok()   { echo -e "${C_GREEN}[ OK ]${C_RST} $*"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RST} $*"; }
log_err()  { echo -e "${C_RED}[ERR ]${C_RST} $*" >&2; }
die()      { log_err "$*"; exit 1; }

#=============================================================================
# 参数
#=============================================================================
usage() {
    cat <<EOF
SOCKS5 一键部署脚本 (sing-box)

用法:
  bash $0 [选项]

选项:
  -u, --user USER    用户名 (默认: unlil)
  -p, --pass PASS    密码   (默认: unlil)
  -P, --port PORT    端口   (默认: 61080)
      --uninstall    卸载 sing-box
  -h, --help         显示帮助
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--user)    SOCKS5_USER="${2:-}"; shift 2 ;;
            -p|--pass)    SOCKS5_PASS="${2:-}"; shift 2 ;;
            -P|--port)    SOCKS5_PORT="${2:-}"; shift 2 ;;
            --uninstall)  ACTION="uninstall"; shift ;;
            -h|--help)    usage ;;
            *) log_warn "忽略未知参数: $1"; shift ;;
        esac
    done
}

#=============================================================================
# 基础检查
#=============================================================================
check_system() {
    [[ "$(id -u)" -eq 0 ]] || die "请使用 root 权限运行 (sudo -i)"
    command -v apt-get &>/dev/null || die "此脚本仅支持 Debian / Ubuntu"

    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        log_info "系统: ${PRETTY_NAME:-unknown}"
    fi
}

validate_params() {
    [[ -n "$SOCKS5_USER" ]] || die "用户名不能为空"
    [[ -n "$SOCKS5_PASS" ]] || die "密码不能为空"
    [[ "$SOCKS5_PORT" =~ ^[0-9]+$ ]] && (( SOCKS5_PORT >= 1 && SOCKS5_PORT <= 65535 )) \
        || die "端口范围 1-65535"
}

ensure_deps() {
    local need=()
    command -v curl  &>/dev/null || need+=(curl)
    command -v tar   &>/dev/null || need+=(tar)
    command -v ss    &>/dev/null || need+=(iproute2)
    if (( ${#need[@]} > 0 )); then
        log_info "安装依赖: ${need[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${need[@]}" \
            || die "依赖安装失败: ${need[*]}"
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7*|armv7l)  echo "armv7" ;;
        armv6*)         echo "armv6" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

#=============================================================================
# 关闭系统防火墙 + 放行所有端口
#=============================================================================
disable_firewall() {
    log_info "关闭系统防火墙，放行所有端口..."

    if command -v ufw &>/dev/null; then
        ufw --force disable >/dev/null 2>&1 || true
        log_ok "已禁用 ufw"
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q '^firewalld'; then
        systemctl stop firewalld >/dev/null 2>&1 || true
        systemctl disable firewalld >/dev/null 2>&1 || true
        log_ok "已禁用 firewalld"
    fi

    if command -v iptables &>/dev/null; then
        iptables -P INPUT   ACCEPT 2>/dev/null || true
        iptables -P FORWARD ACCEPT 2>/dev/null || true
        iptables -P OUTPUT  ACCEPT 2>/dev/null || true
        iptables -F 2>/dev/null || true
        iptables -X 2>/dev/null || true
        iptables -Z 2>/dev/null || true
        iptables -t nat    -F 2>/dev/null || true
        iptables -t nat    -X 2>/dev/null || true
        iptables -t mangle -F 2>/dev/null || true
        iptables -t mangle -X 2>/dev/null || true
        log_ok "iptables 规则已清空 (全部 ACCEPT)"
    fi

    if command -v ip6tables &>/dev/null; then
        ip6tables -P INPUT   ACCEPT 2>/dev/null || true
        ip6tables -P FORWARD ACCEPT 2>/dev/null || true
        ip6tables -P OUTPUT  ACCEPT 2>/dev/null || true
        ip6tables -F 2>/dev/null || true
        ip6tables -X 2>/dev/null || true
    fi

    if systemctl list-unit-files 2>/dev/null | grep -q '^netfilter-persistent'; then
        systemctl stop netfilter-persistent >/dev/null 2>&1 || true
        systemctl disable netfilter-persistent >/dev/null 2>&1 || true
    fi
}

#=============================================================================
# 清理冲突: 旧 danted + 端口占用
#=============================================================================
cleanup_conflicts() {
    log_info "清理可能的冲突服务与端口占用..."

    # 旧 danted 残留
    if systemctl list-unit-files 2>/dev/null | grep -q '^danted'; then
        systemctl stop danted    >/dev/null 2>&1 || true
        systemctl disable danted >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq dante-server >/dev/null 2>&1 || true
        rm -f /etc/danted.conf
        log_ok "已卸载旧 danted"
    fi

    # 停止自身，避免热重启端口占用
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true

    # 杀掉仍占用目标端口的进程
    local pids
    pids="$(ss -H -tlnp 2>/dev/null | awk -v p=":${SOCKS5_PORT}" '$4 ~ p {print $0}' \
        | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)"
    if [[ -n "$pids" ]]; then
        log_warn "端口 ${SOCKS5_PORT} 被进程 ${pids//$'\n'/ } 占用，强制终止"
        for pid in $pids; do kill -9 "$pid" 2>/dev/null || true; done
    fi
}

#=============================================================================
# 下载 & 安装 sing-box
#=============================================================================
get_latest_version() {
    local v
    v="$(curl -fsSL --max-time 10 \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
        | grep -oE '"tag_name":[[:space:]]*"v[^"]+"' \
        | head -1 | sed -E 's/.*"v([^"]+)".*/\1/')"
    if [[ -z "$v" ]]; then
        log_warn "GitHub API 获取版本失败, 使用 fallback: ${SINGBOX_FALLBACK_VER}"
        v="$SINGBOX_FALLBACK_VER"
    fi
    echo "$v"
}

install_singbox() {
    local arch ver pkg url tmp
    arch="$(detect_arch)"
    ver="$(get_latest_version)"
    pkg="sing-box-${ver}-linux-${arch}"
    url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${pkg}.tar.gz"

    log_info "下载 sing-box v${ver} (${arch})..."
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN

    # 主地址失败时尝试 ghproxy 镜像
    if ! curl -fsSL --max-time 60 "$url" -o "$tmp/sb.tar.gz"; then
        log_warn "GitHub 直连失败，尝试镜像..."
        curl -fsSL --max-time 90 "https://ghfast.top/${url}" -o "$tmp/sb.tar.gz" \
            || curl -fsSL --max-time 90 "https://mirror.ghproxy.com/${url}" -o "$tmp/sb.tar.gz" \
            || die "sing-box 下载失败，请检查网络"
    fi

    tar -xzf "$tmp/sb.tar.gz" -C "$tmp" || die "解压失败"
    [[ -f "$tmp/${pkg}/sing-box" ]] || die "压缩包内未找到 sing-box 二进制"

    install -m 0755 "$tmp/${pkg}/sing-box" "$BIN_PATH"
    log_ok "$("$BIN_PATH" version | head -1)"
}

#=============================================================================
# 配置文件 + systemd service
#=============================================================================
write_config() {
    mkdir -p "$CONFIG_DIR"
    log_info "写入配置 ${CONFIG_FILE}..."
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "0.0.0.0",
      "listen_port": ${SOCKS5_PORT},
      "users": [
        {
          "username": "${SOCKS5_USER}",
          "password": "${SOCKS5_PASS}"
        }
      ]
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF

    # 配置语法校验
    if ! "$BIN_PATH" check -c "$CONFIG_FILE" >/dev/null 2>&1; then
        log_err "sing-box 配置校验失败:"
        "$BIN_PATH" check -c "$CONFIG_FILE" || true
        exit 1
    fi
    log_ok "配置校验通过"
}

write_service() {
    log_info "写入 systemd service..."
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box proxy service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} run -c ${CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

start_service() {
    log_info "启动 ${SERVICE_NAME} 服务..."
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE_NAME"
    sleep 2

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_ok "服务运行正常"
    else
        log_err "服务启动失败，最近日志:"
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
        exit 1
    fi
}

#=============================================================================
# 输出结果
#=============================================================================
get_public_ip() {
    local ip
    for url in "https://api.ipify.org" "https://ifconfig.me" "https://checkip.amazonaws.com"; do
        ip="$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')"
        [[ -n "$ip" && "$ip" =~ ^[0-9a-fA-F\.\:]+$ ]] && { echo "$ip"; return; }
    done
    echo "YOUR_SERVER_IP"
}

print_result() {
    local ip; ip="$(get_public_ip)"
    echo ""
    echo -e "${C_GREEN}========================================${C_RST}"
    echo -e "${C_GREEN}${C_BOLD}      SOCKS5 部署成功 (sing-box)${C_RST}"
    echo -e "${C_GREEN}========================================${C_RST}"
    printf "  %-10s ${C_YELLOW}%s${C_RST}\n" "服务器 IP:" "$ip"
    printf "  %-10s ${C_YELLOW}%s${C_RST}\n" "端口:"      "$SOCKS5_PORT"
    printf "  %-10s ${C_YELLOW}%s${C_RST}\n" "用户名:"    "$SOCKS5_USER"
    printf "  %-10s ${C_YELLOW}%s${C_RST}\n" "密码:"      "$SOCKS5_PASS"
    echo ""
    echo -e "  连接串: ${C_CYAN}socks5://${SOCKS5_USER}:${SOCKS5_PASS}@${ip}:${SOCKS5_PORT}${C_RST}"
    echo ""
    echo -e "  测试: curl --socks5-hostname ${SOCKS5_USER}:${SOCKS5_PASS}@${ip}:${SOCKS5_PORT} https://ip.sb"
    echo -e "${C_GREEN}========================================${C_RST}"
    echo ""
    echo -e "  管理:"
    echo -e "    状态  systemctl status ${SERVICE_NAME}"
    echo -e "    日志  journalctl -u ${SERVICE_NAME} -f"
    echo -e "    重启  systemctl restart ${SERVICE_NAME}"
    echo -e "    配置  ${CONFIG_FILE}"
    echo ""
}

#=============================================================================
# 卸载
#=============================================================================
do_uninstall() {
    log_info "卸载 sing-box..."
    systemctl stop    "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -f "$BIN_PATH"
    rm -rf "$CONFIG_DIR"
    log_ok "sing-box 已完全卸载"
    echo ""
}

#=============================================================================
# 入口
#=============================================================================
do_install() {
    validate_params
    echo ""
    echo -e "${C_BOLD}${C_CYAN}=== SOCKS5 一键部署 (sing-box) ===${C_RST}"
    echo -e "  用户名: ${C_YELLOW}${SOCKS5_USER}${C_RST}"
    echo -e "  密码:   ${C_YELLOW}${SOCKS5_PASS}${C_RST}"
    echo -e "  端口:   ${C_YELLOW}${SOCKS5_PORT}${C_RST}"
    echo ""

    ensure_deps
    disable_firewall
    cleanup_conflicts
    install_singbox
    write_config
    write_service
    start_service
    print_result
}

main() {
    parse_args "$@"
    check_system

    case "$ACTION" in
        install)   do_install ;;
        uninstall) do_uninstall ;;
        *) die "未知动作: $ACTION" ;;
    esac
}

main "$@"
