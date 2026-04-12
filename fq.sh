#!/bin/bash
#=============================================================================
# Xray 多协议 + SOCKS5 代理 一体化管理脚本
# 功能：
#   1. 星辰大海 Xray 一键多协议（VLESS-Reality / Shadowsocks-2022）
#   2. Sing-box SOCKS5 一键代理
#=============================================================================

# 颜色
gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_bai='\033[0m'
gl_kjlan='\033[96m'
gl_zi='\033[35m'
gl_hui='\033[90m'

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${gl_hong}错误: 此脚本需要 root 权限！${gl_bai}"
        exit 1
    fi
}

break_end() {
    echo ""
    read -n 1 -s -r -p "按任意键继续..."
    echo ""
}

#=============================================================================
# SOCKS5 相关常量
#=============================================================================
SOCKS5_CONFIG_DIR="/etc/sbox_socks5"
SOCKS5_CONFIG_FILE="${SOCKS5_CONFIG_DIR}/config.json"
SOCKS5_SERVICE_NAME="sbox-socks5"

#=============================================================================
# 通用：获取服务器公网 IP
#=============================================================================
get_server_ip() {
    local mode="${1:-auto}"
    local result=""

    _is_valid_ip() {
        local ip="$1"
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && return 0
        [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$ip" == *:* ]] && return 0
        return 1
    }

    _try_get_ip() {
        result=$(curl "$2" -s --max-time 5 "$1" 2>/dev/null | tr -d '[:space:]')
        [ -n "$result" ] && _is_valid_ip "$result" && echo "$result" && return 0
        return 1
    }

    case "$mode" in
        ipv6)
            _try_get_ip "ifconfig.me" "-6" && return 0
            _try_get_ip "ip.sb" "-6" && return 0
            ;;
        ipv4)
            _try_get_ip "ifconfig.me" "-4" && return 0
            _try_get_ip "ip.sb" "-4" && return 0
            ;;
        *)
            _try_get_ip "ifconfig.me" "-4" && return 0
            _try_get_ip "ip.sb" "-4" && return 0
            _try_get_ip "ifconfig.me" "-6" && return 0
            ;;
    esac

    echo "IP获取失败"
    return 1
}

#=============================================================================
# 通用：检测 sing-box 二进制
#=============================================================================
detect_singbox_cmd() {
    local verbose="${1:-}"
    DETECTED_SINGBOX_CMD=""

    for path in /etc/sing-box/sing-box /usr/local/bin/sing-box /opt/sing-box/sing-box; do
        [ -e "$path" ] || continue
        [ -x "$path" ] || chmod +x "$path" 2>/dev/null
        [ -x "$path" ] || continue
        [ -L "$path" ] && path=$(readlink -f "$path")
        if command -v file >/dev/null 2>&1; then
            file "$path" 2>/dev/null | grep -q "ELF" || continue
        fi
        DETECTED_SINGBOX_CMD="$path"
        break
    done

    if [ -z "$DETECTED_SINGBOX_CMD" ]; then
        for cmd in sing-box sb; do
            command -v "$cmd" &>/dev/null || continue
            local cmd_path; cmd_path=$(which "$cmd")
            [ -L "$cmd_path" ] && cmd_path=$(readlink -f "$cmd_path")
            if command -v file >/dev/null 2>&1; then
                file "$cmd_path" 2>/dev/null | grep -q "ELF" || continue
            fi
            DETECTED_SINGBOX_CMD="$cmd_path"
            break
        done
    fi

    if [ -n "$DETECTED_SINGBOX_CMD" ]; then
        [ "$verbose" = "verbose" ] && echo -e "${gl_lv}✅ 找到 sing-box: $DETECTED_SINGBOX_CMD${gl_bai}"
        return 0
    else
        [ "$verbose" = "verbose" ] && echo -e "${gl_hong}❌ 未找到 sing-box${gl_bai}"
        return 1
    fi
}

#=============================================================================
# SOCKS5：安装 sing-box 二进制（仅二进制，无协议配置）
#=============================================================================
install_singbox_binary() {
    clear
    echo -e "${gl_kjlan}=== 自动安装 Sing-box 核心程序 ===${gl_bai}"
    echo ""
    echo -e "${gl_huang}说明: 仅下载官方二进制，不安装任何协议配置${gl_bai}"
    echo ""
    read -e -p "$(echo -e "${gl_huang}是否继续安装？(Y/N): ${gl_bai}")" confirm
    case "$confirm" in
        [Yy]) ;;
        *)
            echo "已取消"
            return 1
            ;;
    esac

    echo ""
    local arch
    case "$(uname -m)" in
        aarch64|arm64) arch="arm64" ;;
        x86_64|amd64)  arch="amd64" ;;
        armv7l)        arch="armv7" ;;
        *)
            echo -e "${gl_hong}❌ 不支持的架构: $(uname -m)${gl_bai}"
            return 1
            ;;
    esac

    echo -e "${gl_zi}[1/5] 架构: ${arch}${gl_bai}"

    echo -e "${gl_zi}[2/5] 获取最新版本...${gl_bai}"
    local version
    version=$(wget --timeout=10 --tries=2 -qO- "https://api.github.com/repos/SagerNet/sing-box/releases" 2>/dev/null \
        | grep '"tag_name"' \
        | sed -E 's/.*"tag_name":[[:space:]]*"v([^"]+)".*/\1/' \
        | grep -v -E '(alpha|beta|rc)' \
        | sort -Vr | head -1)
    [ -z "$version" ] && version="1.10.0"
    echo -e "${gl_lv}  版本: v${version}${gl_bai}"

    echo -e "${gl_zi}[3/5] 下载 sing-box...${gl_bai}"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz"
    local tmp_dir="/tmp/singbox-install-$$"
    mkdir -p "$tmp_dir"

    if ! wget --timeout=30 --tries=3 -qO "${tmp_dir}/sing-box.tar.gz" "$url" 2>/dev/null; then
        echo -e "${gl_hong}❌ 下载失败${gl_bai}"
        rm -rf "$tmp_dir"
        return 1
    fi

    echo -e "${gl_zi}[4/5] 安装...${gl_bai}"
    if ! tar -xzf "${tmp_dir}/sing-box.tar.gz" -C "$tmp_dir" 2>/dev/null; then
        echo -e "${gl_hong}❌ 解压失败${gl_bai}"
        rm -rf "$tmp_dir"
        return 1
    fi

    mkdir -p /etc/sing-box
    local binary_path; binary_path=$(find "$tmp_dir" -name "sing-box" -type f 2>/dev/null | head -1)
    if [ -z "$binary_path" ]; then
        echo -e "${gl_hong}❌ 未找到二进制文件${gl_bai}"
        rm -rf "$tmp_dir"
        return 1
    fi

    mv "$binary_path" /etc/sing-box/sing-box
    chmod +x /etc/sing-box/sing-box
    rm -rf "$tmp_dir"

    echo -e "${gl_zi}[5/5] 验证...${gl_bai}"
    if /etc/sing-box/sing-box version >/dev/null 2>&1; then
        echo -e "${gl_lv}✅ sing-box $(/etc/sing-box/sing-box version 2>/dev/null | head -1) 安装成功${gl_bai}"
        return 0
    else
        echo -e "${gl_hong}❌ 验证失败${gl_bai}"
        return 1
    fi
}

#=============================================================================
# SOCKS5：部署
#=============================================================================
deploy_socks5() {
    clear
    echo -e "${gl_kjlan}=== Sing-box SOCKS5 一键部署 ===${gl_bai}"
    echo ""

    # 检测 sing-box
    echo -e "${gl_zi}[步骤1/7] 检测 sing-box 安装...${gl_bai}"
    echo ""
    local SINGBOX_CMD=""
    if detect_singbox_cmd "verbose"; then
        SINGBOX_CMD="$DETECTED_SINGBOX_CMD"
    else
        if install_singbox_binary; then
            echo ""
            echo -e "${gl_zi}重新检测 sing-box...${gl_bai}"
            if detect_singbox_cmd "verbose"; then
                SINGBOX_CMD="$DETECTED_SINGBOX_CMD"
            else
                echo -e "${gl_hong}❌ 安装后仍找不到 sing-box${gl_bai}"
                break_end
                return 1
            fi
        else
            return 1
        fi
    fi

    echo ""
    $SINGBOX_CMD version 2>/dev/null | head -n 1
    echo ""

    # 监听模式
    echo -e "${gl_zi}[步骤2/7] 配置参数...${gl_bai}"
    echo ""
    echo -e "${gl_huang}请选择监听模式：${gl_bai}"
    echo "  1. IPv4 only (0.0.0.0)  — 默认"
    echo "  2. IPv6 only (::)       — 纯 IPv6 服务器"
    echo ""
    read -e -p "$(echo -e "${gl_huang}请输入选项 [1/2，回车默认1]: ${gl_bai}")" listen_choice
    local listen_addr
    case "$listen_choice" in
        2) listen_addr="::" ; echo -e "${gl_lv}✅ 监听模式: IPv6 only${gl_bai}" ;;
        *) listen_addr="0.0.0.0" ; echo -e "${gl_lv}✅ 监听模式: IPv4 only${gl_bai}" ;;
    esac
    echo ""

    # 端口
    local socks5_port=""
    while true; do
        read -e -p "$(echo -e "${gl_huang}请输入端口 [回车随机生成]: ${gl_bai}")" socks5_port
        if [ -z "$socks5_port" ]; then
            socks5_port=$(( ((RANDOM<<15) | RANDOM) % 55536 + 10000 ))
            echo -e "${gl_lv}✅ 随机端口: ${socks5_port}${gl_bai}"
            break
        elif [[ "$socks5_port" =~ ^[0-9]+$ ]] && [ "$socks5_port" -ge 1024 ] && [ "$socks5_port" -le 65535 ]; then
            if ss -tulpn | grep -q ":${socks5_port} "; then
                echo -e "${gl_hong}❌ 端口 ${socks5_port} 已被占用${gl_bai}"
            else
                echo -e "${gl_lv}✅ 端口: ${socks5_port}${gl_bai}"
                break
            fi
        else
            echo -e "${gl_hong}❌ 无效端口${gl_bai}"
        fi
    done
    echo ""

    # 用户名
    local socks5_user=""
    while true; do
        read -e -p "$(echo -e "${gl_huang}请输入用户名: ${gl_bai}")" socks5_user
        if [ -z "$socks5_user" ]; then
            echo -e "${gl_hong}❌ 用户名不能为空${gl_bai}"
        elif [[ "$socks5_user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            echo -e "${gl_lv}✅ 用户名: ${socks5_user}${gl_bai}"
            break
        else
            echo -e "${gl_hong}❌ 用户名只能包含字母、数字、下划线和连字符${gl_bai}"
        fi
    done
    echo ""

    # 密码
    local socks5_pass=""
    while true; do
        read -e -p "$(echo -e "${gl_huang}请输入密码: ${gl_bai}")" socks5_pass
        if [ -z "$socks5_pass" ]; then
            echo -e "${gl_hong}❌ 密码不能为空${gl_bai}"
        elif [ ${#socks5_pass} -lt 6 ]; then
            echo -e "${gl_hong}❌ 密码长度至少6位${gl_bai}"
        elif [[ "$socks5_pass" == *\"* || "$socks5_pass" == *\\* ]]; then
            echo -e "${gl_hong}❌ 密码不能包含 \" 或 \\ 字符${gl_bai}"
        else
            echo -e "${gl_lv}✅ 密码已设置${gl_bai}"
            break
        fi
    done

    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}配置确认：${gl_bai}"
    echo -e "  监听地址: ${gl_huang}${listen_addr}${gl_bai}"
    echo -e "  端口:     ${gl_huang}${socks5_port}${gl_bai}"
    echo -e "  用户名:   ${gl_huang}${socks5_user}${gl_bai}"
    echo -e "  密码:     ${gl_huang}${socks5_pass}${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    read -e -p "$(echo -e "${gl_huang}确认开始部署？(Y/N): ${gl_bai}")" confirm
    case "$confirm" in
        [Yy]) ;;
        *) echo "已取消"; break_end; return 1 ;;
    esac

    # 创建目录
    echo ""
    echo -e "${gl_zi}[步骤3/7] 创建配置目录...${gl_bai}"
    mkdir -p "$SOCKS5_CONFIG_DIR"
    echo -e "${gl_lv}✅ 目录创建成功${gl_bai}"

    # 写配置文件
    echo ""
    echo -e "${gl_zi}[步骤4/7] 创建配置文件...${gl_bai}"
    cat > "$SOCKS5_CONFIG_FILE" << CONFIGEOF
{
  "log": {
    "level": "info",
    "output": "${SOCKS5_CONFIG_DIR}/socks5.log"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks5-in",
      "listen": "${listen_addr}",
      "listen_port": ${socks5_port},
      "users": [
        {
          "username": "${socks5_user}",
          "password": "${socks5_pass}"
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
CONFIGEOF
    chmod 600 "$SOCKS5_CONFIG_FILE"
    echo -e "${gl_lv}✅ 配置文件创建成功${gl_bai}"

    # 验证配置
    echo ""
    echo -e "${gl_zi}[步骤5/7] 验证配置文件...${gl_bai}"
    if ! $SINGBOX_CMD check -c "$SOCKS5_CONFIG_FILE" >/dev/null 2>&1; then
        echo -e "${gl_hong}❌ 配置文件语法错误${gl_bai}"
        $SINGBOX_CMD check -c "$SOCKS5_CONFIG_FILE"
        break_end
        return 1
    fi
    echo -e "${gl_lv}✅ 语法正确${gl_bai}"

    # 创建 systemd 服务
    echo ""
    echo -e "${gl_zi}[步骤6/7] 创建 systemd 服务...${gl_bai}"
    cat > /etc/systemd/system/${SOCKS5_SERVICE_NAME}.service << SERVICEEOF
[Unit]
Description=Sing-box SOCKS5 Service
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SINGBOX_CMD} run -c ${SOCKS5_CONFIG_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SOCKS5_SERVICE_NAME}
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SERVICEEOF
    chmod 644 /etc/systemd/system/${SOCKS5_SERVICE_NAME}.service
    echo -e "${gl_lv}✅ 服务文件创建成功${gl_bai}"

    # 启动服务
    echo ""
    echo -e "${gl_zi}[步骤7/7] 启动服务...${gl_bai}"
    systemctl daemon-reload
    systemctl enable "$SOCKS5_SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SOCKS5_SERVICE_NAME" >/dev/null 2>&1
    sleep 3

    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}验证部署结果：${gl_bai}"
    echo ""

    if systemctl is-active --quiet "$SOCKS5_SERVICE_NAME"; then
        echo -e "  服务状态: ${gl_lv}✅ Running${gl_bai}"
    else
        echo -e "  服务状态: ${gl_hong}❌ Failed${gl_bai}"
    fi

    if ss -tulpn | grep -q ":${socks5_port} "; then
        echo -e "  端口监听: ${gl_lv}✅ ${socks5_port}${gl_bai}"
    else
        echo -e "  端口监听: ${gl_hong}❌ 未监听${gl_bai}"
    fi

    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    if systemctl is-active --quiet "$SOCKS5_SERVICE_NAME"; then
        local server_ip
        if [ "$listen_addr" = "::" ]; then
            server_ip=$(get_server_ip "ipv6")
        else
            server_ip=$(get_server_ip "auto")
        fi

        echo -e "${gl_lv}🎉 部署成功！${gl_bai}"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_lv}SOCKS5 连接信息：${gl_bai}"
        echo ""
        echo -e "  服务器地址: ${gl_huang}${server_ip}${gl_bai}"
        echo -e "  端口:       ${gl_huang}${socks5_port}${gl_bai}"
        echo -e "  用户名:     ${gl_huang}${socks5_user}${gl_bai}"
        echo -e "  密码:       ${gl_huang}${socks5_pass}${gl_bai}"
        echo -e "  协议:       ${gl_huang}SOCKS5${gl_bai}"
        echo ""
        echo -e "  快捷 URL:   ${gl_huang}socks5://${socks5_user}:${socks5_pass}@${server_ip}:${socks5_port}${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "${gl_zi}测试命令：${gl_bai}"
        echo "curl --socks5-hostname ${socks5_user}:${socks5_pass}@${server_ip}:${socks5_port} http://httpbin.org/ip"
    else
        echo -e "${gl_hong}❌ 部署失败，查看日志：${gl_bai}"
        echo "  journalctl -u ${SOCKS5_SERVICE_NAME} -n 50 --no-pager"
    fi

    break_end
}

#=============================================================================
# SOCKS5：查看信息
#=============================================================================
view_socks5() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}      查看 SOCKS5 代理信息${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    if [ ! -f "$SOCKS5_CONFIG_FILE" ]; then
        echo -e "${gl_huang}⚠️ 未检测到 SOCKS5 代理配置${gl_bai}"
        break_end
        return 1
    fi

    local port username password listen_addr server_ip
    port=$(grep -o '"listen_port"[[:space:]]*:[[:space:]]*[0-9]*' "$SOCKS5_CONFIG_FILE" | grep -o '[0-9]*$')
    username=$(grep -o '"username"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" | sed 's/.*"username"[[:space:]]*:[[:space:]]*"//;s/"$//')
    password=$(grep -o '"password"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" | sed 's/.*"password"[[:space:]]*:[[:space:]]*"//;s/"$//')
    listen_addr=$(grep -o '"listen"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" | sed 's/.*"listen"[[:space:]]*:[[:space:]]*"//;s/"$//')

    if [ -z "$port" ] || [ -z "$username" ]; then
        echo -e "${gl_hong}❌ 配置文件格式错误${gl_bai}"
        break_end
        return 1
    fi

    if [ "$listen_addr" = "::" ]; then
        server_ip=$(get_server_ip "ipv6")
    else
        server_ip=$(get_server_ip "auto")
    fi

    local service_status port_status
    systemctl is-active --quiet "$SOCKS5_SERVICE_NAME" && \
        service_status="${gl_lv}✅ 运行中${gl_bai}" || service_status="${gl_hong}❌ 未运行${gl_bai}"
    ss -tulpn | grep -q ":${port} " && \
        port_status="${gl_lv}✅ 监听中${gl_bai}" || port_status="${gl_hong}❌ 未监听${gl_bai}"

    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "  服务器地址: ${gl_huang}${server_ip}${gl_bai}"
    echo -e "  端口:       ${gl_huang}${port}${gl_bai}"
    echo -e "  用户名:     ${gl_huang}${username}${gl_bai}"
    echo -e "  密码:       ${gl_huang}${password}${gl_bai}"
    echo -e "  服务状态:   $service_status"
    echo -e "  端口状态:   $port_status"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    echo -e "${gl_lv}快捷 URL：${gl_bai}"
    echo "socks5://${username}:${password}@${server_ip}:${port}"
    echo ""
    echo -e "${gl_zi}管理命令：${gl_bai}"
    echo "  日志: journalctl -u ${SOCKS5_SERVICE_NAME} -f"
    echo "  重启: systemctl restart ${SOCKS5_SERVICE_NAME}"
    echo "  停止: systemctl stop ${SOCKS5_SERVICE_NAME}"

    break_end
}

#=============================================================================
# SOCKS5：修改配置
#=============================================================================
modify_socks5() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}      修改 SOCKS5 代理配置${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    if [ ! -f "$SOCKS5_CONFIG_FILE" ]; then
        echo -e "${gl_huang}⚠️ 未检测到 SOCKS5 代理配置${gl_bai}"
        break_end
        return 1
    fi

    local cur_port cur_user cur_pass cur_listen
    cur_port=$(grep -o '"listen_port"[[:space:]]*:[[:space:]]*[0-9]*' "$SOCKS5_CONFIG_FILE" | grep -o '[0-9]*$')
    cur_user=$(grep -o '"username"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" | sed 's/.*"username"[[:space:]]*:[[:space:]]*"//;s/"$//')
    cur_pass=$(grep -o '"password"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" | sed 's/.*"password"[[:space:]]*:[[:space:]]*"//;s/"$//')
    cur_listen=$(grep -o '"listen"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" | sed 's/.*"listen"[[:space:]]*:[[:space:]]*"//;s/"$//')

    echo -e "${gl_zi}当前配置：${gl_bai}"
    echo "  端口: ${cur_port}  用户名: ${cur_user}  密码: ${cur_pass}"
    echo ""
    echo -e "${gl_huang}请输入新值（回车保持不变）：${gl_bai}"
    echo ""

    local new_port new_user new_pass
    while true; do
        read -e -p "$(echo -e "新端口 [${cur_port}]: ")" new_port
        new_port="${new_port:-$cur_port}"
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
            if [ "$new_port" != "$cur_port" ] && ss -tulpn | grep -q ":${new_port} "; then
                echo -e "${gl_hong}❌ 端口 ${new_port} 已被占用${gl_bai}"
            else
                break
            fi
        else
            echo -e "${gl_hong}❌ 无效端口${gl_bai}"
        fi
    done

    while true; do
        read -e -p "$(echo -e "新用户名 [${cur_user}]: ")" new_user
        new_user="${new_user:-$cur_user}"
        [[ "$new_user" =~ ^[a-zA-Z0-9_-]+$ ]] && break || echo -e "${gl_hong}❌ 用户名格式无效${gl_bai}"
    done

    while true; do
        read -e -p "$(echo -e "新密码 [回车保持不变]: ")" new_pass
        if [ -z "$new_pass" ]; then
            new_pass="$cur_pass"
            break
        elif [ ${#new_pass} -lt 6 ]; then
            echo -e "${gl_hong}❌ 密码长度至少6位${gl_bai}"
        elif [[ "$new_pass" == *\"* || "$new_pass" == *\\* ]]; then
            echo -e "${gl_hong}❌ 密码不能包含 \" 或 \\ 字符${gl_bai}"
        else
            break
        fi
    done

    if ! detect_singbox_cmd; then
        echo -e "${gl_hong}❌ 未找到 sing-box${gl_bai}"
        break_end
        return 1
    fi

    cat > "$SOCKS5_CONFIG_FILE" << CONFIGEOF
{
  "log": {
    "level": "info",
    "output": "${SOCKS5_CONFIG_DIR}/socks5.log"
  },
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks5-in",
      "listen": "${cur_listen}",
      "listen_port": ${new_port},
      "users": [
        {
          "username": "${new_user}",
          "password": "${new_pass}"
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
CONFIGEOF
    chmod 600 "$SOCKS5_CONFIG_FILE"

    # 更新服务文件中的 ExecStart（sing-box 路径不变，直接重启即可）
    systemctl restart "$SOCKS5_SERVICE_NAME"
    sleep 2

    if systemctl is-active --quiet "$SOCKS5_SERVICE_NAME"; then
        echo ""
        echo -e "${gl_lv}✅ 配置修改成功，服务已重启${gl_bai}"
    else
        echo -e "${gl_hong}❌ 服务重启失败${gl_bai}"
        echo "journalctl -u ${SOCKS5_SERVICE_NAME} -n 20"
    fi

    break_end
}

#=============================================================================
# SOCKS5：删除
#=============================================================================
delete_socks5() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}      删除 SOCKS5 代理${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""

    local has_config=false has_service=false
    { [ -f "$SOCKS5_CONFIG_FILE" ] || [ -d "$SOCKS5_CONFIG_DIR" ]; } && has_config=true
    [ -f "/etc/systemd/system/${SOCKS5_SERVICE_NAME}.service" ] && has_service=true

    if [ "$has_config" = false ] && [ "$has_service" = false ]; then
        echo -e "${gl_huang}⚠️ 未检测到 SOCKS5 代理配置${gl_bai}"
        break_end
        return 0
    fi

    echo -e "${gl_hong}⚠️ 此操作不可恢复！${gl_bai}"
    echo ""
    read -e -p "$(echo -e "${gl_huang}确认删除？请输入 'yes' 确认: ${gl_bai}")" confirm
    [ "$confirm" != "yes" ] && { echo "已取消"; break_end; return 0; }

    $has_service && {
        systemctl stop "$SOCKS5_SERVICE_NAME" 2>/dev/null
        systemctl disable "$SOCKS5_SERVICE_NAME" 2>/dev/null
        rm -f "/etc/systemd/system/${SOCKS5_SERVICE_NAME}.service"
        systemctl daemon-reload
        echo -e "${gl_lv}✅ 服务已删除${gl_bai}"
    }

    $has_config && {
        rm -rf "$SOCKS5_CONFIG_DIR"
        echo -e "${gl_lv}✅ 配置目录已删除${gl_bai}"
    }

    echo ""
    echo -e "${gl_lv}🎉 SOCKS5 代理已完全删除${gl_bai}"
    break_end
}

#=============================================================================
# SOCKS5 管理菜单
#=============================================================================
menu_socks5() {
    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}      Sing-box SOCKS5 管理${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""

        if [ -f "$SOCKS5_CONFIG_FILE" ]; then
            local port user
            port=$(grep -o '"listen_port"[[:space:]]*:[[:space:]]*[0-9]*' "$SOCKS5_CONFIG_FILE" | grep -o '[0-9]*$')
            user=$(grep -o '"username"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" | sed 's/.*"username"[[:space:]]*:[[:space:]]*"//;s/"$//')
            if systemctl is-active --quiet "$SOCKS5_SERVICE_NAME"; then
                echo -e "  当前状态: ${gl_lv}✅ 运行中${gl_bai}  端口: ${gl_huang}${port}${gl_bai}  用户名: ${gl_huang}${user}${gl_bai}"
            else
                echo -e "  当前状态: ${gl_hong}❌ 未运行${gl_bai}"
            fi
        else
            echo -e "  当前状态: ${gl_zi}未部署${gl_bai}"
        fi

        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo "  1. 新增 SOCKS5 代理"
        echo "  2. 修改 SOCKS5 配置"
        echo "  3. 删除 SOCKS5 代理"
        echo "  4. 查看 SOCKS5 信息"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo "  0. 返回主菜单"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        read -e -p "请输入选项 [0-4]: " choice

        case "$choice" in
            1)
                if [ -f "$SOCKS5_CONFIG_FILE" ]; then
                    echo ""
                    echo -e "${gl_huang}⚠️  检测到已存在 SOCKS5 配置${gl_bai}"
                    read -e -p "$(echo -e "${gl_huang}是否覆盖现有配置？(Y/N): ${gl_bai}")" ow
                    [[ "$ow" =~ ^[Yy]$ ]] || { sleep 1; continue; }
                fi
                deploy_socks5
                ;;
            2) modify_socks5 ;;
            3) delete_socks5 ;;
            4) view_socks5 ;;
            0) return ;;
            *) echo -e "${gl_hong}❌ 无效选项${gl_bai}"; sleep 1 ;;
        esac
    done
}

#=============================================================================
# Xray 多协议管理（内嵌完整脚本）
#=============================================================================
run_xray_menu() {
    clear
    echo -e "${gl_kjlan}=== 星辰大海 Xray 一键多协议（增强版） ===${gl_bai}"
    echo ""
    echo -e "${gl_lv}✨ 功能：${gl_bai}"
    echo "  • VLESS-Reality / Shadowsocks-2022 多节点"
    echo "  • SOCKS5 链式代理 / 路由过滤"
    echo "  • 随机 shortId / SNI 域名快速选择"
    echo ""

    local script_path="/tmp/xray_enhanced_$$.sh"

    cat > "$script_path" << 'XRAY_SCRIPT_EOF'
#!/bin/bash
set -euo pipefail

readonly XRAY_SCRIPT_VERSION="Final v2.9.1"
readonly xray_config_path="/usr/local/etc/xray/config.json"
readonly xray_binary_path="/usr/local/bin/xray"
readonly xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

xray_status_info=""
is_quiet=false

error()   { echo -e "\n$red[✖] $1$none\n" >&2; }
info()    { [[ "$is_quiet" = false ]] && echo -e "\n$yellow[!] $1$none\n"; }
success() { [[ "$is_quiet" = false ]] && echo -e "\n$green[✔] $1$none\n"; }

spinner() {
    local pid="$1" spinstr='|/-\\'
    if [[ "$is_quiet" = true ]]; then wait "$pid"; return; fi
    while ps -p "$pid" > /dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        spinstr=$temp${spinstr%"$temp"}
        sleep 0.1; printf "\r"
    done; printf "    \r"
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
}

pre_check() {
    [[ "$(id -u)" != 0 ]] && error "需要 root 权限" && exit 1
    [ ! -f /etc/debian_version ] && error "仅支持 Debian/Ubuntu" && exit 1
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        info "安装依赖 (jq/curl)..."
        (DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl) &>/dev/null &
        spinner $!
        wait $! || true
        if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
            error "依赖安装失败，请手动运行 'apt update && apt install -y jq curl'"
            exit 1
        fi
    fi
}

check_xray_status() {
    if [[ ! -f "$xray_binary_path" || ! -x "$xray_binary_path" ]]; then
        xray_status_info=" Xray 状态: ${red}未安装${none}"; return
    fi
    local v; v=$("$xray_binary_path" version 2>/dev/null | head -n 1 | awk '{print $2}' || echo "未知")
    local s; systemctl is-active --quiet xray 2>/dev/null && s="${green}运行中${none}" || s="${yellow}未运行${none}"
    xray_status_info=" Xray 状态: ${green}已安装${none} | ${s} | 版本: ${cyan}${v}${none}"
}

quick_status() {
    [[ ! -f "$xray_binary_path" ]] && { echo -e " ${red}●${none} 未安装"; return; }
    local si; systemctl is-active --quiet xray 2>/dev/null && si="${green}●${none}" || si="${red}●${none}"
    echo -e " $si Xray $(systemctl is-active xray 2>/dev/null || echo "inactive")"
}

generate_ss_key()   { openssl rand -base64 16; }
generate_shortid()  { openssl rand -hex 4; }

build_vless_inbound() {
    local port="$1" uuid="$2" domain="$3" priv="$4" pub="$5" tag="$6"
    local sid="${7:-$(generate_shortid)}"
    jq -n --argjson port "$port" --arg uuid "$uuid" --arg domain "$domain" \
       --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" --arg tag "$tag" \
    '{"listen":"0.0.0.0","port":$port,"protocol":"vless","settings":{"clients":[{"id":$uuid,"flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":($domain+":443"),"xver":0,"serverNames":[$domain],"privateKey":$priv,"publicKey":$pub,"shortIds":[$sid]}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"]},"tag":$tag}'
}

build_ss_inbound() {
    local port="$1" pass="$2" tag="$3"
    jq -n --argjson port "$port" --arg pass "$pass" --arg tag "$tag" \
    '{"listen":"0.0.0.0","port":$port,"protocol":"shadowsocks","settings":{"method":"2022-blake3-aes-128-gcm","password":$pass},"tag":$tag}'
}

write_config() {
    local inbounds_json="$1" enable_routing="${2:-}"
    [[ -z "$enable_routing" ]] && {
        if [[ -f "$xray_config_path" ]]; then
            [[ -n "$(jq -r '.routing // empty' "$xray_config_path" 2>/dev/null)" ]] && enable_routing="true" || enable_routing="false"
        else
            enable_routing="false"
        fi
    }

    local existing_custom_outbounds="[]" existing_custom_routing_rules="[]"
    if [[ -f "$xray_config_path" ]] && jq empty "$xray_config_path" 2>/dev/null; then
        if jq -e '.inbounds[]? | select(.protocol == "vless" or .protocol == "shadowsocks")' "$xray_config_path" &>/dev/null; then
            local t
            t=$(jq -c '[.outbounds[]? | select(.protocol != "freedom" and .protocol != "blackhole")]' "$xray_config_path" 2>/dev/null)
            [[ -n "$t" ]] && echo "$t" | jq empty 2>/dev/null && existing_custom_outbounds="$t"
            t=$(jq -c '[.routing.rules[]? | select(.inboundTag != null or (.outboundTag? | startswith("socks5-")))]' "$xray_config_path" 2>/dev/null)
            [[ -n "$t" ]] && echo "$t" | jq empty 2>/dev/null && existing_custom_routing_rules="$t"
        fi
    fi

    inbounds_json=$(echo "$inbounds_json" | jq -c '.')
    existing_custom_outbounds=$(echo "$existing_custom_outbounds" | jq -c '.')
    existing_custom_routing_rules=$(echo "$existing_custom_routing_rules" | jq -c '.')

    local base_outbounds
    [[ "$enable_routing" == "true" ]] && \
        base_outbounds='[{"protocol":"freedom","tag":"direct","settings":{"domainStrategy":"UseIPv4v6"}},{"protocol":"blackhole","tag":"block"}]' || \
        base_outbounds='[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}]'

    local full_outbounds; full_outbounds=$(echo "$base_outbounds" | jq -c --argjson c "$existing_custom_outbounds" '. + $c')
    local full_rules
    if [[ "$enable_routing" == "true" ]]; then
        local def_block='[{"type":"field","domain":["geosite:category-ads-all","geosite:category-porn","regexp:.*missav.*","geosite:missav"],"outboundTag":"block"}]'
        full_rules=$(echo "$existing_custom_routing_rules" | jq -c --argjson d "$def_block" '. + $d')
    else
        full_rules="$existing_custom_routing_rules"
    fi

    local config_content
    if [[ "$enable_routing" == "true" ]]; then
        config_content=$(jq -n --argjson i "$inbounds_json" --argjson o "$full_outbounds" --argjson r "$full_rules" \
            '{"log":{"loglevel":"warning"},"inbounds":$i,"outbounds":$o,"routing":{"domainStrategy":"IPOnDemand","rules":$r}}')
    else
        local rl; rl=$(echo "$full_rules" | jq 'length')
        if [[ "$rl" -gt 0 ]]; then
            config_content=$(jq -n --argjson i "$inbounds_json" --argjson o "$full_outbounds" --argjson r "$full_rules" \
                '{"log":{"loglevel":"warning"},"inbounds":$i,"outbounds":$o,"routing":{"domainStrategy":"IPOnDemand","rules":$r}}')
        else
            config_content=$(jq -n --argjson i "$inbounds_json" --argjson o "$full_outbounds" \
                '{"log":{"loglevel":"warning"},"inbounds":$i,"outbounds":$o}')
        fi
    fi

    echo "$config_content" | jq . >/dev/null 2>&1 || { error "配置文件格式错误！"; return 1; }
    echo "$config_content" > "$xray_config_path"
    chmod 640 "$xray_config_path"
    chown nobody:root "$xray_config_path"
}

execute_official_script() {
    local args="$1" script_content tmp_script="/tmp/xray_install_$$.sh"
    script_content=$(curl -fsSL --max-time 30 "$xray_install_script_url" 2>/dev/null) || { error "下载官方安装脚本失败！"; return 1; }
    [[ -z "$script_content" || ! "$script_content" =~ "install-release" ]] && { error "官方脚本内容异常！"; return 1; }
    echo "$script_content" > "$tmp_script"; chmod +x "$tmp_script"
    if [[ "$is_quiet" = false ]]; then
        bash "$tmp_script" $args &; spinner $!; wait $! || { rm -f "$tmp_script"; return 1; }
    else
        bash "$tmp_script" $args &>/dev/null || { rm -f "$tmp_script"; return 1; }
    fi
    rm -f "$tmp_script"
}

run_core_install() {
    info "下载安装 Xray 核心..."
    execute_official_script "install" || { error "安装失败！"; return 1; }
    info "更新 GeoIP/GeoSite..."
    execute_official_script "install-geodata" || info "Geo-data 更新失败，可稍后手动更新"
    success "Xray 核心准备就绪"
}

is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

is_port_available() {
    local port="$1"
    is_valid_port "$port" || return 1
    ss -tlpn 2>/dev/null | grep -q ":$port " && { error "端口 $port 已被系统占用"; return 1; }
    if [[ -f "$xray_config_path" ]]; then
        jq -r '.inbounds[]?.port // empty' "$xray_config_path" 2>/dev/null | grep -q "^${port}$" && { error "端口 $port 已在 Xray 配置中使用"; return 1; }
    fi
    return 0
}

generate_random_port() {
    local attempt=0
    while [ $attempt -lt 100 ]; do
        local p=$((RANDOM % 55536 + 10000))
        is_port_available "$p" 2>/dev/null && echo "$p" && return 0
        ((attempt++))
    done
    error "无法生成可用端口"; return 1
}

is_valid_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]] && [[ "$1" != *--* ]]
}

show_port_usage() {
    echo ""
    info "当前系统端口使用情况:"
    printf "%-15s %-9s\n" "程序名" "端口"
    echo "────────────────────────────────────────────────────────"
    declare -A program_ports
    while read line; do
        [[ "$line" =~ LISTEN|UNCONN ]] || continue
        local addr=$(echo "$line" | awk '{print $5}')
        local port=$(echo "$addr" | grep -o ':[0-9]*$' | cut -d':' -f2)
        local prog=$(echo "$line" | awk '{print $7}' | cut -d'"' -f2 2>/dev/null || echo "")
        [ -n "$port" ] && [ -n "$prog" ] && [ "$prog" != "-" ] && {
            [ -z "${program_ports[$prog]:-}" ] && program_ports[$prog]="$port" || \
                [[ ! "${program_ports[$prog]}" =~ (^|.*\|)$port(\||$) ]] && program_ports[$prog]="${program_ports[$prog]}|$port"
        }
    done < <(ss -tulnp 2>/dev/null || true)
    for prog in $(printf '%s\n' "${!program_ports[@]}" | sort); do
        printf "%-10s | %-9s\n" "$prog" "${program_ports[$prog]}"
    done
    echo "────────────────────────────────────────────────────────"
    echo ""
}

prompt_for_vless_config() {
    local -n p_port="$1" p_uuid="$2" p_sni="$3" p_node_name="$4"
    show_port_usage
    while true; do
        read -p " -> 请输入 VLESS 端口 (留空随机生成): " p_port || true
        if [[ -z "$p_port" ]]; then
            p_port=$(generate_random_port) && { info "随机端口: ${cyan}${p_port}${none}"; break; }
        else
            is_port_available "$p_port" && break
        fi
    done
    read -p " -> 请输入UUID (留空自动生成): " p_uuid || true
    [[ -z "$p_uuid" ]] && { p_uuid=$(cat /proc/sys/kernel/random/uuid); info "随机UUID: ${cyan}${p_uuid:0:8}...${none}"; }

    echo ""; echo -e "${cyan}请选择 SNI 域名:${none}"
    echo "  1. addons.mozilla.org"; echo "  2. updates.cdn-apple.com"; echo "  3. 自定义"
    read -p "请输入选择 [1]: " sni_choice || true; sni_choice=${sni_choice:-1}
    case "$sni_choice" in
        1) p_sni="addons.mozilla.org" ;;
        2) p_sni="updates.cdn-apple.com" ;;
        3) while true; do
               read -p " -> 请输入自定义SNI域名: " p_sni || true
               is_valid_domain "$p_sni" && break || error "域名格式无效"
           done ;;
        *) p_sni="addons.mozilla.org" ;;
    esac
    info "SNI: ${cyan}${p_sni}${none}"
    read -p " -> 请输入节点名称 (留空用端口号): " p_node_name || true
    [[ -z "$p_node_name" ]] && p_node_name="VLESS-Reality-${p_port}"
}

prompt_for_ss_config() {
    local -n p_port="$1" p_pass="$2" p_node_name="$3"
    show_port_usage
    while true; do
        read -p " -> 请输入 Shadowsocks 端口 (留空随机生成): " p_port || true
        if [[ -z "$p_port" ]]; then
            p_port=$(generate_random_port) && { info "随机端口: ${cyan}${p_port}${none}"; break; }
        else
            is_port_available "$p_port" && break
        fi
    done
    read -p " -> 请输入密钥 (留空自动生成): " p_pass || true
    [[ -z "$p_pass" ]] && { p_pass=$(generate_ss_key); info "随机密钥: ${cyan}${p_pass:0:4}...${none}"; }
    read -p " -> 请输入节点名称 (留空用端口号): " p_node_name || true
    [[ -z "$p_node_name" ]] && p_node_name="Shadowsocks-2022-${p_port}"
}

draw_divider() { printf "%0.s─" {1..48}; printf "\n"; }

draw_menu_header() {
    clear
    echo -e "${cyan} Xray VLESS-Reality & Shadowsocks-2022 管理脚本${none}"
    echo -e "${yellow} Version: ${XRAY_SCRIPT_VERSION}${none}"
    draw_divider; check_xray_status; echo -e "${xray_status_info}"; quick_status; draw_divider
}

press_any_key_to_continue() { echo ""; read -n 1 -s -r -p " 按任意键返回主菜单..." || true; }

restart_xray() {
    [[ ! -f "$xray_binary_path" ]] && { error "Xray 未安装"; return 1; }
    info "重启 Xray..."
    systemctl restart xray || { error "重启失败！"; systemctl status xray --no-pager -l | tail -5; return 1; }
    sleep 2
    systemctl is-active --quiet xray && success "Xray 已重启！" || { error "启动失败"; systemctl status xray --no-pager -l | tail -5; return 1; }
}

run_install_vless() {
    local port="$1" uuid="$2" domain="$3" tag="$4"
    [[ -z "$(get_public_ip)" ]] && { error "无法获取公网 IP"; exit 1; }
    run_core_install || exit 1
    info "生成 Reality 密钥对..."
    local kp priv pub
    kp=$("$xray_binary_path" x25519)
    priv=$(echo "$kp" | awk '/PrivateKey:/ {print $2}')
    pub=$(echo "$kp" | awk '/PublicKey/ {print $NF}')
    [[ -z "$priv" || -z "$pub" ]] && { error "生成密钥失败！"; exit 1; }
    local inbound; inbound=$(build_vless_inbound "$port" "$uuid" "$domain" "$priv" "$pub" "$tag")
    write_config "[$inbound]"
    restart_xray || exit 1
    success "VLESS-Reality 安装成功！"
    view_all_info
}

run_install_ss() {
    local port="$1" pass="$2" tag="$3"
    [[ -z "$(get_public_ip)" ]] && { error "无法获取公网 IP"; exit 1; }
    run_core_install || exit 1
    local inbound; inbound=$(build_ss_inbound "$port" "$pass" "$tag")
    write_config "[$inbound]"
    restart_xray || exit 1
    success "Shadowsocks-2022 安装成功！"
    view_all_info
}

run_install_dual() {
    local vp="$1" vu="$2" vd="$3" vt="$4" sp="$5" spass="$6" st="$7"
    [[ -z "$(get_public_ip)" ]] && { error "无法获取公网 IP"; exit 1; }
    run_core_install || exit 1
    info "生成 Reality 密钥对..."
    local kp priv pub
    kp=$("$xray_binary_path" x25519)
    priv=$(echo "$kp" | awk '/PrivateKey:/ {print $2}')
    pub=$(echo "$kp" | awk '/PublicKey/ {print $NF}')
    [[ -z "$priv" || -z "$pub" ]] && { error "生成密钥失败！"; exit 1; }
    local vi si
    vi=$(build_vless_inbound "$vp" "$vu" "$vd" "$priv" "$pub" "$vt")
    si=$(build_ss_inbound "$sp" "$spass" "$st")
    write_config "[$vi, $si]"
    restart_xray || exit 1
    success "双协议安装成功！"
    view_all_info
}

view_all_info() {
    [ ! -f "$xray_config_path" ] && { [[ "$is_quiet" = true ]] && return; error "配置文件不存在"; return; }
    [[ "$is_quiet" = false ]] && { clear; echo -e "${cyan} Xray 配置及订阅信息${none}"; draw_divider; }

    local ip; ip=$(get_public_ip)
    [[ -z "$ip" ]] && { [[ "$is_quiet" = false ]] && error "无法获取公网 IP"; return 1; }
    local links_array=()
    local display_ip; display_ip=$ip && [[ $ip =~ ":" ]] && display_ip="[$ip]"

    local vc; vc=$(jq '[.inbounds[] | select(.protocol == "vless")] | length' "$xray_config_path" 2>/dev/null || echo "0")
    for ((i=0; i<vc; i++)); do
        local vi uuid port domain pub sid tag
        vi=$(jq --argjson i "$i" '[.inbounds[] | select(.protocol == "vless")][$i]' "$xray_config_path")
        uuid=$(echo "$vi" | jq -r '.settings.clients[0].id')
        port=$(echo "$vi" | jq -r '.port')
        domain=$(echo "$vi" | jq -r '.streamSettings.realitySettings.serverNames[0]')
        pub=$(echo "$vi" | jq -r '.streamSettings.realitySettings.publicKey')
        sid=$(echo "$vi" | jq -r '.streamSettings.realitySettings.shortIds[0]')
        tag=$(echo "$vi" | jq -r '.tag // "VLESS-" + (.port | tostring)')
        [[ -z "$pub" ]] && continue
        local encoded; encoded=$(echo "$tag" | sed 's/ /%20/g')
        local url="vless://${uuid}@${display_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${pub}&sid=${sid}#${encoded}"
        links_array+=("$url")
        if [[ "$is_quiet" = false ]]; then
            [[ $i -gt 0 ]] && echo ""
            echo -e "${green} [ VLESS-Reality - ${tag} ]${none}"
            printf "    %s: ${cyan}%s${none}\n" "服务器" "$ip"
            printf "    %s: ${cyan}%s${none}\n" "端口" "$port"
            printf "    %s: ${cyan}%s${none}\n" "UUID" "${uuid:0:8}...${uuid: -4}"
            printf "    %s: ${cyan}%s${none}\n" "SNI" "$domain"
            printf "    %s: ${cyan}%s${none}\n" "PublicKey" "${pub:0:16}..."
            printf "    %s: ${cyan}%s${none}\n" "ShortId" "$sid"
        fi
    done

    local sc; sc=$(jq '[.inbounds[] | select(.protocol == "shadowsocks")] | length' "$xray_config_path" 2>/dev/null || echo "0")
    for ((i=0; i<sc; i++)); do
        local si port method pass tag
        si=$(jq --argjson i "$i" '[.inbounds[] | select(.protocol == "shadowsocks")][$i]' "$xray_config_path")
        port=$(echo "$si" | jq -r '.port')
        method=$(echo "$si" | jq -r '.settings.method')
        pass=$(echo "$si" | jq -r '.settings.password')
        tag=$(echo "$si" | jq -r '.tag // "Shadowsocks-2022-" + (.port | tostring)')
        local encoded; encoded=$(echo "$tag" | sed 's/ /%20/g')
        local b64; b64=$(echo -n "${method}:${pass}" | base64 -w 0)
        local url="ss://${b64}@${ip}:${port}#${encoded}"
        links_array+=("$url")
        if [[ "$is_quiet" = false ]]; then
            echo ""
            echo -e "${green} [ Shadowsocks-2022 - ${tag} ]${none}"
            printf "    %s: ${cyan}%s${none}\n" "服务器" "$ip"
            printf "    %s: ${cyan}%s${none}\n" "端口" "$port"
            printf "    %s: ${cyan}%s${none}\n" "加密" "$method"
            printf "    %s: ${cyan}%s${none}\n" "密码" "${pass:0:4}...${pass: -4}"
        fi
    done

    if [ ${#links_array[@]} -gt 0 ]; then
        if [[ "$is_quiet" = true ]]; then
            printf "%s\n" "${links_array[@]}"
        else
            draw_divider
            printf "%s\n" "${links_array[@]}" > ~/xray_subscription_info.txt
            success "订阅链接已保存到: ~/xray_subscription_info.txt"
            echo -e "\n${yellow} --- 客户端导入链接 ---${none}\n"
            for l in "${links_array[@]}"; do echo -e "${cyan}${l}${none}\n"; done
            draw_divider
        fi
    fi
}

install_menu() {
    local ve="" se=""
    [[ -f "$xray_config_path" ]] && {
        ve=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
        se=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    }
    draw_menu_header
    if [[ -n "$ve" && -n "$se" ]]; then
        success "已安装 VLESS-Reality + Shadowsocks-2022 双协议"; return
    elif [[ -n "$ve" && -z "$se" ]]; then
        info "已安装 VLESS-Reality"
        printf "  ${green}%-2s${none} %-35s\n" "1." "追加安装 Shadowsocks-2022"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 VLESS-Reality"
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回"
        read -p " 选项 [0-2]: " c || true
        case "$c" in 1) add_ss_to_vless ;; 2) install_vless_only ;; 0) return ;; esac
    elif [[ -z "$ve" && -n "$se" ]]; then
        info "已安装 Shadowsocks-2022"
        printf "  ${green}%-2s${none} %-35s\n" "1." "追加安装 VLESS-Reality"
        printf "  ${red}%-2s${none} %-35s\n" "2." "覆盖重装 Shadowsocks-2022"
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "返回"
        read -p " 选项 [0-2]: " c || true
        case "$c" in 1) add_vless_to_ss ;; 2) install_ss_only ;; 0) return ;; esac
    else
        clean_install_menu
    fi
}

clean_install_menu() {
    draw_menu_header
    printf "  ${green}%-2s${none} %-35s\n" "1." "仅 VLESS-Reality"
    printf "  ${cyan}%-2s${none} %-35s\n" "2." "仅 Shadowsocks-2022"
    printf "  ${yellow}%-2s${none} %-35s\n" "3." "双协议"
    printf "  ${magenta}%-2s${none} %-35s\n" "0." "返回"
    read -p " 选项 [0-3]: " c || true
    case "$c" in 1) install_vless_only ;; 2) install_ss_only ;; 3) install_dual ;; 0) return ;; esac
}

install_vless_only() {
    local port uuid sni tag; prompt_for_vless_config port uuid sni tag
    run_install_vless "$port" "$uuid" "$sni" "$tag"
}

install_ss_only() {
    local port pass tag; prompt_for_ss_config port pass tag
    run_install_ss "$port" "$pass" "$tag"
}

install_dual() {
    info "配置双协议..."
    local vp vu vd vt; prompt_for_vless_config vp vu vd vt
    local def_sp=$(( vp == 443 ? 8388 : vp + 1 ))
    local sp spass st; prompt_for_ss_config sp spass st "$def_sp"
    run_install_dual "$vp" "$vu" "$vd" "$vt" "$sp" "$spass" "$st"
}

add_ss_to_vless() {
    [[ -z "$(get_public_ip)" ]] && { error "无法获取公网 IP"; return 1; }
    local vi; vi=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
    local vp; vp=$(echo "$vi" | jq -r '.port')
    local def=$(( vp == 443 ? 8388 : vp + 1 ))
    local sp spass st; prompt_for_ss_config sp spass st "$def"
    local si; si=$(build_ss_inbound "$sp" "$spass" "$st")
    write_config "[$vi, $si]"
    restart_xray || return 1
    success "追加 Shadowsocks-2022 成功！"; view_all_info
}

add_vless_to_ss() {
    [[ -z "$(get_public_ip)" ]] && { error "无法获取公网 IP"; return 1; }
    local si; si=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
    local vp vu vd vt; prompt_for_vless_config vp vu vd vt
    info "生成 Reality 密钥对..."
    local kp; kp=$("$xray_binary_path" x25519)
    local priv; priv=$(echo "$kp" | awk '/PrivateKey:/ {print $2}')
    local pub;  pub=$(echo "$kp" | awk '/PublicKey/ {print $NF}')
    [[ -z "$priv" || -z "$pub" ]] && { error "生成密钥失败！"; return 1; }
    local vi; vi=$(build_vless_inbound "$vp" "$vu" "$vd" "$priv" "$pub" "$vt")
    write_config "[$vi, $si]"
    restart_xray || return 1
    success "追加 VLESS-Reality 成功！"; view_all_info
}

add_new_vless() {
    [[ ! -f "$xray_binary_path" ]] && { error "Xray 未安装"; return; }
    [[ -z "$(get_public_ip)" ]] && { error "无法获取公网 IP"; return 1; }
    local vp vu vd vt; prompt_for_vless_config vp vu vd vt
    info "生成 Reality 密钥对..."
    local kp; kp=$("$xray_binary_path" x25519)
    local priv; priv=$(echo "$kp" | awk '/PrivateKey:/ {print $2}')
    local pub;  pub=$(echo "$kp" | awk '/PublicKey/ {print $NF}')
    [[ -z "$priv" || -z "$pub" ]] && { error "生成密钥失败！"; return 1; }
    local vi; vi=$(build_vless_inbound "$vp" "$vu" "$vd" "$priv" "$pub" "$vt")
    local existing_inbounds
    if [[ -f "$xray_config_path" ]]; then
        existing_inbounds=$(jq '.inbounds' "$xray_config_path")
        write_config "$(echo "$existing_inbounds" | jq ". += [$vi]")"
    else
        write_config "[$vi]"
    fi
    restart_xray || return 1
    success "新 VLESS 节点添加成功！"; view_all_info
}

add_new_ss() {
    [[ ! -f "$xray_binary_path" ]] && { error "Xray 未安装"; return; }
    [[ -z "$(get_public_ip)" ]] && { error "无法获取公网 IP"; return 1; }
    local sp spass st; prompt_for_ss_config sp spass st
    local si; si=$(build_ss_inbound "$sp" "$spass" "$st")
    local existing_inbounds
    if [[ -f "$xray_config_path" ]]; then
        existing_inbounds=$(jq '.inbounds' "$xray_config_path")
        write_config "$(echo "$existing_inbounds" | jq ". += [$si]")"
    else
        write_config "[$si]"
    fi
    restart_xray || return 1
    success "新 Shadowsocks-2022 节点添加成功！"; view_all_info
}

delete_vless_node() {
    [[ ! -f "$xray_config_path" ]] && { error "配置文件不存在"; return; }
    local vc; vc=$(jq '[.inbounds[] | select(.protocol == "vless")] | length' "$xray_config_path")
    [[ "$vc" -eq 0 ]] && { error "未找到 VLESS 节点"; return; }
    draw_menu_header; echo -e "${cyan} VLESS 节点列表${none}"; draw_divider
    local idx=1
    jq -r '.inbounds[] | select(.protocol == "vless") | "\(.port)|\(.settings.clients[0].id)|\(.tag // "未命名")"' "$xray_config_path" | while IFS='|' read -r p u t; do
        printf "  ${green}%-2s${none} 端口:${cyan}%-6s${none} UUID:${cyan}%s...%s${none} %s\n" "$idx." "$p" "${u:0:8}" "${u: -4}" "$t"; ((idx++))
    done
    draw_divider; printf "  ${yellow}%-2s${none} 返回\n" "0."
    read -p " 选择节点编号 [0-$vc]: " c || true
    [[ "$c" == "0" ]] && return
    [[ ! "$c" =~ ^[0-9]+$ ]] || [[ "$c" -lt 1 ]] || [[ "$c" -gt "$vc" ]] && { error "无效选项"; return; }
    local ni; ni=$(jq --argjson idx "$((c - 1))" '([.inbounds[] | select(.protocol == "vless")] | del(.[$idx])) as $f | [.inbounds[] | select(.protocol != "vless")] + $f' "$xray_config_path")
    write_config "$ni"
    restart_xray || return 1
    success "VLESS 节点删除成功！"; view_all_info
}

delete_ss_node() {
    [[ ! -f "$xray_config_path" ]] && { error "配置文件不存在"; return; }
    local sc; sc=$(jq '[.inbounds[] | select(.protocol == "shadowsocks")] | length' "$xray_config_path")
    [[ "$sc" -eq 0 ]] && { error "未找到 Shadowsocks-2022 节点"; return; }
    draw_menu_header; echo -e "${cyan} Shadowsocks-2022 节点列表${none}"; draw_divider
    local idx=1
    jq -r '.inbounds[] | select(.protocol == "shadowsocks") | "\(.port)|\(.settings.password)|\(.tag // "未命名")"' "$xray_config_path" | while IFS='|' read -r p pw t; do
        printf "  ${green}%-2s${none} 端口:${cyan}%-6s${none} 密码:${cyan}%s...%s${none} %s\n" "$idx." "$p" "${pw:0:4}" "${pw: -4}" "$t"; ((idx++))
    done
    draw_divider; printf "  ${yellow}%-2s${none} 返回\n" "0."
    read -p " 选择节点编号 [0-$sc]: " c || true
    [[ "$c" == "0" ]] && return
    [[ ! "$c" =~ ^[0-9]+$ ]] || [[ "$c" -lt 1 ]] || [[ "$c" -gt "$sc" ]] && { error "无效选项"; return; }
    local ni; ni=$(jq --argjson idx "$((c - 1))" '([.inbounds[] | select(.protocol == "shadowsocks")] | del(.[$idx])) as $f | [.inbounds[] | select(.protocol != "shadowsocks")] + $f' "$xray_config_path")
    write_config "$ni"
    restart_xray || return 1
    success "Shadowsocks-2022 节点删除成功！"; view_all_info
}

update_xray() {
    [[ ! -f "$xray_binary_path" ]] && { error "Xray 未安装"; return; }
    info "检查最新版本..."
    local cv lv
    cv=$("$xray_binary_path" version 2>/dev/null | head -n 1 | awk '{print $2}')
    lv=$(curl -s --max-time 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | jq -r '.tag_name' 2>/dev/null | sed 's/v//' || echo "")
    [[ -z "$lv" ]] && { info "无法获取最新版本，强制更新..."; run_core_install || { error "更新失败"; return 1; }; restart_xray || return 1; success "Xray 更新完成！"; return; }
    info "当前: ${cyan}${cv}${none}，最新: ${cyan}${lv}${none}"
    [[ "$cv" == "$lv" ]] && { success "已是最新版本"; return; }
    run_core_install || { error "更新失败"; return 1; }
    restart_xray || return 1
    success "Xray 更新成功！"
}

uninstall_xray() {
    [[ ! -f "$xray_binary_path" ]] && { error "Xray 未安装"; return; }
    read -p "$(echo -e "${yellow}确定要卸载 Xray 吗？[Y/n]: ${none}")" c || true
    [[ "$c" =~ ^[nN]$ ]] && { info "已取消"; return; }
    info "卸载 Xray..."
    execute_official_script "remove --purge" || { error "卸载失败！"; return 1; }
    rm -f ~/xray_subscription_info.txt
    success "Xray 已卸载"
}

manage_routing_rules() {
    clear
    [[ ! -f "$xray_config_path" ]] && { error "配置文件不存在！请先安装 Xray"; return 1; }
    local has_routing; has_routing=$(jq -r '.routing // empty' "$xray_config_path" 2>/dev/null)
    if [[ -n "$has_routing" ]]; then
        echo -e "${green}✓ 路由过滤规则已启用${none}"
        echo "  屏蔽: 广告/色情/missav"
        echo ""; echo -e "${cyan}1.${none} 禁用路由过滤"; echo -e "${red}0.${none} 返回"
        read -p " 选项 [0-1]: " c || true
        [[ "$c" == "1" ]] && {
            local ib; ib=$(jq -c '.inbounds' "$xray_config_path")
            write_config "$ib" "false"
            restart_xray && success "路由过滤已禁用！"
        }
    else
        echo -e "${yellow}✗ 路由过滤规则未启用${none}"
        echo "  启用后屏蔽: 广告/色情/missav"
        echo ""; echo -e "${green}1.${none} 启用路由过滤"; echo -e "${red}0.${none} 返回"
        read -p " 选项 [0-1]: " c || true
        [[ "$c" == "1" ]] && {
            if [[ ! -f "/usr/local/share/xray/geosite.dat" ]]; then
                info "GeoSite 不存在，下载中..."
                execute_official_script "install-geodata" || true
            fi
            local ib; ib=$(jq -c '.inbounds' "$xray_config_path")
            write_config "$ib" "true"
            restart_xray && success "路由过滤已启用！"
        }
    fi
}

view_xray_log() {
    [[ ! -f "$xray_binary_path" ]] && { error "Xray 未安装"; return; }
    info "实时日志... 按 Ctrl+C 退出"
    journalctl -u xray -f --no-pager
}

main_menu() {
    while true; do
        draw_menu_header
        printf "  ${green}%-2s${none} %-35s\n" "1." "安装 Xray (VLESS/Shadowsocks)"
        draw_divider
        echo -e "${cyan}[VLESS 管理]${none}"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "增加 VLESS 协议"
        printf "  ${magenta}%-2s${none} %-35s\n" "3." "删除指定 VLESS 节点"
        draw_divider
        echo -e "${cyan}[Shadowsocks-2022 管理]${none}"
        printf "  ${cyan}%-2s${none} %-35s\n" "4." "增加 Shadowsocks-2022 协议"
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "删除指定 Shadowsocks-2022 节点"
        draw_divider
        echo -e "${cyan}[Xray 服务]${none}"
        printf "  ${green}%-2s${none} %-35s\n" "6." "更新 Xray"
        printf "  ${red}%-2s${none} %-35s\n" "7." "卸载 Xray"
        printf "  ${cyan}%-2s${none} %-35s\n" "8." "重启 Xray"
        printf "  ${magenta}%-2s${none} %-35s\n" "9." "查看 Xray 日志"
        printf "  ${yellow}%-2s${none} %-35s\n" "10." "查看订阅信息"
        draw_divider
        printf "  ${green}%-2s${none} %-35s ⭐\n" "11." "路由过滤规则管理"
        draw_divider
        printf "  ${red}%-2s${none} %-35s\n" "0." "退出"
        draw_divider
        read -p " 请输入选项 [0-11]: " choice || true
        local needs_pause=true
        case "$choice" in
            1) install_menu ;;
            2) add_new_vless ;;
            3) delete_vless_node ;;
            4) add_new_ss ;;
            5) delete_ss_node ;;
            6) update_xray ;;
            7) uninstall_xray ;;
            8) restart_xray ;;
            9) view_xray_log; needs_pause=false ;;
            10) view_all_info ;;
            11) manage_routing_rules ;;
            0) success "感谢使用！"; exit 0 ;;
            *) error "无效选项。请输入 0-11。" ;;
        esac
        $needs_pause && press_any_key_to_continue
    done
}

pre_check
main_menu
XRAY_SCRIPT_EOF

    chmod +x "$script_path"
    echo -e "${gl_lv}✅ 脚本准备完成，启动 Xray 管理菜单...${gl_bai}"
    sleep 1

    bash "$script_path"
    rm -f "$script_path"
}

#=============================================================================
# 主菜单
#=============================================================================
main_menu() {
    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}  Xray 多协议 + SOCKS5 代理 一体化管理工具${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""

        # 显示 Xray 状态
        if [ -f "/usr/local/bin/xray" ]; then
            local xv; xv=$(/usr/local/bin/xray version 2>/dev/null | head -1 | awk '{print $2}')
            if systemctl is-active --quiet xray 2>/dev/null; then
                echo -e "  Xray:   ${gl_lv}✅ 运行中${gl_bai}  版本: ${gl_huang}${xv}${gl_bai}"
            else
                echo -e "  Xray:   ${gl_hong}❌ 未运行${gl_bai}  版本: ${gl_huang}${xv}${gl_bai}"
            fi
        else
            echo -e "  Xray:   ${gl_hui}未安装${gl_bai}"
        fi

        # 显示 SOCKS5 状态
        if [ -f "$SOCKS5_CONFIG_FILE" ]; then
            local sp su
            sp=$(grep -o '"listen_port"[[:space:]]*:[[:space:]]*[0-9]*' "$SOCKS5_CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*$')
            su=$(grep -o '"username"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" 2>/dev/null | sed 's/.*"username"[[:space:]]*:[[:space:]]*"//;s/"$//')
            if systemctl is-active --quiet "$SOCKS5_SERVICE_NAME" 2>/dev/null; then
                echo -e "  SOCKS5: ${gl_lv}✅ 运行中${gl_bai}  端口: ${gl_huang}${sp}${gl_bai}  用户: ${gl_huang}${su}${gl_bai}"
            else
                echo -e "  SOCKS5: ${gl_hong}❌ 未运行${gl_bai}"
            fi
        else
            echo -e "  SOCKS5: ${gl_hui}未部署${gl_bai}"
        fi

        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "  ${gl_lv}1.${gl_bai} 星辰大海 Xray 一键多协议"
        echo -e "     ${gl_hui}（VLESS-Reality / Shadowsocks-2022 / 链式代理）${gl_bai}"
        echo ""
        echo -e "  ${gl_lv}2.${gl_bai} Sing-box SOCKS5 代理管理"
        echo -e "     ${gl_hui}（一键部署 / 修改 / 删除 / 查看）${gl_bai}"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "  ${gl_hong}0.${gl_bai} 退出"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        read -e -p "请输入选项 [0-2]: " choice

        case "$choice" in
            1) run_xray_menu ;;
            2) menu_socks5 ;;
            0) echo -e "${gl_lv}再见！${gl_bai}"; exit 0 ;;
            *) echo -e "${gl_hong}❌ 无效选项${gl_bai}"; sleep 1 ;;
        esac
    done
}

check_root
main_menu
