#!/bin/bash
#=============================================================================
# Sing-box SOCKS5 一键部署脚本
# 用法:
#   bash socks5-deploy.sh [选项]
#
# 选项:
#   -u, --user     用户名        (默认: proxy)
#   -p, --pass     密码          (默认: 随机生成)
#   -P, --port     端口          (默认: 随机生成)
#   -l, --listen   监听地址      (默认: 0.0.0.0，填 :: 为IPv6)
#   -v, --version  sing-box版本  (默认: 自动获取最新)
#   -h, --help     显示帮助
#
# 示例:
#   bash socks5-deploy.sh -u admin -p MyPass123 -P 1080
#   bash socks5-deploy.sh --user proxy --pass secret --port 10808 --listen 0.0.0.0
#   curl -fsSL https://raw.githubusercontent.com/xxx/xxx/main/socks5-deploy.sh | bash -s -- -u admin -p pass123 -P 1080
#=============================================================================

set -euo pipefail

#=============================================================================
# 默认值
#=============================================================================
SOCKS5_USER="proxy"
SOCKS5_PASS=""
SOCKS5_PORT=""
LISTEN_ADDR="0.0.0.0"
SINGBOX_VERSION=""

CONFIG_DIR="/etc/sbox_socks5"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_NAME="sbox-socks5"

#=============================================================================
# 颜色
#=============================================================================
red='\033[31m'; green='\033[32m'; yellow='\033[33m'
cyan='\033[96m'; bai='\033[0m'

log_info()    { echo -e "${cyan}[INFO]${bai} $*"; }
log_ok()      { echo -e "${green}[OK]${bai}   $*"; }
log_warn()    { echo -e "${yellow}[WARN]${bai} $*"; }
log_error()   { echo -e "${red}[ERR]${bai}  $*" >&2; }
die()         { log_error "$*"; exit 1; }

#=============================================================================
# 帮助
#=============================================================================
usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

#=============================================================================
# 解析参数
#=============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--user)    SOCKS5_USER="$2";    shift 2 ;;
            -p|--pass)    SOCKS5_PASS="$2";    shift 2 ;;
            -P|--port)    SOCKS5_PORT="$2";    shift 2 ;;
            -l|--listen)  LISTEN_ADDR="$2";    shift 2 ;;
            -v|--version) SINGBOX_VERSION="$2"; shift 2 ;;
            -h|--help)    usage ;;
            *) log_warn "未知参数: $1"; shift ;;
        esac
    done
}

#=============================================================================
# 校验
#=============================================================================
validate_args() {
    # 用户名
    [[ -z "$SOCKS5_USER" ]] && die "用户名不能为空"
    [[ "$SOCKS5_USER" =~ ^[a-zA-Z0-9_-]+$ ]] || die "用户名只能含字母/数字/下划线/连字符"

    # 密码：未指定则随机生成
    if [[ -z "$SOCKS5_PASS" ]]; then
        SOCKS5_PASS=$(tr -dc 'A-Za-z0-9!@#%^&*' < /dev/urandom | head -c 16)
        log_info "随机密码: ${SOCKS5_PASS}"
    fi
    [[ ${#SOCKS5_PASS} -lt 6 ]] && die "密码至少6位"

    # 端口：未指定则随机生成
    if [[ -z "$SOCKS5_PORT" ]]; then
        SOCKS5_PORT=$(( ((RANDOM<<15)|RANDOM) % 55536 + 10000 ))
        log_info "随机端口: ${SOCKS5_PORT}"
    fi
    [[ "$SOCKS5_PORT" =~ ^[0-9]+$ ]] && [ "$SOCKS5_PORT" -ge 1024 ] && [ "$SOCKS5_PORT" -le 65535 ] \
        || die "端口范围: 1024-65535"
    ss -tulpn 2>/dev/null | grep -q ":${SOCKS5_PORT} " && die "端口 ${SOCKS5_PORT} 已被占用"

    # 监听地址
    [[ "$LISTEN_ADDR" == "0.0.0.0" || "$LISTEN_ADDR" == "::" ]] \
        || die "监听地址只支持 0.0.0.0 或 ::"
}

#=============================================================================
# 检查 root
#=============================================================================
check_root() {
    [[ "$(id -u)" -eq 0 ]] || die "需要 root 权限，请使用 sudo 或以 root 执行"
}

#=============================================================================
# 获取系统架构
#=============================================================================
get_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7l)         echo "armv7" ;;
        s390x)          echo "s390x" ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
}

#=============================================================================
# 检测已安装的 sing-box
#=============================================================================
find_singbox() {
    for p in /etc/sing-box/sing-box /usr/local/bin/sing-box /opt/sing-box/sing-box; do
        [[ -x "$p" ]] && echo "$p" && return 0
    done
    command -v sing-box &>/dev/null && which sing-box && return 0
    return 1
}

#=============================================================================
# 安装 sing-box
#=============================================================================
install_singbox() {
    local arch; arch=$(get_arch)

    if [[ -z "$SINGBOX_VERSION" ]]; then
        log_info "获取最新版本..."
        SINGBOX_VERSION=$(curl -fsSL --max-time 10 \
            "https://api.github.com/repos/SagerNet/sing-box/releases/latest" 2>/dev/null \
            | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/' | head -1)
        [[ -z "$SINGBOX_VERSION" ]] && SINGBOX_VERSION="1.11.0"
        log_info "版本: v${SINGBOX_VERSION}"
    fi

    local url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/sing-box-${SINGBOX_VERSION}-linux-${arch}.tar.gz"
    local tmp="/tmp/singbox-$$.tar.gz"

    log_info "下载 sing-box v${SINGBOX_VERSION} (${arch})..."
    curl -fsSL --max-time 60 -o "$tmp" "$url" || wget -q --timeout=60 -O "$tmp" "$url" \
        || die "下载失败: $url"

    mkdir -p /etc/sing-box
    tar -xzf "$tmp" -C /tmp/ 2>/dev/null
    local bin; bin=$(find /tmp -name "sing-box" -type f 2>/dev/null | grep -v ".tar" | head -1)
    [[ -z "$bin" ]] && die "解压后未找到 sing-box 二进制"
    mv "$bin" /etc/sing-box/sing-box
    chmod +x /etc/sing-box/sing-box
    rm -f "$tmp"

    /etc/sing-box/sing-box version >/dev/null 2>&1 || die "sing-box 安装验证失败"
    log_ok "sing-box 安装成功"
}

#=============================================================================
# 部署
#=============================================================================
deploy() {
    local SINGBOX_BIN

    # 检测或安装 sing-box
    log_info "检测 sing-box..."
    if SINGBOX_BIN=$(find_singbox); then
        log_ok "已找到: $SINGBOX_BIN"
    else
        log_info "未找到 sing-box，开始安装..."
        install_singbox
        SINGBOX_BIN="/etc/sing-box/sing-box"
    fi

    # 创建配置目录
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    # 写入配置
    log_info "写入配置..."
    cat > "$CONFIG_FILE" << EOF
{
  "log": {
    "level": "warn",
    "output": "${CONFIG_DIR}/socks5.log"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks5-in",
      "listen": "${LISTEN_ADDR}",
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
    chmod 600 "$CONFIG_FILE"

    # 验证配置
    log_info "验证配置..."
    $SINGBOX_BIN check -c "$CONFIG_FILE" >/dev/null 2>&1 \
        || { $SINGBOX_BIN check -c "$CONFIG_FILE"; die "配置验证失败"; }
    log_ok "配置验证通过"

    # 创建 systemd 服务
    log_info "创建 systemd 服务..."
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=Sing-box SOCKS5 Proxy
After=network.target

[Service]
Type=simple
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SERVICE_NAME"
    sleep 2

    # 验证运行
    systemctl is-active --quiet "$SERVICE_NAME" || {
        log_error "服务启动失败，日志："
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager
        exit 1
    }

    log_ok "服务已启动"
}

#=============================================================================
# 获取公网 IP
#=============================================================================
get_public_ip() {
    local ip
    for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') && [[ -n "$ip" ]] && echo "$ip" && return
    done
    echo "YOUR_SERVER_IP"
}

#=============================================================================
# 输出结果
#=============================================================================
print_result() {
    local ip; ip=$(get_public_ip)
    echo ""
    echo -e "${green}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${bai}"
    echo -e "${green} 🎉 SOCKS5 部署成功！${bai}"
    echo -e "${green}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${bai}"
    printf "  %-8s %s\n" "服务器:" "$ip"
    printf "  %-8s %s\n" "端口:"   "$SOCKS5_PORT"
    printf "  %-8s %s\n" "用户名:" "$SOCKS5_USER"
    printf "  %-8s %s\n" "密码:"   "$SOCKS5_PASS"
    printf "  %-8s %s\n" "协议:"   "SOCKS5"
    echo ""
    echo -e "  ${cyan}URL: socks5://${SOCKS5_USER}:${SOCKS5_PASS}@${ip}:${SOCKS5_PORT}${bai}"
    echo ""
    echo -e "  验证: curl --socks5-hostname ${SOCKS5_USER}:${SOCKS5_PASS}@${ip}:${SOCKS5_PORT} https://ip.sb"
    echo -e "${green}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${bai}"
    echo ""
}

#=============================================================================
# 主流程
#=============================================================================
main() {
    parse_args "$@"
    check_root
    validate_args
    deploy
    print_result
}

main "$@"
