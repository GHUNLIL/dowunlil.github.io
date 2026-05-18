#!/bin/bash
# ============================================================
# 专线网络优化工具 v1
# wget -O bbr.sh https://raw.githubusercontent.com/GHUNLIL/dowunlil.github.io/main/bbr.sh && chmod +x bbr.sh && sudo bash bbr.sh
# 用法: sudo bash bbr.sh [命令]
# ============================================================

VERSION="v1.3"
UPDATE_URL="https://raw.githubusercontent.com/GHUNLIL/dowunlil.github.io/main/bbr.sh"
CONFIG_DIR="/etc/network-optimizer"
SYSCTL_CONF="$CONFIG_DIR/sysctl-optimize.conf"
PROFILE_CONF="$CONFIG_DIR/profile.conf"
GEO_CONF="$CONFIG_DIR/geo-whitelist.conf"
GEO_DIR="$CONFIG_DIR/geo-zones"
GEO_NFT="$CONFIG_DIR/geo-nftables.nft"
PF_NFT="$CONFIG_DIR/port-forward.nft"
PF_TABLE="port_forward"
GAME_NET_SCRIPT="/usr/local/sbin/gaming-net-apply.sh"
GAME_NET_SERVICE="/etc/systemd/system/gaming-net-apply.service"
GEO_IP_SOURCE="https://www.ipdeny.com/ipblocks/data/aggregated"

declare -A COUNTRY_NAMES=(
    [cn]="中国" [hk]="香港" [tw]="台湾" [jp]="日本" [kr]="韩国"
    [sg]="新加坡" [us]="美国" [gb]="英国" [de]="德国" [fr]="法国"
    [au]="澳大利亚" [ca]="加拿大" [ru]="俄罗斯" [th]="泰国" [my]="马来西亚"
    [vn]="越南" [id]="印尼" [ph]="菲律宾" [in]="印度" [nl]="荷兰"
)

[ "$(id -u)" -ne 0 ] && { echo "错误: 需要root权限"; exit 1; }
trap 'tput cnorm 2>/dev/null; stty sane 2>/dev/null; echo; exit 0' INT TERM

# ==================== 基础工具 ====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
WHITE='\033[1;37m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

rst() { tput cnorm 2>/dev/null; stty sane 2>/dev/null; }

self_update_once() {
    [ "${BBR_SELF_UPDATED:-0}" = "1" ] && return 0
    command -v wget >/dev/null 2>&1 || return 0

    local self tmp
    self=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    [ -n "$self" ] && [ -f "$self" ] && [ -w "$self" ] || return 0
    tmp="${self}.update.$$"

    echo -ne "  ${DIM}检查最新脚本版本(5秒超时)...${NC}"
    if timeout 5 wget -q -O "$tmp" "$UPDATE_URL" 2>/dev/null && [ -s "$tmp" ]; then
        chmod +x "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$self"
        echo -e "\r  ${GREEN}[OK]${NC} 已拉取最新脚本，继续执行...       "
        exec env BBR_SELF_UPDATED=1 bash "$self" "$@"
    else
        rm -f "$tmp" 2>/dev/null || true
        echo -e "\r  ${YELLOW}[!]${NC} 5秒内未拉取到最新版本，运行本地脚本。"
    fi
}

self_update_once "$@"

run_cmd() {
    local msg="$1"; shift
    echo -ne "  ${WHITE}${msg} ... ${NC}"
    "$@" && echo -e "${GREEN}[OK]${NC}" || { echo -e "${RED}[X]${NC}"; return 1; }
}

clamp() { local v=$1 lo=$2 hi=$3; [ $v -lt $lo ] && v=$lo; [ $v -gt $hi ] && v=$hi; echo $v; }

init_config_dir() { mkdir -p "$CONFIG_DIR"; }

detect_interface() {
    local i=$(ip route show default 2>/dev/null | awk '/default/{print $5;exit}')
    [ -z "$i" ] && i=$(ip -o link show up | awk -F': ' '!/lo|ifb|veth|docker|br-/{print $2;exit}')
    echo "$i"
}

get_meminfo() {
    MEM_TOTAL_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
    SWAP_TOTAL_KB=$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null)
    [ -z "$MEM_TOTAL_KB" ] && MEM_TOTAL_KB=2097152
    [ -z "$SWAP_TOTAL_KB" ] && SWAP_TOTAL_KB=0
    # Fix: 使用 MemAvailable 而非 MemTotal+Swap，避免高估可用内存
    MEM_AVAIL_KB=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
    [ -z "$MEM_AVAIL_KB" ] && MEM_AVAIL_KB=$(( MEM_TOTAL_KB / 2 ))
}

# 检测 BBR 版本 (仅识别，不管理)
# 写入: BBR_VER (bbr1/bbr3 字符串) BBR_VER_LABEL (含来源说明)
detect_bbr_version() {
    local kernel=$(uname -r)
    local algos=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    BBR_VER="unknown"
    BBR_VER_LABEL="未知"
    if echo "$kernel" | grep -qiE 'xanmod'; then
        BBR_VER="bbr3"; BBR_VER_LABEL="bbr3 (XanMod)"
    elif modinfo tcp_bbr 2>/dev/null | grep -qiE '^version:.*[3-9]'; then
        BBR_VER="bbr3"; BBR_VER_LABEL="bbr3"
    elif echo "$algos" | grep -qw "bbr3"; then
        BBR_VER="bbr3"; BBR_VER_LABEL="bbr3"
    elif echo "$algos" | grep -qw "bbr2"; then
