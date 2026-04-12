#!/bin/bash
# ============================================================
# 专线网络优化工具 v1.0
# 功能: BBR/sysctl优化 + 链路向导 + 国家白名单 + 端口监控
# 用法: sudo bash network-optimizer.sh [命令]
# ============================================================

VERSION="v3.0"
CONFIG_DIR="/etc/network-optimizer"
SYSCTL_CONF="$CONFIG_DIR/sysctl-optimize.conf"
PROFILE_CONF="$CONFIG_DIR/profile.conf"
GEO_CONF="$CONFIG_DIR/geo-whitelist.conf"
GEO_DIR="$CONFIG_DIR/geo-zones"
GEO_NFT="$CONFIG_DIR/geo-nftables.nft"
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
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m'
W='\033[1;37m' D='\033[2m' B='\033[1m' N='\033[0m'

_reset() { tput cnorm 2>/dev/null; stty sane 2>/dev/null; }
_clamp() { local v=$1; [ $v -lt $2 ] && v=$2; [ $v -gt $3 ] && v=$3; echo $v; }
_min() { [ $1 -lt $2 ] && echo $1 || echo $2; }
_max() { [ $1 -gt $2 ] && echo $1 || echo $2; }

run_cmd() {
    local msg="$1"; shift
    echo -ne "  ${W}${msg} ... ${N}"
    "$@" >/dev/null 2>&1 && echo -e "${G}✓${N}" || { echo -e "${R}✗${N}"; return 1; }
}

confirm() {
    _reset
    echo -ne "  ${Y}$1 [y/N]: ${N}"; read -r a
    [[ "$a" =~ ^[Yy]$ ]]
}

read_int() {
    local prompt="$1" default="$2" varname="$3"
    _reset
    while true; do
        [ -n "$default" ] && echo -ne "  ${W}${prompt} [默认${default}]: ${N}" || echo -ne "  ${W}${prompt}: ${N}"
        read val; [ -z "$val" ] && [ -n "$default" ] && val=$default
        [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ] && { eval "$varname=$val"; return; }
        echo -e "  ${R}请输入有效的正整数${N}"
    done
}

select_menu() {
    local title="$1"; shift; local opts=("$@") cnt=${#opts[@]} sel=0
    tput civis 2>/dev/null
    _draw() {
        for ((i=0;i<cnt+4;i++)); do tput cuu1; tput el; done 2>/dev/null
        echo ""; echo -e "  ${B}${C}$title${N}"; echo -e "  ${D}上下键选择，回车确认${N}"; echo ""
        for ((i=0;i<cnt;i++)); do
            [ $i -eq $sel ] && echo -e "  ${G}▸ ${W}${B}${opts[$i]}${N}" || echo -e "    ${D}${opts[$i]}${N}"
        done
    }
    for ((i=0;i<cnt+4;i++)); do echo ""; done; _draw
    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\x1b') read -rsn2 key
                case "$key" in
                    '[A') ((sel--)); [ $sel -lt 0 ] && sel=$((cnt-1)) ;;
                    '[B') ((sel++)); [ $sel -ge $cnt ] && sel=0 ;;
                esac; _draw ;;
            '') _reset; return $sel ;;
        esac
    done
}

detect_interface() {
    ip route show default 2>/dev/null | awk '/default/{print $5;exit}' ||
    ip -o link show up | awk -F': ' '!/lo|ifb|veth|docker|br-/{print $2;exit}'
}

# ==================== 多线路收集器 ====================
# 用法: collect_lines "方向标签" "名称提示" "带宽提示" "默认ping"
#       结果存入: CL_COUNT CL_MAX_BDP CL_MAX_BW CL_MAIN_BW CL_MAIN_RTT CL_HEADER
collect_lines() {
    local label="$1" name_hint="$2" bw_hint="$3" ping_def="$4"
    CL_COUNT=0; CL_MAX_BDP=0; CL_MAX_BW=0; CL_MAIN_BW=0; CL_MAIN_RTT=0; CL_HEADER=""

    while true; do
        CL_COUNT=$(( CL_COUNT + 1 ))
        echo -e "  ${B}${Y}── ${label} #${CL_COUNT} ──${N}"
        _reset
        echo -ne "  ${W}线路名称 (${name_hint}): ${N}"; read line_name
        [ -z "$line_name" ] && line_name="${label}${CL_COUNT}"

        local l_bw l_ping
        read_int "  ${bw_hint} (Mbps)" "" "l_bw"
        read_int "  单程ping (ms)" "$ping_def" "l_ping"
        local l_rtt=$(( l_ping * 2 )) l_bdp=$(( l_bw * l_rtt * 125 ))

        echo -e "  ${D}→ ${line_name}: ${l_bw}Mbps × ${l_rtt}ms = $(( l_bdp / 1024 ))KB BDP${N}"

        [ $l_bdp -gt $CL_MAX_BDP ] && { CL_MAX_BDP=$l_bdp; CL_MAIN_BW=$l_bw; CL_MAIN_RTT=$l_rtt; }
        [ $l_bw -gt $CL_MAX_BW ] && CL_MAX_BW=$l_bw
        [ $CL_COUNT -eq 1 ] && { CL_MAIN_BW=$l_bw; CL_MAIN_RTT=$l_rtt; }
        CL_HEADER="${CL_HEADER}
# ${label}${CL_COUNT}: ${line_name} | ${l_bw}Mbps | RTT ${l_rtt}ms | BDP $(( l_bdp / 1024 ))KB"

        echo ""
        confirm "还有更多${label}?" || break
        echo ""
    done
}

# ==================== 内存评估 ====================
check_memory_and_swap() {
    echo -e "\n  ${B}${C}━━━ 内存评估 ━━━${N}"
    local mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
    local swap_kb=$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null)
    : ${mem_kb:=2097152} ${swap_kb:=0}
    echo -e "  ${W}内存: ${B}$(( mem_kb / 1024 ))MB${N} | Swap: ${B}$(( swap_kb / 1024 ))MB${N}"

    if [ $(( (mem_kb + swap_kb) / 1024 )) -lt 1024 ]; then
        echo -e "  ${Y}⚠ 内存较小，建议创建Swap${N}"
        if confirm "自动创建2GB Swap?" && [ ! -f /swapfile ]; then
            fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
            chmod 600 /swapfile; mkswap /swapfile >/dev/null 2>&1; swapon /swapfile >/dev/null 2>&1
            grep -q /swapfile /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
            echo -e "  ${G}✓ Swap已创建${N}"
        fi
    else
        echo -e "  ${G}✓ 内存充足${N}"
    fi
}

# ================================================================
#                    BDP计算与参数生成
# ================================================================
# 全部动态计算 | 支持 1Mbps ~ 10Gbps | 参考Azure官方优化

calculate_and_generate() {
    local role="$1" up_bw="$2" up_rtt="$3" down_bw="$4" down_rtt="$5" header="$6"

    local bdp_up=$(( up_bw * up_rtt * 125 ))
    local bdp_down=$(( down_bw * down_rtt * 125 ))
    local bdp=$(_max $bdp_up $bdp_down)
    local bottleneck=$(_min $up_bw $down_bw)
    local max_bw=$(_max $up_bw $down_bw)

    # 缓冲区
    local def_val=$(_clamp $(( (bdp / 65536 + 1) * 65536 )) 131072 4194304)
    local max_val=$(( (bdp * 2 + 1048575) / 1048576 * 1048576 ))
    max_val=$(_clamp $max_val 1048576 134217728)
    [ $def_val -gt $(( max_val / 2 )) ] && def_val=$(( max_val / 2 ))

    # tcp_mem (基于实际内存)
    local mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
    local swap_kb=$(awk '/SwapTotal/{print $2}' /proc/meminfo 2>/dev/null)
    : ${mem_kb:=2097152} ${swap_kb:=0}
    local pages=$(( (mem_kb + swap_kb) / 4 ))
    local ml=$(( pages * 3 / 100 )) mp=$(( pages * 6 / 100 )) mh=$(( pages * 10 / 100 ))
    local need=$(( 50 * max_val * 2 / 4096 ))
    [ $mh -lt $need ] && mh=$need
    [ $mp -lt $(( mh * 6 / 10 )) ] && mp=$(( mh * 6 / 10 ))
    [ $ml -lt $(( mh * 3 / 10 )) ] && ml=$(( mh * 3 / 10 ))
    ml=$(_clamp $ml 65536 999999999); mp=$(_clamp $mp 98304 999999999); mh=$(_clamp $mh 131072 999999999)

    # 动态参数 (1Mbps ~ 10Gbps 连续缩放)
    local notsent=$(_clamp $(( bottleneck * 128 )) 8192 524288)
    local somaxconn=$(_clamp $(( max_bw * 66 )) 1024 65535)
    local syn_bl=$(_clamp $(( max_bw * 32 )) 512 262144)
    local nd_bl=$(_clamp $(( max_bw * 64 )) 1000 524288)
    local tw=$(_clamp $(( max_bw * 4000 )) 65536 16000000)
    local orphans=$(_clamp $(( max_bw * 128 )) 2048 524288)
    local fmax=$(_clamp $(( max_bw * 2048 )) 65536 10485760)
    local udp_buf=$(_clamp $(( bdp / 8 )) 16384 4194304)
    local udp_ml=$(( udp_buf * 2 / 4096 )); [ $udp_ml -lt 4096 ] && udp_ml=4096
    local fin=$(_clamp $(( 30 - max_bw / 200 )) 5 30)
    local optmem=$(_clamp $(( max_bw * 105 )) 65536 1048576)
    local budget=$(_clamp $(( max_bw + 300 )) 300 2000)
    local devwt=$(_clamp $(( max_bw / 16 + 32 )) 32 128)
    local bpoll=0 bread=0
    [ $max_bw -ge 50 ] && { bpoll=$(_clamp $(( max_bw / 20 )) 50 100); bread=$bpoll; }

    cat << EOF
# ============================================================
# ${role} - 网络优化配置
${header}
# BDP: ${up_bw}M×${up_rtt}ms=$(( bdp_up/1024 ))KB | ${down_bw}M×${down_rtt}ms=$(( bdp_down/1024 ))KB
# 缓冲: def=$(( def_val/1024 ))KB max=$(( max_val/1048576 ))MB | 内存$(( mem_kb/1024 ))MB
# 生成: $VERSION $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 缓冲区
net.core.rmem_max = $max_val
net.core.wmem_max = $max_val
net.core.rmem_default = $def_val
net.core.wmem_default = $def_val
net.ipv4.tcp_rmem = 4096 $def_val $max_val
net.ipv4.tcp_wmem = 4096 $def_val $max_val
net.core.optmem_max = $optmem
net.ipv4.tcp_mem = $ml $mp $mh

# 低延迟
net.ipv4.tcp_notsent_lowat = $notsent
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1

# 重传
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_frto = 0
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_retries2 = 15
net.ipv4.tcp_orphan_retries = 3

# ECN
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_ecn_fallback = 1

# MTU探测
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1460

# TCP行为
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = $fin

# Keepalive
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5

# 连接队列
net.core.somaxconn = $somaxconn
net.ipv4.tcp_max_syn_backlog = $syn_bl
net.core.netdev_max_backlog = $nd_bl
net.ipv4.tcp_max_tw_buckets = $tw
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_orphans = $orphans

# 网卡调度
net.core.netdev_budget = $budget
net.core.dev_weight = $devwt
net.core.busy_poll = $bpoll
net.core.busy_read = $bread

# UDP
net.ipv4.udp_rmem_min = $udp_buf
net.ipv4.udp_wmem_min = $udp_buf
net.ipv4.udp_mem = $udp_ml $(( udp_ml*2 )) $(( udp_ml*4 ))

# 转发
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# 安全
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# 系统
vm.swappiness = 1
vm.vfs_cache_pressure = 50
fs.file-max = $fmax
EOF
}

# ==================== 应用配置 ====================
apply_sysctl_config() {
    local role="$1" content="$2"
    echo -e "\n  ${B}${C}正在生成配置: $role${N}"

    if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        modprobe tcp_bbr 2>/dev/null
        grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null ||
            echo -e "  ${R}⚠ 内核不支持BBR (需>=4.9，当前$(uname -r))${N}"
    fi

    check_memory_and_swap
    mkdir -p "$CONFIG_DIR"
    echo "$content" > "$SYSCTL_CONF"
    echo "SYSCTL_PROFILE_NAME=\"$role\"" > "$PROFILE_CONF"
    [ ! -f "$CONFIG_DIR/sysctl-backup.conf" ] && sysctl -a > "$CONFIG_DIR/sysctl-backup.conf" 2>/dev/null
    ln -sf "$SYSCTL_CONF" /etc/sysctl.d/99-network-optimize.conf
    echo -e "  ${G}✓${N} 配置已写入"

    if confirm "立即应用?"; then
        local err=$(sysctl --system 2>&1 | grep -i "error\|cannot\|invalid" || true)
        [ -n "$err" ] && { echo -e "  ${Y}⚠ 部分异常:${N}"; echo "$err" | head -3 | sed 's/^/    /'; }
        echo -e "  ${G}✓${N} 已生效 | $(sysctl -n net.ipv4.tcp_congestion_control) | $(sysctl -n net.core.default_qdisc)"
    else
        echo -e "  ${D}已保存，sysctl --system 手动生效${N}"
    fi
    echo ""
}

# ==================== 链路向导 ====================
wizard_main() {
    echo -e "\n  ${B}${C}━━━ BBR网络优化 - 链路向导 ━━━${N}"
    echo -e "  ${D}用户 → 前置 → IX专线 → 国际转发 → 落地 → 目标${N}\n"

    select_menu "选择要优化的服务器" \
        "前置服务器 (用户接入点)" "IX专线服务器 (专线中转)" \
        "国际转发/线路服务器 (跨国中继)" "落地服务器 (最终出口)" "返回"

    case $? in 0) wizard_frontend;; 1) wizard_ix;; 2) wizard_relay;; 3) wizard_landing;; esac
}

wizard_frontend() {
    echo -e "\n  ${B}${C}━━━ ① 前置服务器 ━━━${N}\n"
    local up_local up_remote up_ping
    read_int "本机上行带宽 (Mbps)" "" "up_local"
    read_int "用户家宽带宽 (Mbps)" "" "up_remote"
    read_int "用户到本机单程ping (ms)" "" "up_ping"
    local up_rtt=$(( up_ping * 2 )) up_bw=$(_min $up_local $up_remote)

    echo -e "\n  ${W}${B}下游线路:${N}"
    collect_lines "下游" "IX专线/HK线路机/SG直连" "带宽" ""
    local bdp_up=$(( up_bw * up_rtt * 125 ))

    echo -e "\n  ${G}━ 计算结果 ━${N}"
    echo -e "  用户方向: 瓶颈${B}${up_bw}M${N} × ${up_rtt}ms = $(( bdp_up/1024 ))KB"
    echo -e "  下游最大: $(( CL_MAX_BDP/1024 ))KB (${CL_COUNT}条)\n"

    local eff_bw=$up_bw eff_rtt=$up_rtt
    [ $CL_MAX_BDP -gt $bdp_up ] && { eff_bw=$CL_MAIN_BW; eff_rtt=$CL_MAIN_RTT; }

    local config=$(calculate_and_generate "前置服务器" "$up_bw" "$up_rtt" "$CL_MAIN_BW" "$CL_MAIN_RTT" \
        "# 角色: 前置服务器
# 用户方向: ${up_local}M/${up_remote}M → 瓶颈${up_bw}M | RTT ${up_rtt}ms
# 下游: ${CL_COUNT}条${CL_HEADER}")
    apply_sysctl_config "前置服务器 (瓶颈${eff_bw}Mbps)" "$config"
}

wizard_ix() {
    echo -e "\n  ${B}${C}━━━ ② IX专线服务器 ━━━${N}\n"
    echo -e "  ${W}${B}上游线路:${N}"
    collect_lines "上游" "前置5M/前置300M" "带宽" "6"
    local up_count=$CL_COUNT up_header="$CL_HEADER"
    local main_bw=$CL_MAIN_BW main_rtt=$CL_MAIN_RTT max_bdp=$CL_MAX_BDP max_bw=$CL_MAX_BW

    echo -e "\n  ${W}${B}下游线路:${N}"
    collect_lines "下游" "东京落地/HK转发" "带宽" ""
    [ $CL_MAX_BDP -gt $max_bdp ] && { max_bdp=$CL_MAX_BDP; main_bw=$CL_MAIN_BW; main_rtt=$CL_MAIN_RTT; }
    [ $CL_MAX_BW -gt $max_bw ] && max_bw=$CL_MAX_BW

    echo -e "\n  ${G}━ 结果 ━${N}  上游${up_count}条 下游${CL_COUNT}条 最大BDP $(( max_bdp/1024 ))KB\n"

    local sec_bw=$max_bw sec_rtt=12; [ $main_rtt -eq 12 ] && sec_rtt=50
    local config=$(calculate_and_generate "IX专线服务器" "$main_bw" "$main_rtt" "$sec_bw" "$sec_rtt" \
        "# 角色: IX专线服务器
# 上游${up_count}条${up_header}
# 下游${CL_COUNT}条${CL_HEADER}")
    apply_sysctl_config "IX专线 (${up_count}上游/${CL_COUNT}下游)" "$config"
}

wizard_relay() {
    echo -e "\n  ${B}${C}━━━ ③ 国际转发/线路服务器 ━━━${N}\n"
    local my_bw; read_int "本机带宽 (Mbps)" "" "my_bw"

    local cn_bw=0 cn_rtt=0 bdp_cn=0
    echo ""
    if confirm "同时做中国优化节点? (前置直连不走IX)"; then
        local cn_remote cn_ping
        read_int "前置带宽 (Mbps)" "" "cn_remote"
        read_int "前置到本机ping (ms)" "" "cn_ping"
        cn_rtt=$(( cn_ping * 2 )); cn_bw=$(_min $my_bw $cn_remote)
        bdp_cn=$(( cn_bw * cn_rtt * 125 ))
    fi

    echo -e "\n  ${W}${B}IX方向:${N}"
    local ix_bw ix_ping; read_int "IX带宽 (Mbps)" "300" "ix_bw"; read_int "IX到本机ping (ms)" "" "ix_ping"
    local up_rtt=$(( ix_ping * 2 )) up_bw=$(_min $my_bw $ix_bw)

    echo -e "  ${W}${B}落地方向:${N}"
    local land_bw land_ping; read_int "落地带宽 (Mbps)" "" "land_bw"; read_int "到落地ping (ms)" "" "land_ping"
    local dn_rtt=$(( land_ping * 2 )) dn_bw=$(_min $my_bw $land_bw)

    local bdp_up=$(( up_bw * up_rtt * 125 )) bdp_dn=$(( dn_bw * dn_rtt * 125 ))
    local m_bw=$up_bw m_rtt=$up_rtt s_bw=$dn_bw s_rtt=$dn_rtt
    [ $bdp_dn -gt $bdp_up ] && { m_bw=$dn_bw; m_rtt=$dn_rtt; s_bw=$up_bw; s_rtt=$up_rtt; }
    [ $bdp_cn -gt $(( m_bw * m_rtt * 125 )) ] && { s_bw=$m_bw; s_rtt=$m_rtt; m_bw=$cn_bw; m_rtt=$cn_rtt; }

    local config=$(calculate_and_generate "国际转发/线路服务器" "$m_bw" "$m_rtt" "$s_bw" "$s_rtt" \
        "# 角色: 国际转发/线路服务器
# 本机${my_bw}M | IX瓶颈${up_bw}M RTT${up_rtt}ms | 落地瓶颈${dn_bw}M RTT${dn_rtt}ms")
    apply_sysctl_config "国际转发 (瓶颈${m_bw}Mbps)" "$config"
}

wizard_landing() {
    echo -e "\n  ${B}${C}━━━ ④ 落地服务器 ━━━${N}\n"
    echo -e "  ${W}${B}上游线路:${N}"
    collect_lines "上游" "IX直连/国际转发" "带宽" ""

    echo -e "\n  ${W}${B}出口方向:${N}"
    local dn_bw dn_ping
    read_int "出口带宽 (Mbps)" "$CL_MAX_BW" "dn_bw"
    read_int "到目标ping (ms)" "3" "dn_ping"
    local dn_rtt=$(( dn_ping * 2 ))

    local config=$(calculate_and_generate "落地服务器" "$CL_MAIN_BW" "$CL_MAIN_RTT" "$dn_bw" "$dn_rtt" \
        "# 角色: 落地服务器
# 上游${CL_COUNT}条${CL_HEADER}
# 出口: ${dn_bw}M RTT${dn_rtt}ms")
    apply_sysctl_config "落地服务器 (${CL_COUNT}条上游)" "$config"
}

# ==================== 系统状态 ====================
show_status() {
    echo -e "\n  ${B}${C}========== 系统状态 ==========${N}"
    [ -f "$PROFILE_CONF" ] && { source "$PROFILE_CONF"; echo -e "  ${W}方案: ${B}$SYSCTL_PROFILE_NAME${N}"; } || echo -e "  ${D}BBR: 未配置${N}"

    echo -e "  拥塞: ${B}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${N} | 队列: ${B}$(sysctl -n net.core.default_qdisc 2>/dev/null)${N}"
    local rmem=$(sysctl -n net.core.rmem_max 2>/dev/null); echo -e "  rmem_max: ${B}$(( rmem/1048576 ))MB${N} | notsent: ${B}$(( $(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null)/1024 ))KB${N}"
    echo -e "  内存: ${B}$(awk '/MemTotal/{printf "%.0f",$2/1024}' /proc/meminfo)MB${N} | Swap: ${B}$(awk '/SwapTotal/{printf "%.0f",$2/1024}' /proc/meminfo)MB${N}"

    echo ""
    if nft list table inet geo_filter >/dev/null 2>&1; then
        [ -f "$GEO_CONF" ] && { source "$GEO_CONF"; echo -e "  ${G}●${N} 白名单: ${W}${GEO_COUNTRIES}${N}"; } || echo -e "  ${G}●${N} 白名单: 已启用"
    else
        echo -e "  ${D}○ 白名单: 未启用${N}"
    fi

    echo -e "\n  ${B}[重传统计]${N}"
    nstat -sz TcpRetransSegs 2>/dev/null | sed 's/^/  /' || netstat -s 2>/dev/null | grep -i retrans | sed 's/^/  /'
    echo ""
}

# ==================== 服务管理 ====================
install_service() {
    local sp=$(readlink -f "$0"); mkdir -p "$CONFIG_DIR"
    cat > /etc/systemd/system/network-optimizer.service << EOF
[Unit]
Description=专线网络优化 (BBR + 白名单)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$sp service-start
ExecStop=$sp service-stop
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable network-optimizer.service
    echo -e "\n  ${G}✓ 开机自启已安装${N}\n"
}

toggle_service() {
    if systemctl is-enabled network-optimizer.service >/dev/null 2>&1; then
        confirm "关闭开机自启?" && { systemctl disable network-optimizer.service 2>/dev/null; echo -e "  ${G}已关闭${N}"; }
    else install_service; fi
}

reload_network() {
    echo -e "\n  ${B}${C}刷新网络配置${N}\n"
    local pattern="tcp_congestion_control|tcp_rmem|tcp_wmem|rmem_max|wmem_max|default_qdisc|tcp_notsent_lowat|tcp_slow_start|tcp_fastopen|tcp_tw_reuse|ip_forward|busy_poll|busy_read|netdev_budget|dev_weight|optmem_max"
    local found=0

    for f in /etc/sysctl.d/*.conf /etc/sysctl.conf; do
        [ ! -f "$f" ] || [ "$f" = "/etc/sysctl.d/99-network-optimize.conf" ] && continue
        if grep -qE "$pattern" "$f" 2>/dev/null; then
            echo -e "  ${Y}⚠${N} 冲突: $f"
            found=1
        fi
    done

    if [ $found -eq 1 ] && confirm "直接删除冲突文件? (备份到 $CONFIG_DIR/backup/)"; then
        mkdir -p "$CONFIG_DIR/backup"
        for f in /etc/sysctl.d/*.conf /etc/sysctl.conf; do
            [ ! -f "$f" ] || [ "$f" = "/etc/sysctl.d/99-network-optimize.conf" ] && continue
            [[ "$f" == /usr/lib/* || "$f" == /run/* ]] && continue
            if grep -qE "$pattern" "$f" 2>/dev/null; then
                cp "$f" "$CONFIG_DIR/backup/$(echo $f | tr / _).bak" 2>/dev/null
                rm -f "$f"; echo -e "  ${G}✓${N} 已删除: $f"
            fi
        done
    fi
    [ $found -eq 0 ] && echo -e "  ${G}✓${N} 无冲突"

    echo ""
    [ -f "$SYSCTL_CONF" ] && { run_cmd "加载sysctl" sysctl --system; } || echo -e "  ${D}跳过 (无配置)${N}"
    [ -f "$GEO_NFT" ] && run_cmd "加载白名单" nft -f "$GEO_NFT"

    echo -e "\n  ${G}${B}完成${N} | $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) | rmem=$(( $(sysctl -n net.core.rmem_max 2>/dev/null)/1048576 ))MB\n"
}

service_start() {
    [ -f "$SYSCTL_CONF" ] && { echo "[sysctl] 应用..."; sysctl --system >/dev/null 2>&1; }
    [ -f "$GEO_NFT" ] && { echo "[geo] 加载..."; nft -f "$GEO_NFT" 2>/dev/null; }
}
service_stop() { echo "[service] 已停止"; }

restore_defaults() {
    confirm "恢复默认? (删除所有优化配置)" || return
    rm -f /etc/sysctl.d/99-network-optimize.conf; sysctl --system >/dev/null 2>&1
    systemctl disable network-optimizer.service 2>/dev/null; rm -f /etc/systemd/system/network-optimizer.service
    nft delete table inet geo_filter 2>/dev/null
    systemctl disable geo-whitelist.service 2>/dev/null; rm -f /etc/systemd/system/geo-whitelist.service
    systemctl daemon-reload 2>/dev/null
    [ -f "$CONFIG_DIR/sysctl-backup.conf" ] && echo -e "  ${D}备份保留: $CONFIG_DIR/sysctl-backup.conf${N}"
    rm -f "$SYSCTL_CONF" "$PROFILE_CONF" "$GEO_CONF" "$GEO_NFT"; rm -rf "$GEO_DIR"
    echo -e "  ${G}已恢复默认${N}"
}

# ==================== 国家白名单 ====================
geo_main() {
    while true; do
        echo ""
        if nft list table inet geo_filter >/dev/null 2>&1; then
            [ -f "$GEO_CONF" ] && source "$GEO_CONF"
            echo -e "  ${G}●${N} 白名单: ${W}${GEO_COUNTRIES:-已启用}${N} | Ping: ${GEO_ALLOW_PING:-yes}"
        else echo -e "  ${D}○ 白名单: 未启用${N}"; fi

        local ping_label="禁止Ping"
        [ -f "$GEO_CONF" ] && { source "$GEO_CONF"; [ "${GEO_ALLOW_PING:-yes}" = "no" ] && ping_label="允许Ping"; }

        select_menu "国家白名单" "设置白名单" "更新IP库" "$ping_label" "查看规则" "关闭白名单" "返回"
        case $? in 0) geo_setup;; 1) geo_update;; 2) geo_toggle_ping;; 3) geo_status;; 4) geo_remove;; 5) return;; esac
        echo -ne "  ${D}回车继续...${N}"; read -r
    done
}

geo_setup() {
    command -v nft >/dev/null || { echo -e "  ${R}需安装nftables: apt install nftables -y${N}"; return; }
    command -v curl >/dev/null || { echo -e "  ${R}需安装curl: apt install curl -y${N}"; return; }

    echo -e "  ${B}${C}━━━ 白名单设置 ━━━${N}"
    echo -e "  ${R}${B}⚠ 确保SSH端口正确，否则会被锁！${N}\n"

    local ssh_port; read_int "SSH端口" "22" "ssh_port"

    select_menu "流量方向" "只控制入站" "入站+转发"; local chain_mode="input"; [ $? -eq 1 ] && chain_mode="input+forward"
    select_menu "ICMP Ping" "允许" "禁止"; local allow_ping="yes"; [ $? -eq 1 ] && allow_ping="no"

    echo -e "\n  ${D}常用: cn hk tw jp kr sg us de gb fr au ca nl th my vn id ph in ru${N}"
    _reset; local countries=""
    while [ -z "$countries" ]; do
        echo -ne "  ${W}国家代码 (空格分隔): ${N}"; read countries
        countries=$(echo "$countries" | tr '[:upper:]' '[:lower:]' | tr ',' ' ' | xargs)
        for cc in $countries; do [[ "$cc" =~ ^[a-z]{2}$ ]] || { echo -e "  ${R}无效: $cc${N}"; countries=""; break; }; done
    done

    echo -ne "  ${W}额外白名单IP (留空跳过): ${N}"; read custom_ips
    [ -n "$custom_ips" ] && custom_ips=$(echo "$custom_ips" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' | xargs)

    echo -e "\n  ${Y}应用: 国家=$countries SSH=$ssh_port Ping=$allow_ping 方向=$chain_mode${N}"
    confirm "确认?" || return

    mkdir -p "$CONFIG_DIR" "$GEO_DIR"
    cat > "$GEO_CONF" << EOF
GEO_COUNTRIES="$countries"
GEO_SSH_PORT="$ssh_port"
GEO_CUSTOM_IPS="$custom_ips"
GEO_CHAIN_MODE="$chain_mode"
GEO_ALLOW_PING="$allow_ping"
EOF
    geo_load_and_apply "$countries" "$ssh_port" "$custom_ips" "$chain_mode" "$allow_ping" "no"
}

geo_load_and_apply() {
    local countries="$1" ssh="$2" custom="$3" chain="${4:-input}" ping="${5:-yes}" force="${6:-no}"
    mkdir -p "$CONFIG_DIR" "$GEO_DIR"
    local all_ips="" fails=0

    for cc in $countries; do
        local zf="$GEO_DIR/${cc}.zone" name="${COUNTRY_NAMES[$cc]:-$cc}"
        if [ "$force" = "no" ] && [ -f "$zf" ] && [ -s "$zf" ]; then
            echo -e "  $cc ($name) ${G}缓存${N} ($(wc -l < "$zf")条)"
        else
            echo -ne "  $cc ($name) 下载..."
            if curl -sf --connect-timeout 10 --max-time 60 "${GEO_IP_SOURCE}/${cc}-aggregated.zone" -o "$zf" 2>/dev/null && [ -s "$zf" ]; then
                echo -e " ${G}✓${N} ($(wc -l < "$zf")条)"
            else echo -e " ${R}✗${N}"; ((fails++)); continue; fi
        fi
        while IFS= read -r l; do [[ "$l" =~ ^#|^$ ]] || all_ips="${all_ips}${l},"; done < "$zf"
    done
    all_ips="${all_ips%,}"
    [ -z "$all_ips" ] && { echo -e "  ${R}无可用数据${N}"; return 1; }

    local custom_rules="" fwd_chain=""
    for ip in $custom; do custom_rules="${custom_rules}
        ip saddr ${ip} accept"; done

    local icmp="ip protocol icmp accept"
    [ "$ping" = "no" ] && icmp="ip protocol icmp drop"

    [ "$chain" = "input+forward" ] && fwd_chain="
    chain forward {
        type filter hook forward priority 10; policy accept;
        ct state established,related accept
        ip saddr {10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10} accept
        ip saddr @wl accept${custom_rules}
        counter drop
    }"

    cat > "$GEO_NFT" << NFTEOF
table inet geo_filter
delete table inet geo_filter
table inet geo_filter {
    set wl { type ipv4_addr; flags interval; auto-merge; elements = { ${all_ips} } }
    chain input {
        type filter hook input priority 10; policy accept;
        ct state established,related accept
        iif "lo" accept
        ip saddr {10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,127.0.0.0/8} accept
        tcp dport ${ssh} accept
        ${icmp}
        ip saddr @wl accept${custom_rules}
        counter drop
    }${fwd_chain}
}
NFTEOF

    if run_cmd "应用nftables" nft -f "$GEO_NFT"; then
        cat > /etc/systemd/system/geo-whitelist.service << SEOF
[Unit]
Description=GeoIP Whitelist
After=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${GEO_NFT}
ExecStop=/usr/sbin/nft delete table inet geo_filter
[Install]
WantedBy=multi-user.target
SEOF
        systemctl daemon-reload; systemctl enable geo-whitelist.service 2>/dev/null
        sed -i '/^GEO_LAST_UPDATE=/d' "$GEO_CONF" 2>/dev/null
        echo "GEO_LAST_UPDATE=\"$(date '+%Y-%m-%d %H:%M:%S')\"" >> "$GEO_CONF"
        echo -e "  ${G}${B}白名单已生效 | $countries | SSH $ssh 全球开放${N}"
    fi
    [ $fails -gt 0 ] && echo -e "  ${Y}⚠ ${fails}个国家下载失败${N}"
}

geo_update() {
    [ -f "$GEO_CONF" ] || { echo -e "  ${R}请先设置白名单${N}"; return; }
    source "$GEO_CONF"
    geo_load_and_apply "$GEO_COUNTRIES" "$GEO_SSH_PORT" "$GEO_CUSTOM_IPS" "${GEO_CHAIN_MODE:-input}" "${GEO_ALLOW_PING:-yes}" "yes"
}

geo_toggle_ping() {
    [ -f "$GEO_CONF" ] || { echo -e "  ${R}请先设置白名单${N}"; return; }
    source "$GEO_CONF"
    local np="no"; [ "${GEO_ALLOW_PING:-yes}" = "no" ] && np="yes"
    sed -i "s/^GEO_ALLOW_PING=.*/GEO_ALLOW_PING=\"$np\"/" "$GEO_CONF"
    echo -e "  ${C}Ping: ${GEO_ALLOW_PING} → $np${N}"
    geo_load_and_apply "$GEO_COUNTRIES" "$GEO_SSH_PORT" "$GEO_CUSTOM_IPS" "${GEO_CHAIN_MODE:-input}" "$np" "no"
}

geo_status() {
    echo -e "\n  ${B}${C}━━━ 白名单状态 ━━━${N}"
    if nft list table inet geo_filter >/dev/null 2>&1; then
        echo -e "  ${G}●${N} 已启用"
        [ -f "$GEO_CONF" ] && { source "$GEO_CONF"
            echo -e "  国家: ${B}$GEO_COUNTRIES${N} | SSH: ${B}$GEO_SSH_PORT${N} | Ping: ${B}${GEO_ALLOW_PING:-yes}${N}"
            [ -n "$GEO_LAST_UPDATE" ] && echo -e "  更新: $GEO_LAST_UPDATE"; }
        echo -e "  拦截: ${B}$(nft list chain inet geo_filter input 2>/dev/null | grep -oP 'counter packets \K[0-9]+' | tail -1 || echo 0)${N} 包"
    else echo -e "  ${D}未启用${N}"; fi
    echo ""
}

geo_remove() {
    nft list table inet geo_filter >/dev/null 2>&1 || { echo -e "  ${D}未启用${N}"; return; }
    confirm "关闭白名单?" || return
    nft delete table inet geo_filter 2>/dev/null
    systemctl disable geo-whitelist.service 2>/dev/null; rm -f /etc/systemd/system/geo-whitelist.service
    systemctl daemon-reload 2>/dev/null
    echo -e "  ${G}已关闭${N}"
}

# ==================== 端口监控 ====================
port_monitor() {
    while true; do
        select_menu "端口监控" "所有端口连接" "指定端口详情" "连接排行" "返回"
        case $? in 0) port_all;; 1) port_single;; 2) port_rank;; 3) return;; esac
        echo -ne "  ${D}回车继续...${N}"; read -r
    done
}

# 着色: $1=数值 $2=高阈值 $3=中阈值
_color_val() {
    [ "$1" -ge "$2" ] && echo -ne "${R}${B}" || { [ "$1" -ge "$3" ] && echo -ne "${Y}" || echo -ne "${W}"; }
    echo -ne "$1${N}"
}

_port_svc() {
    case "$1" in
        22) echo SSH;; 80) echo HTTP;; 443) echo HTTPS;; 8080) echo HTTP-Alt;; 3306) echo MySQL;;
        5432) echo PgSQL;; 6379) echo Redis;; 53) echo DNS;; 1080) echo SOCKS;; 8388) echo SS;;
        *) local p=$(ss -tlnpH 2>/dev/null | grep ":$1 " | grep -oP 'users:\(\("\K[^"]+' | head -1); echo "${p:--}";;
    esac
}

port_all() {
    echo -e "\n  ${B}${C}━━━ 端口连接 ━━━${N}\n"
    printf "  ${B}%-7s %-12s %-8s %-8s${N}\n" "端口" "服务" "连接" "IP数"
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oP '\d+$' | sort -un | while read p; do
        local c=$(ss -tnH | awk '{print $5}' | grep -c ":${p}$")
        local u=$(ss -tnH | awk '{print $5}' | grep ":${p}$" | grep -oP '^[^:]+' | sort -u | wc -l)
        printf "  %-7s %-12s " "$p" "$(_port_svc $p)"
        _color_val $c 100 10; printf "        "; _color_val $u 50 5; echo
    done
    echo ""
}

port_single() {
    _reset; local p; read_int "端口号" "" "p"
    echo -e "\n  ${B}${C}━━━ 端口 $p ━━━${N} ($(_port_svc $p))\n"
    local data=$(ss -tnH | awk '{print $5}' | grep ":${p}$" | grep -oP '^[^:]+' | sort | uniq -c | sort -rn)
    [ -z "$data" ] && { echo -e "  ${D}无连接${N}\n"; return; }
    printf "  ${B}%-8s %-30s${N}\n" "连接数" "IP"
    echo "$data" | while read c ip; do printf "  "; _color_val $c 50 10; printf "        %s\n" "$ip"; done
    echo ""
}

port_rank() {
    echo -e "\n  ${B}${C}━━━ 连接排行 ━━━${N}"
    echo -e "\n  ${B}[TOP 15 IP]${N}"
    ss -tnH | awk '{print $5}' | grep -oP '^[^:]+' | sort | uniq -c | sort -rn | head -15 | while read c ip; do
        printf "  "; _color_val $c 100 30; printf "  %s\n" "$ip"
    done
    echo -e "\n  ${B}[连接状态]${N}"
    ss -tnH | awk '{print $1}' | sort | uniq -c | sort -rn | while read c s; do printf "  %-14s %s\n" "$s" "$c"; done
    echo ""
}

# ==================== 主菜单 ====================
interactive_main() {
    while true; do
        clear; echo ""
        echo -e "  ${B}${W}╔═══════════════════════════════════════╗${N}"
        echo -e "  ${B}${W}║     专线网络优化工具 $VERSION           ║${N}"
        echo -e "  ${B}${W}╚═══════════════════════════════════════╝${N}\n"

        [ -f "$PROFILE_CONF" ] && { source "$PROFILE_CONF"; echo -e "  ${G}●${N} BBR: ${W}$SYSCTL_PROFILE_NAME${N}"; } \
            || echo -e "  ${D}○ BBR: 未配置${N}"
        nft list table inet geo_filter >/dev/null 2>&1 && { [ -f "$GEO_CONF" ] && source "$GEO_CONF"; echo -e "  ${G}●${N} 白名单: ${W}${GEO_COUNTRIES:-on}${N}"; } \
            || echo -e "  ${D}○ 白名单: 未启用${N}"
        local al="安装开机自启"
        systemctl is-enabled network-optimizer.service >/dev/null 2>&1 && { echo -e "  ${G}●${N} 自启: ${W}已启用${N}"; al="关闭开机自启"; } \
            || echo -e "  ${D}○ 自启: 未启用${N}"
        echo -e "  ${D}内存: $(awk '/MemTotal/{printf "%.0f",$2/1024}' /proc/meminfo)MB | Swap: $(awk '/SwapTotal/{printf "%.0f",$2/1024}' /proc/meminfo)MB${N}\n"

        select_menu "操作" "[配置] BBR优化" "[配置] 国家白名单" "[监控] 系统状态" "[监控] 端口监控" \
            "[管理] 刷新配置" "[管理] $al" "[管理] 恢复默认" "退出"

        case $? in
            0) wizard_main;; 1) geo_main; continue;; 2) show_status;; 3) port_monitor; continue;;
            4) reload_network;; 5) toggle_service;; 6) restore_defaults;; 7) _reset; exit 0;;
        esac
        echo -ne "  ${D}回车返回...${N}"; read -r
    done
}

# ==================== 入口 ====================
case "${1}" in
    start|service-start) service_start;; stop|service-stop) service_stop;;
    status) show_status;; install) install_service;; restore) restore_defaults;;
    wizard) wizard_main;; geo-update) geo_update;; geo-remove) geo_remove;; geo-status) geo_status;;
    ports) port_all;; ports-rank) port_rank;; "") interactive_main;;
    *) echo "用法: $0 [wizard|status|ports|ports-rank|install|restore|geo-update|geo-remove|geo-status]"; exit 1;;
esac
