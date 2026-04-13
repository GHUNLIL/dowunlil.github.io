#!/bin/bash
#=============================================================================
# Xray 多协议 + SOCKS5 代理 一体化管理脚本
#=============================================================================

red='\e[91m'; green='\e[92m'; yellow='\e[93m'
magenta='\e[95m'; cyan='\e[96m'; none='\e[0m'
gl_hong='\033[31m'; gl_lv='\033[32m'; gl_huang='\033[33m'
gl_bai='\033[0m'; gl_kjlan='\033[96m'; gl_zi='\033[35m'; gl_hui='\033[90m'

check_root() {
    [ "$EUID" -ne 0 ] && echo -e "${gl_hong}错误: 需要 root 权限！${gl_bai}" && exit 1
}

break_end() {
    echo ""
    read -n 1 -s -r -p "按任意键继续..."
    echo ""
}

SOCKS5_CONFIG_DIR="/etc/sbox_socks5"
SOCKS5_CONFIG_FILE="${SOCKS5_CONFIG_DIR}/config.json"
SOCKS5_SERVICE_NAME="sbox-socks5"
xray_config_path="/usr/local/etc/xray/config.json"
xray_binary_path="/usr/local/bin/xray"
xray_install_script_url="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# 获取公网 IP
get_public_ip() {
    local ip
    for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
        ip=$(curl -4s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [ -n "$ip" ] && echo "$ip" && return 0
    done
    for url in "https://api64.ipify.org" "https://ip.sb"; do
        ip=$(curl -6s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [ -n "$ip" ] && echo "$ip" && return 0
    done
}

# 检测 sing-box
detect_singbox_cmd() {
    DETECTED_SINGBOX_CMD=""
    for path in /etc/sing-box/sing-box /usr/local/bin/sing-box /opt/sing-box/sing-box; do
        [ -e "$path" ] || continue
        chmod +x "$path" 2>/dev/null
        [ -x "$path" ] || continue
        [ -L "$path" ] && path=$(readlink -f "$path")
        DETECTED_SINGBOX_CMD="$path" && return 0
    done
    for cmd in sing-box sb; do
        command -v "$cmd" &>/dev/null && DETECTED_SINGBOX_CMD=$(which "$cmd") && return 0
    done
    return 1
}

# 安装 sing-box
install_singbox_binary() {
    clear
    echo -e "${gl_kjlan}=== 安装 Sing-box 核心程序 ===${gl_bai}"
    echo ""
    read -e -p "$(echo -e "${gl_huang}是否安装？(Y/N): ${gl_bai}")" confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && return 1
    local arch
    case "$(uname -m)" in
        aarch64|arm64) arch="arm64" ;;
        x86_64|amd64)  arch="amd64" ;;
        armv7l)        arch="armv7" ;;
        *) echo -e "${gl_hong}❌ 不支持的架构${gl_bai}"; return 1 ;;
    esac
    local version
    version=$(wget --timeout=10 --tries=2 -qO- "https://api.github.com/repos/SagerNet/sing-box/releases" 2>/dev/null \
        | grep '"tag_name"' | sed -E 's/.*"tag_name":[[:space:]]*"v([^"]+)".*/\1/' \
        | grep -v -E '(alpha|beta|rc)' | sort -Vr | head -1)
    [ -z "$version" ] && version="1.10.0"
    echo -e "${gl_zi}下载 sing-box v${version} (${arch})...${gl_bai}"
    local tmp_dir="/tmp/singbox-install-$$"
    mkdir -p "$tmp_dir"
    wget --timeout=30 --tries=3 -qO "${tmp_dir}/sing-box.tar.gz" \
        "https://github.com/SagerNet/sing-box/releases/download/v${version}/sing-box-${version}-linux-${arch}.tar.gz" || {
        echo -e "${gl_hong}❌ 下载失败${gl_bai}"; rm -rf "$tmp_dir"; return 1; }
    tar -xzf "${tmp_dir}/sing-box.tar.gz" -C "$tmp_dir" 2>/dev/null || {
        echo -e "${gl_hong}❌ 解压失败${gl_bai}"; rm -rf "$tmp_dir"; return 1; }
    local bin; bin=$(find "$tmp_dir" -name "sing-box" -type f 2>/dev/null | head -1)
    [ -z "$bin" ] && { echo -e "${gl_hong}❌ 未找到二进制${gl_bai}"; rm -rf "$tmp_dir"; return 1; }
    mkdir -p /etc/sing-box
    mv "$bin" /etc/sing-box/sing-box && chmod +x /etc/sing-box/sing-box
    rm -rf "$tmp_dir"
    /etc/sing-box/sing-box version >/dev/null 2>&1 && \
        echo -e "${gl_lv}✅ sing-box 安装成功${gl_bai}" || { echo -e "${gl_hong}❌ 验证失败${gl_bai}"; return 1; }
}

#=============================================================================
# SOCKS5 功能
#=============================================================================

deploy_socks5() {
    clear
    echo -e "${gl_kjlan}=== Sing-box SOCKS5 一键部署 ===${gl_bai}"
    echo ""
    echo -e "${gl_zi}[1/7] 检测 sing-box...${gl_bai}"
    local SINGBOX_CMD=""
    if detect_singbox_cmd; then
        SINGBOX_CMD="$DETECTED_SINGBOX_CMD"
        echo -e "${gl_lv}✅ 找到: $SINGBOX_CMD${gl_bai}"
    else
        install_singbox_binary || { break_end; return 1; }
        detect_singbox_cmd && SINGBOX_CMD="$DETECTED_SINGBOX_CMD" || {
            echo -e "${gl_hong}❌ 仍找不到 sing-box${gl_bai}"; break_end; return 1; }
    fi
    echo ""
    echo -e "${gl_zi}[2/7] 配置参数...${gl_bai}"
    echo ""
    echo "  1. IPv4 only (0.0.0.0)  [默认]"
    echo "  2. IPv6 only (::)"
    read -e -p "$(echo -e "${gl_huang}监听模式 [1/2]: ${gl_bai}")" lc
    local listen_addr
    if [ "$lc" = "2" ]; then
        listen_addr="::"
        echo -e "${gl_lv}✅ IPv6 only${gl_bai}"
    else
        listen_addr="0.0.0.0"
        echo -e "${gl_lv}✅ IPv4 only${gl_bai}"
    fi
    echo ""
    local socks5_port=""
    while true; do
        read -e -p "$(echo -e "${gl_huang}端口 [回车随机]: ${gl_bai}")" socks5_port
        if [ -z "$socks5_port" ]; then
            socks5_port=$(( ((RANDOM<<15)|RANDOM) % 55536 + 10000 ))
            echo -e "${gl_lv}✅ 随机端口: ${socks5_port}${gl_bai}"; break
        elif [[ "$socks5_port" =~ ^[0-9]+$ ]] && [ "$socks5_port" -ge 1024 ] && [ "$socks5_port" -le 65535 ]; then
            if ss -tulpn 2>/dev/null | grep -q ":${socks5_port} "; then
                echo -e "${gl_hong}❌ 端口已占用${gl_bai}"
            else
                echo -e "${gl_lv}✅ 端口: ${socks5_port}${gl_bai}"; break
            fi
        else
            echo -e "${gl_hong}❌ 无效端口${gl_bai}"
        fi
    done
    echo ""
    local socks5_user=""
    while true; do
        read -e -p "$(echo -e "${gl_huang}用户名: ${gl_bai}")" socks5_user
        [ -z "$socks5_user" ] && { echo -e "${gl_hong}❌ 不能为空${gl_bai}"; continue; }
        [[ "$socks5_user" =~ ^[a-zA-Z0-9_-]+$ ]] && echo -e "${gl_lv}✅ 用户名: ${socks5_user}${gl_bai}" && break
        echo -e "${gl_hong}❌ 只能含字母/数字/下划线/连字符${gl_bai}"
    done
    echo ""
    local socks5_pass=""
    while true; do
        read -e -p "$(echo -e "${gl_huang}密码 (≥6位): ${gl_bai}")" socks5_pass
        [ -z "$socks5_pass" ] && { echo -e "${gl_hong}❌ 不能为空${gl_bai}"; continue; }
        [ ${#socks5_pass} -lt 6 ] && { echo -e "${gl_hong}❌ 至少6位${gl_bai}"; continue; }
        [[ "$socks5_pass" == *\"* || "$socks5_pass" == *\\* ]] && { echo -e "${gl_hong}❌ 不能含 \" 或 \\${gl_bai}"; continue; }
        echo -e "${gl_lv}✅ 密码已设置${gl_bai}"; break
    done
    echo ""
    echo -e "${gl_kjlan}━━━ 配置确认 ━━━${gl_bai}"
    echo -e "  监听: ${gl_huang}${listen_addr}${gl_bai}  端口: ${gl_huang}${socks5_port}${gl_bai}"
    echo -e "  用户: ${gl_huang}${socks5_user}${gl_bai}  密码: ${gl_huang}${socks5_pass}${gl_bai}"
    echo ""
    read -e -p "$(echo -e "${gl_huang}确认部署？(Y/N): ${gl_bai}")" confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "已取消"; break_end; return 1; }
    echo ""
    echo -e "${gl_zi}[3/7] 创建目录...${gl_bai}"
    mkdir -p "$SOCKS5_CONFIG_DIR"
    echo -e "${gl_zi}[4/7] 写入配置文件...${gl_bai}"
    cat > "$SOCKS5_CONFIG_FILE" << EOF
{
  "log": { "level": "info", "output": "${SOCKS5_CONFIG_DIR}/socks5.log" },
  "inbounds": [{
    "type": "socks", "tag": "socks5-in",
    "listen": "${listen_addr}", "listen_port": ${socks5_port},
    "users": [{ "username": "${socks5_user}", "password": "${socks5_pass}" }]
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
    chmod 600 "$SOCKS5_CONFIG_FILE"
    echo -e "${gl_lv}✅ 配置写入成功${gl_bai}"
    echo -e "${gl_zi}[5/7] 验证配置...${gl_bai}"
    $SINGBOX_CMD check -c "$SOCKS5_CONFIG_FILE" >/dev/null 2>&1 || {
        echo -e "${gl_hong}❌ 配置语法错误${gl_bai}"; $SINGBOX_CMD check -c "$SOCKS5_CONFIG_FILE"; break_end; return 1; }
    echo -e "${gl_lv}✅ 语法正确${gl_bai}"
    echo -e "${gl_zi}[6/7] 创建 systemd 服务...${gl_bai}"
    cat > "/etc/systemd/system/${SOCKS5_SERVICE_NAME}.service" << EOF
[Unit]
Description=Sing-box SOCKS5 Service
After=network.target

[Service]
Type=simple
ExecStart=${SINGBOX_CMD} run -c ${SOCKS5_CONFIG_FILE}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    echo -e "${gl_lv}✅ 服务文件创建成功${gl_bai}"
    echo -e "${gl_zi}[7/7] 启动服务...${gl_bai}"
    systemctl daemon-reload
    systemctl enable "$SOCKS5_SERVICE_NAME" >/dev/null 2>&1
    systemctl restart "$SOCKS5_SERVICE_NAME" >/dev/null 2>&1
    sleep 3
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    systemctl is-active --quiet "$SOCKS5_SERVICE_NAME" && \
        echo -e "  服务: ${gl_lv}✅ Running${gl_bai}" || echo -e "  服务: ${gl_hong}❌ Failed${gl_bai}"
    ss -tulpn 2>/dev/null | grep -q ":${socks5_port} " && \
        echo -e "  端口: ${gl_lv}✅ :${socks5_port}${gl_bai}" || echo -e "  端口: ${gl_hong}❌ 未监听${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    if systemctl is-active --quiet "$SOCKS5_SERVICE_NAME"; then
        local server_ip
        [ "$listen_addr" = "::" ] && server_ip=$(curl -6s --max-time 5 ip.sb 2>/dev/null) \
                                   || server_ip=$(curl -4s --max-time 5 ip.sb 2>/dev/null)
        [ -z "$server_ip" ] && server_ip="你的服务器IP"
        echo ""
        echo -e "${gl_lv}🎉 部署成功！${gl_bai}"
        echo ""
        echo -e "  服务器: ${gl_huang}${server_ip}${gl_bai}"
        echo -e "  端口:   ${gl_huang}${socks5_port}${gl_bai}"
        echo -e "  用户名: ${gl_huang}${socks5_user}${gl_bai}"
        echo -e "  密码:   ${gl_huang}${socks5_pass}${gl_bai}"
        echo ""
        echo -e "  URL: ${gl_huang}socks5://${socks5_user}:${socks5_pass}@${server_ip}:${socks5_port}${gl_bai}"
    else
        echo ""
        echo -e "${gl_hong}❌ 部署失败，查看日志: journalctl -u ${SOCKS5_SERVICE_NAME} -n 50${gl_bai}"
    fi
    break_end
}

view_socks5() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}      SOCKS5 代理信息${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    if [ ! -f "$SOCKS5_CONFIG_FILE" ]; then
        echo -e "${gl_huang}⚠️  未检测到配置${gl_bai}"; break_end; return 1
    fi
    local port username password listen_addr server_ip
    port=$(grep -o '"listen_port"[[:space:]]*:[[:space:]]*[0-9]*' "$SOCKS5_CONFIG_FILE" | grep -o '[0-9]*$')
    username=$(grep -o '"username"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" | sed 's/.*"//;s/"$//')
    password=$(grep -o '"password"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" | sed 's/.*"//;s/"$//')
    listen_addr=$(grep -o '"listen"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" | sed 's/.*"//;s/"$//')
    [ "$listen_addr" = "::" ] && server_ip=$(curl -6s --max-time 5 ip.sb 2>/dev/null) \
                               || server_ip=$(curl -4s --max-time 5 ip.sb 2>/dev/null)
    [ -z "$server_ip" ] && server_ip="你的服务器IP"
    local sstat pstat
    systemctl is-active --quiet "$SOCKS5_SERVICE_NAME" && sstat="${gl_lv}✅ 运行中${gl_bai}" || sstat="${gl_hong}❌ 未运行${gl_bai}"
    ss -tulpn 2>/dev/null | grep -q ":${port} " && pstat="${gl_lv}✅ 监听中${gl_bai}" || pstat="${gl_hong}❌ 未监听${gl_bai}"
    echo -e "  服务器: ${gl_huang}${server_ip}${gl_bai}"
    echo -e "  端口:   ${gl_huang}${port}${gl_bai}"
    echo -e "  用户名: ${gl_huang}${username}${gl_bai}"
    echo -e "  密码:   ${gl_huang}${password}${gl_bai}"
    echo -e "  服务:   $sstat"
    echo -e "  端口:   $pstat"
    echo ""
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_lv}快捷 URL：${gl_bai}"
    echo "socks5://${username}:${password}@${server_ip}:${port}"
    echo ""
    echo -e "${gl_zi}日志: journalctl -u ${SOCKS5_SERVICE_NAME} -f${gl_bai}"
    break_end
}

modify_socks5() {
    clear
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo -e "${gl_kjlan}      修改 SOCKS5 配置${gl_bai}"
    echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
    echo ""
    if [ ! -f "$SOCKS5_CONFIG_FILE" ]; then
        echo -e "${gl_huang}⚠️  未检测到配置${gl_bai}"; break_end; return 1
    fi
    local cur_port cur_user cur_pass cur_listen
    cur_port=$(grep -o '"listen_port"[[:space:]]*:[[:space:]]*[0-9]*' "$SOCKS5_CONFIG_FILE" | grep -o '[0-9]*$')
    cur_user=$(grep -o '"username"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" | sed 's/.*"//;s/"$//')
    cur_pass=$(grep -o '"password"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" | sed 's/.*"//;s/"$//')
    cur_listen=$(grep -o '"listen"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" | sed 's/.*"//;s/"$//')
    echo -e "${gl_zi}当前: 端口=${cur_port}  用户=${cur_user}${gl_bai}"
    echo -e "${gl_huang}回车保持不变${gl_bai}"
    echo ""
    local new_port new_user new_pass
    while true; do
        read -e -p "新端口 [${cur_port}]: " new_port
        new_port="${new_port:-$cur_port}"
        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
            echo -e "${gl_hong}❌ 无效端口${gl_bai}"; continue
        fi
        [ "$new_port" != "$cur_port" ] && ss -tulpn 2>/dev/null | grep -q ":${new_port} " && \
            { echo -e "${gl_hong}❌ 端口已占用${gl_bai}"; continue; }
        break
    done
    while true; do
        read -e -p "新用户名 [${cur_user}]: " new_user
        new_user="${new_user:-$cur_user}"
        [[ "$new_user" =~ ^[a-zA-Z0-9_-]+$ ]] && break || echo -e "${gl_hong}❌ 格式无效${gl_bai}"
    done
    while true; do
        read -e -p "新密码 [回车不变]: " new_pass
        if [ -z "$new_pass" ]; then new_pass="$cur_pass"; break
        elif [ ${#new_pass} -lt 6 ]; then echo -e "${gl_hong}❌ 至少6位${gl_bai}"
        elif [[ "$new_pass" == *\"* || "$new_pass" == *\\* ]]; then echo -e "${gl_hong}❌ 含非法字符${gl_bai}"
        else break; fi
    done
    detect_singbox_cmd || { echo -e "${gl_hong}❌ 未找到 sing-box${gl_bai}"; break_end; return 1; }
    cat > "$SOCKS5_CONFIG_FILE" << EOF
{
  "log": { "level": "info", "output": "${SOCKS5_CONFIG_DIR}/socks5.log" },
  "inbounds": [{
    "type": "socks", "tag": "socks5-in",
    "listen": "${cur_listen}", "listen_port": ${new_port},
    "users": [{ "username": "${new_user}", "password": "${new_pass}" }]
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
    chmod 600 "$SOCKS5_CONFIG_FILE"
    systemctl restart "$SOCKS5_SERVICE_NAME" 2>/dev/null
    sleep 2
    systemctl is-active --quiet "$SOCKS5_SERVICE_NAME" && \
        echo -e "${gl_lv}✅ 修改成功，服务已重启${gl_bai}" || echo -e "${gl_hong}❌ 服务重启失败${gl_bai}"
    break_end
}

delete_socks5() {
    clear
    echo -e "${gl_hong}━━━ 删除 SOCKS5 代理 ━━━${gl_bai}"
    echo ""
    local has_config=false has_service=false
    { [ -f "$SOCKS5_CONFIG_FILE" ] || [ -d "$SOCKS5_CONFIG_DIR" ]; } && has_config=true
    [ -f "/etc/systemd/system/${SOCKS5_SERVICE_NAME}.service" ] && has_service=true
    if [ "$has_config" = false ] && [ "$has_service" = false ]; then
        echo -e "${gl_huang}⚠️  未检测到配置${gl_bai}"; break_end; return 0
    fi
    echo -e "${gl_hong}⚠️  此操作不可恢复！${gl_bai}"
    echo ""
    read -e -p "$(echo -e "${gl_huang}确认删除？输入 'yes': ${gl_bai}")" confirm
    [ "$confirm" != "yes" ] && { echo "已取消"; break_end; return 0; }
    if $has_service; then
        systemctl stop "$SOCKS5_SERVICE_NAME" 2>/dev/null
        systemctl disable "$SOCKS5_SERVICE_NAME" 2>/dev/null
        rm -f "/etc/systemd/system/${SOCKS5_SERVICE_NAME}.service"
        systemctl daemon-reload
        echo -e "${gl_lv}✅ 服务已删除${gl_bai}"
    fi
    $has_config && rm -rf "$SOCKS5_CONFIG_DIR" && echo -e "${gl_lv}✅ 配置已删除${gl_bai}"
    echo ""
    echo -e "${gl_lv}🎉 SOCKS5 代理已完全删除${gl_bai}"
    break_end
}

menu_socks5() {
    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}      Sing-box SOCKS5 管理${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        if [ -f "$SOCKS5_CONFIG_FILE" ]; then
            local sp su
            sp=$(grep -o '"listen_port"[[:space:]]*:[[:space:]]*[0-9]*' "$SOCKS5_CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*$')
            su=$(grep -o '"username"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" 2>/dev/null | sed 's/.*"//;s/"$//')
            systemctl is-active --quiet "$SOCKS5_SERVICE_NAME" && \
                echo -e "  ${gl_lv}✅ 运行中${gl_bai}  端口:${gl_huang}${sp}${gl_bai}  用户:${gl_huang}${su}${gl_bai}" || \
                echo -e "  ${gl_hong}❌ 未运行${gl_bai}"
        else
            echo -e "  ${gl_zi}未部署${gl_bai}"
        fi
        echo ""
        echo "  1. 新增 SOCKS5 代理"
        echo "  2. 修改 SOCKS5 配置"
        echo "  3. 删除 SOCKS5 代理"
        echo "  4. 查看 SOCKS5 信息"
        echo "  0. 返回主菜单"
        echo ""
        read -e -p "请输入选项 [0-4]: " choice
        case "$choice" in
            1)
                if [ -f "$SOCKS5_CONFIG_FILE" ]; then
                    read -e -p "$(echo -e "${gl_huang}已存在配置，是否覆盖？(Y/N): ${gl_bai}")" ow
                    [[ "$ow" =~ ^[Yy]$ ]] || continue
                fi
                deploy_socks5 ;;
            2) modify_socks5 ;;
            3) delete_socks5 ;;
            4) view_socks5 ;;
            0) return ;;
            *) echo -e "${gl_hong}❌ 无效选项${gl_bai}"; sleep 1 ;;
        esac
    done
}

#=============================================================================
# Xray 功能
#=============================================================================

xray_error()   { echo -e "\n${red}[✖] $1${none}\n" >&2; }
xray_info()    { echo -e "\n${yellow}[!] $1${none}\n"; }
xray_success() { echo -e "\n${green}[✔] $1${none}\n"; }

draw_divider() { printf "%0.s─" {1..48}; printf "\n"; }

draw_xray_header() {
    clear
    echo -e "${cyan} Xray VLESS-Reality & Shadowsocks-2022 管理${none}"
    draw_divider
    if [ -f "$xray_binary_path" ] && [ -x "$xray_binary_path" ]; then
        local sv; sv=$("$xray_binary_path" version 2>/dev/null | head -1 | awk '{print $2}')
        if systemctl is-active --quiet xray 2>/dev/null; then
            echo -e " Xray: ${green}已安装${none} | ${green}运行中${none} | v${cyan}${sv}${none}"
        else
            echo -e " Xray: ${green}已安装${none} | ${yellow}未运行${none} | v${cyan}${sv}${none}"
        fi
    else
        echo -e " Xray: ${red}未安装${none}"
    fi
    draw_divider
}

press_any_key() { echo ""; read -n 1 -s -r -p " 按任意键返回..."; }

xray_pre_check() {
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null; then
        echo -e "${gl_huang}安装依赖 jq curl...${gl_bai}"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq 2>/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y jq curl 2>/dev/null
        command -v jq &>/dev/null && command -v curl &>/dev/null || {
            echo -e "${gl_hong}❌ 依赖安装失败，请手动: apt install -y jq curl${gl_bai}"
            return 1
        }
    fi
    return 0
}

generate_ss_key()  { openssl rand -base64 16; }
generate_shortid() { openssl rand -hex 4; }

build_vless_inbound() {
    local port="$1" uuid="$2" domain="$3" priv="$4" pub="$5" tag="$6"
    local sid="${7:-$(generate_shortid)}"
    jq -n \
        --argjson port "$port" --arg uuid "$uuid" --arg domain "$domain" \
        --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" --arg tag "$tag" \
    '{
        "listen":"0.0.0.0","port":$port,"protocol":"vless",
        "settings":{"clients":[{"id":$uuid,"flow":"xtls-rprx-vision"}],"decryption":"none"},
        "streamSettings":{"network":"tcp","security":"reality","realitySettings":{
            "show":false,"dest":($domain+":443"),"xver":0,
            "serverNames":[$domain],"privateKey":$priv,"publicKey":$pub,"shortIds":[$sid]
        }},
        "sniffing":{"enabled":true,"destOverride":["http","tls","quic"]},
        "tag":$tag
    }'
}

build_ss_inbound() {
    jq -n --argjson port "$1" --arg pass "$2" --arg tag "$3" \
    '{"listen":"0.0.0.0","port":$port,"protocol":"shadowsocks","settings":{"method":"2022-blake3-aes-128-gcm","password":$pass},"tag":$tag}'
}

xray_write_config() {
    local inbounds_json="$1" enable_routing="${2:-}"
    if [ -z "$enable_routing" ]; then
        if [ -f "$xray_config_path" ] && [ -n "$(jq -r '.routing // empty' "$xray_config_path" 2>/dev/null)" ]; then
            enable_routing="true"
        else
            enable_routing="false"
        fi
    fi
    local ext_out='[]' ext_rules='[]'
    if [ -f "$xray_config_path" ] && jq empty "$xray_config_path" 2>/dev/null; then
        if jq -e '.inbounds[]? | select(.protocol == "vless" or .protocol == "shadowsocks")' "$xray_config_path" &>/dev/null; then
            local t
            t=$(jq -c '[.outbounds[]? | select(.protocol != "freedom" and .protocol != "blackhole")]' "$xray_config_path" 2>/dev/null)
            [ -n "$t" ] && echo "$t" | jq empty 2>/dev/null && ext_out="$t"
            t=$(jq -c '[.routing.rules[]? | select(.inboundTag != null or (.outboundTag? | startswith("socks5-")))]' "$xray_config_path" 2>/dev/null)
            [ -n "$t" ] && echo "$t" | jq empty 2>/dev/null && ext_rules="$t"
        fi
    fi
    inbounds_json=$(echo "$inbounds_json" | jq -c '.')
    local base_out
    if [ "$enable_routing" = "true" ]; then
        base_out='[{"protocol":"freedom","tag":"direct","settings":{"domainStrategy":"UseIPv4v6"}},{"protocol":"blackhole","tag":"block"}]'
    else
        base_out='[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4v6"}}]'
    fi
    local full_out; full_out=$(echo "$base_out" | jq -c --argjson c "$ext_out" '. + $c')
    local full_rules
    if [ "$enable_routing" = "true" ]; then
        local def_block='[{"type":"field","domain":["geosite:category-ads-all","geosite:category-porn","regexp:.*missav.*"],"outboundTag":"block"}]'
        full_rules=$(echo "$ext_rules" | jq -c --argjson d "$def_block" '. + $d')
    else
        full_rules="$ext_rules"
    fi
    local cfg
    if [ "$enable_routing" = "true" ]; then
        cfg=$(jq -n --argjson i "$inbounds_json" --argjson o "$full_out" --argjson r "$full_rules" \
            '{"log":{"loglevel":"warning"},"inbounds":$i,"outbounds":$o,"routing":{"domainStrategy":"IPOnDemand","rules":$r}}')
    else
        local rl; rl=$(echo "$full_rules" | jq 'length')
        if [ "$rl" -gt 0 ]; then
            cfg=$(jq -n --argjson i "$inbounds_json" --argjson o "$full_out" --argjson r "$full_rules" \
                '{"log":{"loglevel":"warning"},"inbounds":$i,"outbounds":$o,"routing":{"domainStrategy":"IPOnDemand","rules":$r}}')
        else
            cfg=$(jq -n --argjson i "$inbounds_json" --argjson o "$full_out" \
                '{"log":{"loglevel":"warning"},"inbounds":$i,"outbounds":$o}')
        fi
    fi
    echo "$cfg" | jq . >/dev/null 2>&1 || { xray_error "配置格式错误！"; return 1; }
    echo "$cfg" > "$xray_config_path"
    chmod 640 "$xray_config_path"
    chown nobody:root "$xray_config_path" 2>/dev/null || true
}

run_xray_install_script() {
    local args="$1"
    local tmp="/tmp/xray_install_$$.sh"
    curl -fsSL --max-time 60 "$xray_install_script_url" -o "$tmp" 2>/dev/null || {
        xray_error "下载安装脚本失败！"; return 1; }
    [[ -s "$tmp" ]] || { xray_error "下载文件为空"; rm -f "$tmp"; return 1; }
    chmod +x "$tmp"
    bash "$tmp" $args
    local rc=$?
    rm -f "$tmp"
    return $rc
}

xray_core_install() {
    xray_info "下载安装 Xray 核心..."
    run_xray_install_script "install" || { xray_error "安装失败！"; return 1; }
    xray_info "更新 GeoIP/GeoSite..."
    run_xray_install_script "install-geodata" || xray_info "Geo 数据更新失败，可稍后更新"
    xray_success "Xray 核心安装完成"
}

xray_restart() {
    [ ! -f "$xray_binary_path" ] && { xray_error "Xray 未安装"; return 1; }
    xray_info "重启 Xray..."
    systemctl restart xray 2>/dev/null || { xray_error "重启失败"; return 1; }
    sleep 2
    systemctl is-active --quiet xray && xray_success "Xray 已重启！" || { xray_error "启动失败"; return 1; }
}

is_valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

xray_port_available() {
    is_valid_port "$1" || { xray_error "端口号无效"; return 1; }
    ss -tlpn 2>/dev/null | grep -q ":$1 " && { xray_error "端口 $1 已被系统占用"; return 1; }
    if [ -f "$xray_config_path" ]; then
        jq -r '.inbounds[]?.port // empty' "$xray_config_path" 2>/dev/null | grep -q "^$1$" && \
            { xray_error "端口 $1 已在 Xray 中使用"; return 1; }
    fi
    return 0
}

rand_port() {
    local n=0
    while [ $n -lt 100 ]; do
        local p=$((RANDOM % 55536 + 10000))
        xray_port_available "$p" 2>/dev/null && echo "$p" && return 0
        ((n++))
    done
    xray_error "无法生成可用端口"; return 1
}

is_valid_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9-]{1,63}(\.[a-zA-Z0-9-]{1,63})+$ ]] && [[ "$1" != *--* ]]
}

show_port_usage() {
    echo ""
    echo -e "${yellow}[当前端口占用]${none}"
    echo "──────────────────────────────────────"
    declare -A pp
    while IFS= read -r line; do
        [[ "$line" =~ LISTEN|UNCONN ]] || continue
        local port prog
        port=$(echo "$line" | awk '{print $5}' | grep -o ':[0-9]*$' | cut -d':' -f2)
        prog=$(echo "$line" | awk '{print $7}' | cut -d'"' -f2 2>/dev/null)
        [ -n "$port" ] && [ -n "$prog" ] && [ "$prog" != "-" ] && \
            pp[$prog]="${pp[$prog]:+${pp[$prog]}|}${port}"
    done < <(ss -tulnp 2>/dev/null)
    for prog in $(printf '%s\n' "${!pp[@]}" | sort); do
        printf "  %-15s %s\n" "$prog" "${pp[$prog]}"
    done
    echo "──────────────────────────────────────"
    echo ""
}

prompt_vless() {
    local -n _port="$1" _uuid="$2" _sni="$3" _tag="$4"
    show_port_usage
    while true; do
        read -p " -> VLESS 端口 (留空随机): " _port
        if [ -z "$_port" ]; then
            _port=$(rand_port) && echo -e "${green}随机端口: ${cyan}${_port}${none}" && break
        else
            xray_port_available "$_port" && break
        fi
    done
    read -p " -> UUID (留空自动生成): " _uuid
    [ -z "$_uuid" ] && _uuid=$(cat /proc/sys/kernel/random/uuid) && \
        echo -e "${yellow}UUID: ${cyan}${_uuid:0:8}...${none}"
    echo ""
    echo -e "${cyan}选择 SNI 域名:${none}"
    echo "  1. addons.mozilla.org  [默认]"
    echo "  2. updates.cdn-apple.com"
    echo "  3. 自定义"
    read -p "选择 [1]: " sc; sc=${sc:-1}
    case "$sc" in
        1) _sni="addons.mozilla.org" ;;
        2) _sni="updates.cdn-apple.com" ;;
        3) while true; do
               read -p " -> 自定义 SNI: " _sni
               is_valid_domain "$_sni" && break || xray_error "域名格式无效"
           done ;;
        *) _sni="addons.mozilla.org" ;;
    esac
    echo -e "${yellow}SNI: ${cyan}${_sni}${none}"
    read -p " -> 节点名称 (留空用端口号): " _tag
    [ -z "$_tag" ] && _tag="VLESS-Reality-${_port}"
}

prompt_ss() {
    local -n _port="$1" _pass="$2" _tag="$3"
    show_port_usage
    while true; do
        read -p " -> SS 端口 (留空随机): " _port
        if [ -z "$_port" ]; then
            _port=$(rand_port) && echo -e "${green}随机端口: ${cyan}${_port}${none}" && break
        else
            xray_port_available "$_port" && break
        fi
    done
    read -p " -> 密钥 (留空自动生成): " _pass
    [ -z "$_pass" ] && _pass=$(generate_ss_key) && \
        echo -e "${yellow}随机密钥: ${cyan}${_pass:0:4}...${none}"
    read -p " -> 节点名称 (留空用端口号): " _tag
    [ -z "$_tag" ] && _tag="Shadowsocks-2022-${_port}"
}

xray_view_all_info() {
    [ ! -f "$xray_config_path" ] && { xray_error "配置文件不存在"; return; }
    clear
    echo -e "${cyan} Xray 配置及订阅信息${none}"; draw_divider
    local ip; ip=$(get_public_ip)
    [ -z "$ip" ] && { xray_error "无法获取公网 IP"; return 1; }
    local links=()
    local dip; dip=$ip && [[ $ip =~ ":" ]] && dip="[$ip]"

    local vc; vc=$(jq '[.inbounds[] | select(.protocol == "vless")] | length' "$xray_config_path" 2>/dev/null || echo 0)
    for ((i=0; i<vc; i++)); do
        local vi uuid port domain pub sid tag enc
        vi=$(jq --argjson i "$i" '[.inbounds[] | select(.protocol == "vless")][$i]' "$xray_config_path")
        uuid=$(echo "$vi" | jq -r '.settings.clients[0].id')
        port=$(echo "$vi" | jq -r '.port')
        domain=$(echo "$vi" | jq -r '.streamSettings.realitySettings.serverNames[0]')
        pub=$(echo "$vi"  | jq -r '.streamSettings.realitySettings.publicKey')
        sid=$(echo "$vi"  | jq -r '.streamSettings.realitySettings.shortIds[0]')
        tag=$(echo "$vi"  | jq -r '.tag // "VLESS-" + (.port | tostring)')
        [ -z "$pub" ] && continue
        enc=$(echo "$tag" | sed 's/ /%20/g')
        links+=("vless://${uuid}@${dip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=chrome&pbk=${pub}&sid=${sid}#${enc}")
        [ $i -gt 0 ] && echo ""
        echo -e "${green} [ VLESS-Reality - ${tag} ]${none}"
        printf "    %-9s ${cyan}%s${none}\n" "服务器:" "$ip"
        printf "    %-9s ${cyan}%s${none}\n" "端口:" "$port"
        printf "    %-9s ${cyan}%s...%s${none}\n" "UUID:" "${uuid:0:8}" "${uuid: -4}"
        printf "    %-9s ${cyan}%s${none}\n" "SNI:" "$domain"
        printf "    %-9s ${cyan}%s...${none}\n" "PublicKey:" "${pub:0:16}"
        printf "    %-9s ${cyan}%s${none}\n" "ShortId:" "$sid"
    done

    local sc; sc=$(jq '[.inbounds[] | select(.protocol == "shadowsocks")] | length' "$xray_config_path" 2>/dev/null || echo 0)
    for ((i=0; i<sc; i++)); do
        local si port method pass tag enc b64
        si=$(jq --argjson i "$i" '[.inbounds[] | select(.protocol == "shadowsocks")][$i]' "$xray_config_path")
        port=$(echo "$si" | jq -r '.port')
        method=$(echo "$si" | jq -r '.settings.method')
        pass=$(echo "$si" | jq -r '.settings.password')
        tag=$(echo "$si" | jq -r '.tag // "Shadowsocks-2022-" + (.port | tostring)')
        enc=$(echo "$tag" | sed 's/ /%20/g')
        b64=$(echo -n "${method}:${pass}" | base64 -w 0)
        links+=("ss://${b64}@${ip}:${port}#${enc}")
        echo ""
        echo -e "${green} [ Shadowsocks-2022 - ${tag} ]${none}"
        printf "    %-9s ${cyan}%s${none}\n" "服务器:" "$ip"
        printf "    %-9s ${cyan}%s${none}\n" "端口:" "$port"
        printf "    %-9s ${cyan}%s${none}\n" "加密:" "$method"
        printf "    %-9s ${cyan}%s...%s${none}\n" "密码:" "${pass:0:4}" "${pass: -4}"
    done

    if [ ${#links[@]} -gt 0 ]; then
        draw_divider
        printf "%s\n" "${links[@]}" > ~/xray_subscription_info.txt
        xray_success "订阅链接已保存到: ~/xray_subscription_info.txt"
        echo -e "\n${yellow} --- 订阅链接 ---${none}\n"
        for l in "${links[@]}"; do echo -e "${cyan}${l}${none}"; echo; done
        draw_divider
    fi
}

do_install_vless() {
    [ -z "$(get_public_ip)" ] && { xray_error "无法获取公网 IP"; return 1; }
    xray_core_install || return 1
    xray_info "生成 Reality 密钥对..."
    local kp priv pub
    kp=$("$xray_binary_path" x25519)
    priv=$(echo "$kp" | awk '/PrivateKey:/ {print $2}')
    pub=$(echo "$kp"  | awk '/PublicKey/  {print $NF}')
    [ -z "$priv" ] || [ -z "$pub" ] && { xray_error "生成密钥失败！"; return 1; }
    local vi; vi=$(build_vless_inbound "$1" "$2" "$3" "$priv" "$pub" "$4")
    xray_write_config "[$vi]" || return 1
    xray_restart || return 1
    xray_success "VLESS-Reality 安装成功！"
    xray_view_all_info
}

do_install_ss() {
    [ -z "$(get_public_ip)" ] && { xray_error "无法获取公网 IP"; return 1; }
    xray_core_install || return 1
    local si; si=$(build_ss_inbound "$1" "$2" "$3")
    xray_write_config "[$si]" || return 1
    xray_restart || return 1
    xray_success "Shadowsocks-2022 安装成功！"
    xray_view_all_info
}

do_install_dual() {
    [ -z "$(get_public_ip)" ] && { xray_error "无法获取公网 IP"; return 1; }
    xray_core_install || return 1
    xray_info "生成 Reality 密钥对..."
    local kp priv pub
    kp=$("$xray_binary_path" x25519)
    priv=$(echo "$kp" | awk '/PrivateKey:/ {print $2}')
    pub=$(echo "$kp"  | awk '/PublicKey/  {print $NF}')
    [ -z "$priv" ] || [ -z "$pub" ] && { xray_error "生成密钥失败！"; return 1; }
    local vi si
    vi=$(build_vless_inbound "$1" "$2" "$3" "$priv" "$pub" "$4")
    si=$(build_ss_inbound "$5" "$6" "$7")
    xray_write_config "[$vi, $si]" || return 1
    xray_restart || return 1
    xray_success "双协议安装成功！"
    xray_view_all_info
}

xray_install_menu() {
    local ve="" se=""
    if [ -f "$xray_config_path" ]; then
        ve=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path" 2>/dev/null || true)
        se=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path" 2>/dev/null || true)
    fi
    draw_xray_header
    if [ -n "$ve" ] && [ -n "$se" ]; then
        xray_success "已安装双协议，如需重装请先卸载再重新安装"
        return
    elif [ -n "$ve" ] && [ -z "$se" ]; then
        xray_info "已安装 VLESS-Reality"
        printf "  ${green}%-2s${none} %s\n" "1." "追加 Shadowsocks-2022"
        printf "  ${red}%-2s${none}   %s\n" "2." "覆盖重装 VLESS-Reality"
        printf "  ${yellow}%-2s${none} %s\n" "0." "返回"
        read -p " 选项: " c
        if [ "$c" = "1" ]; then
            local ve_raw; ve_raw=$(jq '.inbounds[] | select(.protocol == "vless")' "$xray_config_path")
            [ -z "$(get_public_ip)" ] && { xray_error "无法获取公网 IP"; return; }
            local sp spass st; prompt_ss sp spass st
            local si; si=$(build_ss_inbound "$sp" "$spass" "$st")
            xray_write_config "[$ve_raw, $si]" && xray_restart && xray_success "追加成功！" && xray_view_all_info
        elif [ "$c" = "2" ]; then
            local vp vu vd vt; prompt_vless vp vu vd vt; do_install_vless "$vp" "$vu" "$vd" "$vt"
        fi
    elif [ -z "$ve" ] && [ -n "$se" ]; then
        xray_info "已安装 Shadowsocks-2022"
        printf "  ${green}%-2s${none} %s\n" "1." "追加 VLESS-Reality"
        printf "  ${red}%-2s${none}   %s\n" "2." "覆盖重装 Shadowsocks-2022"
        printf "  ${yellow}%-2s${none} %s\n" "0." "返回"
        read -p " 选项: " c
        if [ "$c" = "1" ]; then
            local se_raw; se_raw=$(jq '.inbounds[] | select(.protocol == "shadowsocks")' "$xray_config_path")
            [ -z "$(get_public_ip)" ] && { xray_error "无法获取公网 IP"; return; }
            local vp vu vd vt; prompt_vless vp vu vd vt
            xray_info "生成密钥对..."
            local kp priv pub
            kp=$("$xray_binary_path" x25519)
            priv=$(echo "$kp" | awk '/PrivateKey:/ {print $2}')
            pub=$(echo "$kp"  | awk '/PublicKey/  {print $NF}')
            local vi; vi=$(build_vless_inbound "$vp" "$vu" "$vd" "$priv" "$pub" "$vt")
            xray_write_config "[$vi, $se_raw]" && xray_restart && xray_success "追加成功！" && xray_view_all_info
        elif [ "$c" = "2" ]; then
            local sp spass st; prompt_ss sp spass st; do_install_ss "$sp" "$spass" "$st"
        fi
    else
        draw_xray_header
        printf "  ${green}%-2s${none} %s\n" "1." "仅 VLESS-Reality"
        printf "  ${cyan}%-2s${none}  %s\n" "2." "仅 Shadowsocks-2022"
        printf "  ${yellow}%-2s${none} %s\n" "3." "双协议"
        printf "  ${magenta}%-2s${none} %s\n" "0." "返回"
        read -p " 选项 [0-3]: " c
        case "$c" in
            1) local vp vu vd vt; prompt_vless vp vu vd vt; do_install_vless "$vp" "$vu" "$vd" "$vt" ;;
            2) local sp spass st; prompt_ss sp spass st; do_install_ss "$sp" "$spass" "$st" ;;
            3) local vp vu vd vt; prompt_vless vp vu vd vt
               local sp spass st; prompt_ss sp spass st
               do_install_dual "$vp" "$vu" "$vd" "$vt" "$sp" "$spass" "$st" ;;
        esac
    fi
}

xray_add_new_vless() {
    [ ! -f "$xray_binary_path" ] && { xray_error "Xray 未安装"; return; }
    [ -z "$(get_public_ip)" ] && { xray_error "无法获取公网 IP"; return; }
    local vp vu vd vt; prompt_vless vp vu vd vt
    xray_info "生成密钥对..."
    local kp priv pub
    kp=$("$xray_binary_path" x25519)
    priv=$(echo "$kp" | awk '/PrivateKey:/ {print $2}')
    pub=$(echo "$kp"  | awk '/PublicKey/  {print $NF}')
    [ -z "$priv" ] || [ -z "$pub" ] && { xray_error "生成密钥失败！"; return; }
    local vi; vi=$(build_vless_inbound "$vp" "$vu" "$vd" "$priv" "$pub" "$vt")
    local existing_inbounds
    [ -f "$xray_config_path" ] && existing_inbounds=$(jq '.inbounds' "$xray_config_path") || existing_inbounds="[]"
    xray_write_config "$(echo "$existing_inbounds" | jq ". += [$vi]")" && \
        xray_restart && xray_success "新 VLESS 节点添加成功！" && xray_view_all_info
}

xray_add_new_ss() {
    [ ! -f "$xray_binary_path" ] && { xray_error "Xray 未安装"; return; }
    local sp spass st; prompt_ss sp spass st
    local si; si=$(build_ss_inbound "$sp" "$spass" "$st")
    local existing_inbounds
    [ -f "$xray_config_path" ] && existing_inbounds=$(jq '.inbounds' "$xray_config_path") || existing_inbounds="[]"
    xray_write_config "$(echo "$existing_inbounds" | jq ". += [$si]")" && \
        xray_restart && xray_success "新 SS 节点添加成功！" && xray_view_all_info
}

xray_modify_vless() {
    [ ! -f "$xray_config_path" ] && { xray_error "配置文件不存在"; return; }
    local vc; vc=$(jq '[.inbounds[] | select(.protocol == "vless")] | length' "$xray_config_path")
    [ "$vc" -eq 0 ] && { xray_error "未找到 VLESS 节点"; return; }
    draw_xray_header; echo -e "${cyan} 选择要修改的 VLESS 节点${none}"; draw_divider
    local idx=1
    while IFS='|' read -r p u t; do
        printf "  ${green}%s${none} 端口:${cyan}%-6s${none} UUID:${cyan}%s...%s${none} %s\n" "${idx}." "$p" "${u:0:8}" "${u: -4}" "$t"
        ((idx++))
    done < <(jq -r '.inbounds[] | select(.protocol == "vless") | "\(.port)|\(.settings.clients[0].id)|\(.tag // "未命名")"' "$xray_config_path")
    printf "  ${yellow}%s${none} 返回\n" "0."; draw_divider
    read -p " 选择编号 [0-$vc]: " c
    [ "$c" = "0" ] && return
    [[ ! "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "$vc" ] && { xray_error "无效选项"; return; }
    local ni=$((c-1))
    local cur_port cur_uuid cur_sni cur_priv cur_pub cur_sid cur_tag
    cur_port=$(jq --argjson i "$ni" '[.inbounds[] | select(.protocol == "vless")][$i].port' "$xray_config_path")
    cur_uuid=$(jq -r --argjson i "$ni" '[.inbounds[] | select(.protocol == "vless")][$i].settings.clients[0].id' "$xray_config_path")
    cur_sni=$(jq -r --argjson i "$ni" '[.inbounds[] | select(.protocol == "vless")][$i].streamSettings.realitySettings.serverNames[0]' "$xray_config_path")
    cur_priv=$(jq -r --argjson i "$ni" '[.inbounds[] | select(.protocol == "vless")][$i].streamSettings.realitySettings.privateKey' "$xray_config_path")
    cur_pub=$(jq -r --argjson i "$ni" '[.inbounds[] | select(.protocol == "vless")][$i].streamSettings.realitySettings.publicKey' "$xray_config_path")
    cur_sid=$(jq -r --argjson i "$ni" '[.inbounds[] | select(.protocol == "vless")][$i].streamSettings.realitySettings.shortIds[0]' "$xray_config_path")
    cur_tag=$(jq -r --argjson i "$ni" '[.inbounds[] | select(.protocol == "vless")][$i].tag // ""' "$xray_config_path")
    echo ""
    echo -e "${gl_huang}回车保持不变${gl_bai}"
    echo ""
    # 端口
    local new_port
    while true; do
        read -p " -> 端口 [${cur_port}]: " new_port
        new_port="${new_port:-$cur_port}"
        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
            echo -e "${gl_hong}❌ 无效端口${gl_bai}"; continue
        fi
        [ "$new_port" != "$cur_port" ] && ! xray_port_available "$new_port" && continue
        break
    done
    # UUID
    local new_uuid
    read -p " -> UUID [回车保持]: " new_uuid
    if [ -z "$new_uuid" ]; then
        new_uuid="$cur_uuid"
    fi
    # SNI
    local new_sni
    echo -e "${cyan}SNI 选择:${none}"
    echo "  1. addons.mozilla.org   2. updates.cdn-apple.com   3. 自定义   [回车保持: ${cur_sni}]"
    read -p " 选择: " sc
    case "$sc" in
        1) new_sni="addons.mozilla.org" ;;
        2) new_sni="updates.cdn-apple.com" ;;
        3) while true; do
               read -p " -> 自定义 SNI: " new_sni
               is_valid_domain "$new_sni" && break || xray_error "域名格式无效"
           done ;;
        *) new_sni="$cur_sni" ;;
    esac
    # 是否重新生成密钥对
    local new_priv="$cur_priv" new_pub="$cur_pub" new_sid="$cur_sid"
    read -p " -> 重新生成密钥对？(y/N): " rk
    if [[ "$rk" =~ ^[Yy]$ ]]; then
        xray_info "生成新密钥对..."
        local kp; kp=$("$xray_binary_path" x25519)
        new_priv=$(echo "$kp" | awk '/PrivateKey:/ {print $2}')
        new_pub=$(echo "$kp"  | awk '/PublicKey/  {print $NF}')
        new_sid=$(generate_shortid)
        echo -e "${green}新 PublicKey: ${cyan}${new_pub:0:16}...${none}"
    fi
    # Tag
    local new_tag
    read -p " -> 节点名称 [${cur_tag}]: " new_tag
    [ -z "$new_tag" ] && new_tag="$cur_tag"
    # 构建新 inbound
    local new_vi; new_vi=$(build_vless_inbound "$new_port" "$new_uuid" "$new_sni" "$new_priv" "$new_pub" "$new_tag" "$new_sid")
    # 替换对应 inbound
    local updated_inbounds
    updated_inbounds=$(jq --argjson i "$ni" --argjson v "$new_vi" \
        '[.inbounds[] | select(.protocol == "vless")] | .[$i] = $v' "$xray_config_path")
    local all_inbounds
    all_inbounds=$(jq --argjson u "$updated_inbounds" \
        '[.inbounds[] | select(.protocol != "vless")] + $u' "$xray_config_path")
    xray_write_config "$all_inbounds" && xray_restart && xray_success "VLESS 节点修改成功！" && xray_view_all_info
}

xray_modify_ss() {
    [ ! -f "$xray_config_path" ] && { xray_error "配置文件不存在"; return; }
    local sc; sc=$(jq '[.inbounds[] | select(.protocol == "shadowsocks")] | length' "$xray_config_path")
    [ "$sc" -eq 0 ] && { xray_error "未找到 Shadowsocks-2022 节点"; return; }
    draw_xray_header; echo -e "${cyan} 选择要修改的 SS 节点${none}"; draw_divider
    local idx=1
    while IFS='|' read -r p pw t; do
        printf "  ${green}%s${none} 端口:${cyan}%-6s${none} 密码:${cyan}%s...%s${none} %s\n" "${idx}." "$p" "${pw:0:4}" "${pw: -4}" "$t"
        ((idx++))
    done < <(jq -r '.inbounds[] | select(.protocol == "shadowsocks") | "\(.port)|\(.settings.password)|\(.tag // "未命名")"' "$xray_config_path")
    printf "  ${yellow}%s${none} 返回\n" "0."; draw_divider
    read -p " 选择编号 [0-$sc]: " c
    [ "$c" = "0" ] && return
    [[ ! "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "$sc" ] && { xray_error "无效选项"; return; }
    local ni=$((c-1))
    local cur_port cur_pass cur_tag
    cur_port=$(jq --argjson i "$ni" '[.inbounds[] | select(.protocol == "shadowsocks")][$i].port' "$xray_config_path")
    cur_pass=$(jq -r --argjson i "$ni" '[.inbounds[] | select(.protocol == "shadowsocks")][$i].settings.password' "$xray_config_path")
    cur_tag=$(jq -r --argjson i "$ni" '[.inbounds[] | select(.protocol == "shadowsocks")][$i].tag // ""' "$xray_config_path")
    echo ""
    echo -e "${gl_huang}回车保持不变${gl_bai}"
    echo ""
    local new_port
    while true; do
        read -p " -> 端口 [${cur_port}]: " new_port
        new_port="${new_port:-$cur_port}"
        if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1 ] || [ "$new_port" -gt 65535 ]; then
            echo -e "${gl_hong}❌ 无效端口${gl_bai}"; continue
        fi
        [ "$new_port" != "$cur_port" ] && ! xray_port_available "$new_port" && continue
        break
    done
    local new_pass
    read -p " -> 密钥 [回车保持]: " new_pass
    if [ -z "$new_pass" ]; then
        new_pass="$cur_pass"
    fi
    read -p " -> 随机生成新密钥？(y/N): " rk
    [[ "$rk" =~ ^[Yy]$ ]] && new_pass=$(generate_ss_key) && echo -e "${green}新密钥: ${cyan}${new_pass:0:4}...${none}"
    local new_tag
    read -p " -> 节点名称 [${cur_tag}]: " new_tag
    [ -z "$new_tag" ] && new_tag="$cur_tag"
    local new_si; new_si=$(build_ss_inbound "$new_port" "$new_pass" "$new_tag")
    local updated_inbounds
    updated_inbounds=$(jq --argjson i "$ni" --argjson s "$new_si" \
        '[.inbounds[] | select(.protocol == "shadowsocks")] | .[$i] = $s' "$xray_config_path")
    local all_inbounds
    all_inbounds=$(jq --argjson u "$updated_inbounds" \
        '[.inbounds[] | select(.protocol != "shadowsocks")] + $u' "$xray_config_path")
    xray_write_config "$all_inbounds" && xray_restart && xray_success "SS 节点修改成功！" && xray_view_all_info
}

xray_delete_vless() {
    [ ! -f "$xray_config_path" ] && { xray_error "配置文件不存在"; return; }
    local vc; vc=$(jq '[.inbounds[] | select(.protocol == "vless")] | length' "$xray_config_path")
    [ "$vc" -eq 0 ] && { xray_error "未找到 VLESS 节点"; return; }
    draw_xray_header; echo -e "${cyan} VLESS 节点列表${none}"; draw_divider
    local idx=1
    while IFS='|' read -r p u t; do
        printf "  ${green}%s${none} 端口:${cyan}%-6s${none} UUID:${cyan}%s...%s${none} %s\n" "${idx}." "$p" "${u:0:8}" "${u: -4}" "$t"
        ((idx++))
    done < <(jq -r '.inbounds[] | select(.protocol == "vless") | "\(.port)|\(.settings.clients[0].id)|\(.tag // "未命名")"' "$xray_config_path")
    printf "  ${yellow}%s${none} 返回\n" "0."; draw_divider
    read -p " 选择编号 [0-$vc]: " c
    [ "$c" = "0" ] && return
    [[ ! "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "$vc" ] && { xray_error "无效选项"; return; }
    local ni; ni=$(jq --argjson idx "$((c-1))" \
        '([.inbounds[] | select(.protocol == "vless")] | del(.[$idx])) as $f | [.inbounds[] | select(.protocol != "vless")] + $f' \
        "$xray_config_path")
    xray_write_config "$ni" && xray_restart && xray_success "删除成功！" && xray_view_all_info
}

xray_delete_ss() {
    [ ! -f "$xray_config_path" ] && { xray_error "配置文件不存在"; return; }
    local sc; sc=$(jq '[.inbounds[] | select(.protocol == "shadowsocks")] | length' "$xray_config_path")
    [ "$sc" -eq 0 ] && { xray_error "未找到 Shadowsocks-2022 节点"; return; }
    draw_xray_header; echo -e "${cyan} Shadowsocks-2022 节点列表${none}"; draw_divider
    local idx=1
    while IFS='|' read -r p pw t; do
        printf "  ${green}%s${none} 端口:${cyan}%-6s${none} 密码:${cyan}%s...%s${none} %s\n" "${idx}." "$p" "${pw:0:4}" "${pw: -4}" "$t"
        ((idx++))
    done < <(jq -r '.inbounds[] | select(.protocol == "shadowsocks") | "\(.port)|\(.settings.password)|\(.tag // "未命名")"' "$xray_config_path")
    printf "  ${yellow}%s${none} 返回\n" "0."; draw_divider
    read -p " 选择编号 [0-$sc]: " c
    [ "$c" = "0" ] && return
    [[ ! "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "$sc" ] && { xray_error "无效选项"; return; }
    local ni; ni=$(jq --argjson idx "$((c-1))" \
        '([.inbounds[] | select(.protocol == "shadowsocks")] | del(.[$idx])) as $f | [.inbounds[] | select(.protocol != "shadowsocks")] + $f' \
        "$xray_config_path")
    xray_write_config "$ni" && xray_restart && xray_success "删除成功！" && xray_view_all_info
}

xray_update() {
    [ ! -f "$xray_binary_path" ] && { xray_error "Xray 未安装"; return; }
    xray_info "更新 Xray..."
    run_xray_install_script "install" && xray_restart && xray_success "更新成功！"
}

xray_uninstall() {
    [ ! -f "$xray_binary_path" ] && { xray_error "Xray 未安装"; return; }
    read -p "$(echo -e "${yellow}确定卸载 Xray？[Y/n]: ${none}")" c
    [[ "$c" =~ ^[nN]$ ]] && { xray_info "已取消"; return; }
    run_xray_install_script "remove --purge" && { rm -f ~/xray_subscription_info.txt; xray_success "Xray 已卸载"; }
}

xray_routing_menu() {
    clear
    [ ! -f "$xray_config_path" ] && { xray_error "配置文件不存在，请先安装 Xray"; break_end; return; }
    local has_routing; has_routing=$(jq -r '.routing // empty' "$xray_config_path" 2>/dev/null)
    if [ -n "$has_routing" ]; then
        echo -e "${green}✓ 路由过滤已启用${none}（屏蔽广告/色情/missav）"
        echo ""; echo -e "${cyan}1.${none} 禁用  ${red}0.${none} 返回"
        read -p " 选项: " c
        [ "$c" = "1" ] && {
            local ib; ib=$(jq -c '.inbounds' "$xray_config_path")
            xray_write_config "$ib" "false" && xray_restart && xray_success "路由过滤已禁用！"
        }
    else
        echo -e "${yellow}✗ 路由过滤未启用${none}"
        echo ""; echo -e "${green}1.${none} 启用  ${red}0.${none} 返回"
        read -p " 选项: " c
        [ "$c" = "1" ] && {
            if [ ! -f "/usr/local/share/xray/geosite.dat" ]; then
                xray_info "下载 GeoSite..."
                run_xray_install_script "install-geodata" || true
            fi
            local ib; ib=$(jq -c '.inbounds' "$xray_config_path")
            xray_write_config "$ib" "true" && xray_restart && xray_success "路由过滤已启用！"
        }
    fi
    break_end
}

menu_xray() {
    xray_pre_check || { break_end; return; }
    while true; do
        draw_xray_header
        printf "  ${green}%-3s${none} %-40s\n" "1." "安装 Xray（VLESS/Shadowsocks）"
        draw_divider
        echo -e "${cyan}[VLESS 管理]${none}"
        printf "  ${cyan}%-3s${none} %-40s\n" "2." "增加 VLESS 节点"
        printf "  ${yellow}%-3s${none} %-40s\n" "3." "修改 VLESS 节点"
        printf "  ${magenta}%-3s${none} %-40s\n" "4." "删除 VLESS 节点"
        draw_divider
        echo -e "${cyan}[Shadowsocks-2022 管理]${none}"
        printf "  ${cyan}%-3s${none} %-40s\n" "5." "增加 Shadowsocks-2022 节点"
        printf "  ${yellow}%-3s${none} %-40s\n" "6." "修改 Shadowsocks-2022 节点"
        printf "  ${magenta}%-3s${none} %-40s\n" "7." "删除 Shadowsocks-2022 节点"
        draw_divider
        echo -e "${cyan}[Xray 服务]${none}"
        printf "  ${green}%-3s${none} %-40s\n" "8." "更新 Xray"
        printf "  ${red}%-3s${none} %-40s\n" "9." "卸载 Xray"
        printf "  ${cyan}%-3s${none} %-40s\n" "10." "重启 Xray"
        printf "  ${magenta}%-3s${none} %-40s\n" "11." "查看 Xray 日志"
        printf "  ${yellow}%-3s${none} %-40s\n" "12." "查看订阅信息"
        draw_divider
        printf "  ${green}%-3s${none} %-40s ⭐\n" "13." "路由过滤规则管理"
        draw_divider
        printf "  ${red}%-3s${none} %-40s\n" "0." "返回主菜单"
        draw_divider
        read -p " 请输入选项 [0-13]: " choice
        case "$choice" in
            1)  xray_install_menu; press_any_key ;;
            2)  xray_add_new_vless; press_any_key ;;
            3)  xray_modify_vless; press_any_key ;;
            4)  xray_delete_vless; press_any_key ;;
            5)  xray_add_new_ss; press_any_key ;;
            6)  xray_modify_ss; press_any_key ;;
            7)  xray_delete_ss; press_any_key ;;
            8)  xray_update; press_any_key ;;
            9)  xray_uninstall; press_any_key ;;
            10) xray_restart; press_any_key ;;
            11) clear; echo -e "${yellow}按 Ctrl+C 退出${none}"; journalctl -u xray -f --no-pager ;;
            12) xray_view_all_info; press_any_key ;;
            13) xray_routing_menu ;;
            0)  return ;;
            *)  xray_error "无效选项"; sleep 1 ;;
        esac
    done
}

#=============================================================================
# 主菜单
#=============================================================================
main_menu() {
    while true; do
        clear
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo -e "${gl_kjlan}   Xray 多协议 + SOCKS5 代理 一体化管理工具${gl_bai}"
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        if [ -f "$xray_binary_path" ] && [ -x "$xray_binary_path" ]; then
            local xv; xv=$("$xray_binary_path" version 2>/dev/null | head -1 | awk '{print $2}')
            systemctl is-active --quiet xray 2>/dev/null && \
                echo -e "  Xray:   ${gl_lv}✅ 运行中${gl_bai} v${xv}" || \
                echo -e "  Xray:   ${gl_hong}❌ 未运行${gl_bai} v${xv}"
        else
            echo -e "  Xray:   ${gl_hui}未安装${gl_bai}"
        fi
        if [ -f "$SOCKS5_CONFIG_FILE" ]; then
            local sp su
            sp=$(grep -o '"listen_port"[[:space:]]*:[[:space:]]*[0-9]*' "$SOCKS5_CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*$')
            su=$(grep -o '"username"[[:space:]]*:[[:space:]]*"[^"]*"' "$SOCKS5_CONFIG_FILE" 2>/dev/null | sed 's/.*"//;s/"$//')
            systemctl is-active --quiet "$SOCKS5_SERVICE_NAME" 2>/dev/null && \
                echo -e "  SOCKS5: ${gl_lv}✅ 运行中${gl_bai} :${sp} ${su}" || \
                echo -e "  SOCKS5: ${gl_hong}❌ 未运行${gl_bai}"
        else
            echo -e "  SOCKS5: ${gl_hui}未部署${gl_bai}"
        fi
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "  ${gl_lv}1.${gl_bai} 星辰大海 Xray 一键多协议"
        echo -e "     ${gl_hui}VLESS-Reality / Shadowsocks-2022 / 路由过滤${gl_bai}"
        echo ""
        echo -e "  ${gl_lv}2.${gl_bai} Sing-box SOCKS5 代理管理"
        echo -e "     ${gl_hui}一键部署 / 修改 / 删除 / 查看${gl_bai}"
        echo ""
        echo -e "${gl_kjlan}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${gl_bai}"
        echo ""
        echo -e "  ${gl_hong}0.${gl_bai} 退出"
        echo ""
        read -e -p "请输入选项 [0-2]: " choice
        case "$choice" in
            1) menu_xray ;;
            2) menu_socks5 ;;
            0) echo -e "${gl_lv}再见！${gl_bai}"; exit 0 ;;
            *) echo -e "${gl_hong}❌ 无效选项${gl_bai}"; sleep 1 ;;
        esac
    done
}

check_root
main_menu
