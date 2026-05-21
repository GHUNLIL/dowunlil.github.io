#!/bin/bash
# ============================================================
# 专线网络优化工具 v1
# wget -O bbr.sh https://raw.githubusercontent.com/GHUNLIL/dowunlil.github.io/main/bbr.sh && chmod +x bbr.sh && sudo bash bbr.sh
# 用法: sudo bash bbr.sh [命令]
# ============================================================

VERSION="v1.4"
UPDATE_URL="https://raw.githubusercontent.com/GHUNLIL/dowunlil.github.io/main/bbr.sh"
CONFIG_DIR="/etc/network-optimizer"
SYSCTL_CONF="$CONFIG_DIR/sysctl-optimize.conf"
PROFILE_CONF="$CONFIG_DIR/profile.conf"
GAME_NET_SCRIPT="/usr/local/sbin/gaming-net-apply.sh"
GAME_NET_SERVICE="/etc/systemd/system/gaming-net-apply.service"

[ "$(id -u)" -ne 0 ] && { echo "错误: 需要root权限"; exit 1; }
trap 'tput cnorm 2>/dev/null; stty sane 2>/dev/null; echo; exit 0' INT TERM

# ==================== 基础工具 ====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
WHITE='\033[1;37m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

rst() { tput cnorm 2>/dev/null; stty sane 2>/dev/null; }

self_update_once() {
    [ "${BBR_SELF_UPDATED:-0}" = "1" ] && return 0
    # 开机/服务等非交互入口不自更新，避免启动期联网失败或拉到坏脚本把开机服务跑挂
    case "${1:-}" in start|service-start|stop|service-stop|status) return 0;; esac
    command -v wget >/dev/null 2>&1 || return 0

    local self tmp
    self=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
    [ -n "$self" ] && [ -f "$self" ] && [ -w "$self" ] || return 0
    tmp="${self}.update.$$"

    echo -ne "  ${DIM}检查最新脚本版本(5秒超时)...${NC}"
    # 校验: 非空 + shebang + 含关键函数 + 语法通过，否则视为下载损坏，绝不覆盖本地脚本
    if timeout 5 wget -q -O "$tmp" "$UPDATE_URL" 2>/dev/null && [ -s "$tmp" ] \
        && head -1 "$tmp" | grep -q '^#!' && grep -q 'self_update_once' "$tmp" \
        && bash -n "$tmp" 2>/dev/null; then
        chmod +x "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$self"
        echo -e "\r  ${GREEN}[OK]${NC} 已拉取最新脚本，继续执行...       "
        exec env BBR_SELF_UPDATED=1 bash "$self" "$@"
    else
        rm -f "$tmp" 2>/dev/null || true
        echo -e "\r  ${YELLOW}[!]${NC} 未拉取到有效的最新版本，运行本地脚本。"
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
        BBR_VER="bbr2"; BBR_VER_LABEL="bbr2"
    elif echo "$algos" | grep -qw "bbr"; then
        BBR_VER="bbr1"; BBR_VER_LABEL="bbr1 (Linux 主线)"
    else
        BBR_VER="none"; BBR_VER_LABEL="不支持 (内核 <4.9)"
    fi
}

# ==================== 交互组件 ====================
select_menu() {
    local title="$1"; shift; local opts=("$@") cnt=${#opts[@]} sel=0
    tput civis 2>/dev/null
    _d() {
        for ((i=0;i<cnt+4;i++)); do tput cuu1 2>/dev/null; tput el 2>/dev/null; done
        echo ""; echo -e "  ${BOLD}${CYAN}$title${NC}"; echo -e "  ${DIM}上下键选择，回车确认${NC}"; echo ""
        for ((i=0;i<cnt;i++)); do
            [ $i -eq $sel ] && echo -e "  ${GREEN}>${NC} ${WHITE}${BOLD}${opts[$i]}${NC}" || echo -e "    ${DIM}${opts[$i]}${NC}"
        done
    }
    for ((i=0;i<cnt+4;i++)); do echo ""; done; _d
    while true; do
        IFS= read -rsn1 k
        case "$k" in
            $'\x1b') read -rsn2 k; case "$k" in '[A') ((sel--)); [ $sel -lt 0 ] && sel=$((cnt-1));; '[B') ((sel++)); [ $sel -ge $cnt ] && sel=0;; esac; _d;;
            '') rst; return $sel;;
        esac
    done
}

confirm_action() { rst; echo -ne "  ${YELLOW}$1 [y/N]: ${NC}"; read -r a; [[ "$a" =~ ^[Yy]$ ]]; }

read_int() {
    local prompt="$1" default="$2" varname="$3"; rst
    while true; do
        [ -n "$default" ] && echo -ne "  ${WHITE}${prompt} [默认${default}]: ${NC}" || echo -ne "  ${WHITE}${prompt}: ${NC}"
        read val; [ -z "$val" ] && [ -n "$default" ] && val=$default
        [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ] && { eval "$varname=$val"; return; }
        echo -e "  ${RED}请输入有效的正整数${NC}"
    done
}

# 手动输入延迟 (RTT)
read_rtt_via_tcp() {
    local label="$1" varname="$2" rtt_def="$3"; rst
    echo ""
    echo -e "  ${DIM}-- ${label} 延迟 --${NC}"
    echo -e "  ${DIM}填 ping 命令显示的 time= 数字（即 RTT，单位 ms），无需任何换算${NC}"
    local p
    read_int "${label} 延迟 (ping 命令显示的数字, ms)" "$rtt_def" "p"
    eval "$varname=$p"
    echo -e "  ${DIM}-> 采用 ${p}ms 作为 RTT${NC}"
}

# ==================== 多线路收集器 ====================
collect_lines() {
    local dir_name="$1" name_hint="$2" bw_def="$3" rtt_def="$4"
    CL_COUNT=0; CL_HEADER=""; CL_MAX_BDP=0; CL_MAX_BW=0; CL_MAIN_BW=0; CL_MAIN_RTT=0
    while true; do
        CL_COUNT=$(( CL_COUNT + 1 ))
        echo -e "  ${BOLD}${YELLOW}-- ${dir_name} 线路 #${CL_COUNT} --${NC}"; rst
        local bw rtt
        read_int "  带宽 (Mbps)" "$bw_def" "bw"
        read_rtt_via_tcp "  ${dir_name}#${CL_COUNT}" "rtt" "$rtt_def"
        local bdp=$(( bw * rtt * 125 ))
        echo -e "  ${DIM}-> ${bw}Mbps x ${rtt}ms = $(( bdp / 1024 ))KB BDP${NC}"
        [ $bdp -gt $CL_MAX_BDP ] && { CL_MAX_BDP=$bdp; CL_MAIN_BW=$bw; CL_MAIN_RTT=$rtt; }
        [ $bw -gt $CL_MAX_BW ] && CL_MAX_BW=$bw
        CL_HEADER="${CL_HEADER}
# ${dir_name}#${CL_COUNT}: ${bw}Mbps | ${rtt}ms | BDP $(( bdp / 1024 ))KB"
        echo ""; confirm_action "还有更多${dir_name}线路?" || break; echo ""
    done
}

# ==================== 内存评估 ====================
check_memory_and_swap() {
    echo ""; echo -e "  ${BOLD}${CYAN}[ 内存评估 ]${NC}"
    get_meminfo
    echo -e "  ${WHITE}物理内存: ${BOLD}$(( MEM_TOTAL_KB / 1024 ))MB${NC}"
    [ $SWAP_TOTAL_KB -gt 0 ] && echo -e "  ${WHITE}Swap:     ${BOLD}$(( SWAP_TOTAL_KB / 1024 ))MB${NC}" || echo -e "  ${DIM}Swap:     未配置${NC}"
    echo ""
    if [ $(( MEM_AVAIL_KB / 1024 )) -lt 1024 ]; then
        echo -e "  ${YELLOW}[!] 内存较小${NC}"
        if confirm_action "创建2GB Swap?"; then
            if [ ! -f /swapfile ]; then
                fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
                chmod 600 /swapfile; mkswap /swapfile >/dev/null 2>&1; swapon /swapfile >/dev/null 2>&1
                grep -q /swapfile /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
                echo -e "  ${GREEN}[OK] Swap已创建${NC}"
            else echo -e "  ${DIM}已存在${NC}"; fi
        fi
    else echo -e "  ${GREEN}[OK] 内存充足${NC}"; fi
}

# ================================================================
#              BDP动态计算与sysctl生成 (1Mbps~10Gbps)
# ================================================================

calculate_and_generate() {
    local role_name="$1" up_bw="$2" up_rtt="$3" down_bw="$4" down_rtt="$5" extra_header="$6"
    get_meminfo
    detect_bbr_version   # 自动识别 BBR1/BBR3，影响下方 ECN 等参数

    local bdp_up=$(( up_bw * up_rtt * 125 ))
    local bdp_dn=$(( down_bw * down_rtt * 125 ))
    local bdp=$bdp_up; [ $bdp_dn -gt $bdp ] && bdp=$bdp_dn
    local mbw=$up_bw; [ $down_bw -gt $mbw ] && mbw=$down_bw

    # BBR3 改进了拥塞响应算法，缓冲倍数可适度收敛 (BBR1=8x, BBR3=6x)
    # 因为 BBR3 更精准探测带宽，不需要那么多 buffer 余量
    local bdp_mult=8
    [ "$BBR_VER" = "bbr3" ] && bdp_mult=6
    local max=$(( (bdp * bdp_mult + 1048575) / 1048576 * 1048576 ))
    [ $max -lt 16777216 ] && max=16777216
    [ $max -gt 536870912 ] && max=536870912

    # ECN: BBR1 关闭 (老旧路由器兼容)；BBR3 支持精确 ECN，可开启提升性能
    local ecn_val=0
    [ "$BBR_VER" = "bbr3" ] && ecn_val=1

    # tcp_notsent_lowat: 应用最多堆 16KB-256KB 未发送数据在内核里，超过则 write() 阻塞
    # 工业最佳实践 (Cloudflare/Google): 固定低范围而非跟带宽线性放大
    # 防止高带宽下应用堆 MB 级数据增加应用层延迟
    local lowat=$(clamp $(( mbw * 64 )) 16384 262144)

    local udpr=$bdp
    local udpr_b=$(( mbw * 8192 ))
    [ $udpr_b -gt $udpr ] && udpr=$udpr_b
    udpr=$(clamp $udpr 2097152 16777216)

    # udp_mem 单位是“页”(4KB)。取可用内存的 40%，并夹在 [64MB, 物理内存的 50%]：
    # 旧版固定 2GB 死下限在小内存机上会高于物理内存，使 UDP 内存压力永不触发 -> OOM 风险
    local udp_max_pages=$(( MEM_AVAIL_KB / 4 * 40 / 100 ))
    local udp_floor=16384
    local udp_cap=$(( MEM_TOTAL_KB / 8 ))
    [ $udp_max_pages -lt $udp_floor ] && udp_max_pages=$udp_floor
    [ $udp_max_pages -gt $udp_cap ] && udp_max_pages=$udp_cap
    local udpml=$(( udp_max_pages / 2 ))
    local udpmm=$(( udp_max_pages * 3 / 4 ))
    local udpmax=$udp_max_pages

    local nfconn=$(clamp $(( MEM_TOTAL_KB / 2 )) 1048576 16777216)
    local omem=$(clamp $(( mbw * 256 )) 262144 4194304)

    local bp=0 br=0
    if [ "$up_rtt" -le 10 ] && [ "$down_rtt" -le 10 ] 2>/dev/null; then
        [ $mbw -ge 20 ] && { bp=$(clamp $(( mbw / 5 )) 20 200); br=$bp; }
    fi

    local initcwnd=128

    cat << EOF
# ============================================================
# ${role_name} - 网络优化配置 (克制版，仅覆盖内核默认不合理项)
${extra_header}
# 内核 BBR 版本: ${BBR_VER_LABEL} -> 适配策略 BDPx${bdp_mult}, ECN=${ecn_val}
# BDP: ${up_bw}Mx${up_rtt}ms=$(( bdp_up / 1024 ))KB / ${down_bw}Mx${down_rtt}ms=$(( bdp_dn / 1024 ))KB
# 缓冲上限: ${max} bytes ($(( max / 1048576 ))MB) | 内存 $(( MEM_TOTAL_KB / 1024 ))MB
# 生成: $VERSION $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# --- 拥塞控制 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 缓冲区上限 ---
net.core.rmem_max = $max
net.core.wmem_max = $max
net.ipv4.tcp_rmem = 4096 87380 $max
net.ipv4.tcp_wmem = 4096 65536 $max
net.core.optmem_max = $omem

# --- 低延迟核心 ---
net.ipv4.tcp_notsent_lowat = $lowat
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_autocorking = 0
net.ipv4.tcp_min_rtt_wlen = 60

# --- 跨国链路 ---
net.ipv4.tcp_max_reordering = 1000
# ECN: BBR1 关闭(老旧路由器兼容)，BBR3 开启(精确响应提升性能)
net.ipv4.tcp_ecn = $ecn_val
net.ipv4.tcp_mtu_probing = 1

# --- 连接管理 ---
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_limit_output_bytes = 4194304

# --- 连接队列 ---
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.ip_local_port_range = 1024 65535

# --- 网卡调度 ---
net.core.flow_limit_table_len = 8192
$([ "$bp" -gt 0 ] && echo "# 低延迟机房启用 busy_poll
net.core.busy_poll = $bp
net.core.busy_read = $br")

# --- UDP ---
net.ipv4.udp_rmem_min = $udpr
net.ipv4.udp_wmem_min = $udpr
net.ipv4.udp_mem = $udpml $udpmm $udpmax

# --- 转发 ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# --- 安全加固 ---
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

# --- nf_conntrack ---
net.netfilter.nf_conntrack_max = $nfconn
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 300

# --- 内存 ---
vm.swappiness = 1

# --- initcwnd 标记 (apply_initcwnd 通过 grep 这一行提取数字，必须保留) ---
# initcwnd=$initcwnd initrwnd=$initcwnd
EOF
}

role_ix_sysctl_overrides() {
    cat << 'EOF'

# --- 角色增强: IX专线 / 高并发 UDP 中转 ---
net.core.netdev_max_backlog = 65536
net.netfilter.nf_conntrack_max = 2097152
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
EOF
}

role_relay_small_sysctl_overrides() {
    cat << 'EOF'

# --- 角色增强: 转发线路 / AWS 小内存保守模式 ---
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.netdev_max_backlog = 8192
net.netfilter.nf_conntrack_max = 1048576
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
EOF
}

# RPS 现代 systemd 优化
apply_rps() {
    local iface=$(detect_interface)
    [ -z "$iface" ] && return
    local qc=$(ls -d /sys/class/net/$iface/queues/rx-* 2>/dev/null | wc -l)
    [ -z "$qc" ] && qc=1
    local cc=$(nproc 2>/dev/null || echo 1)
    [ "$qc" -ge "$cc" ] && return
    [ "$cc" -lt 2 ] && return

    echo ""
    echo -e "  ${BOLD}${YELLOW}[ 多核负载均衡 (RPS) ]${NC}"
    echo -e "  ${DIM}网卡 ${qc}队列 < CPU ${cc}核，自动开启 RPS 分散中断 (基于 Systemd)${NC}"
    echo ""

    local mask=$(printf '%x' $(( (1 << cc) - 1 )))
    echo 65536 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null

    cat > /usr/local/bin/enforce-rps.sh << EOF
#!/bin/bash
echo 65536 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
for i in \$(seq 0 $(( qc - 1 ))); do
    rx="/sys/class/net/${iface}/queues/rx-\$i"
    if [ -d "\$rx" ]; then
        echo "${mask}" > "\$rx/rps_cpus" 2>/dev/null
        echo 4096 > "\$rx/rps_flow_cnt" 2>/dev/null
    fi
done
EOF
    chmod +x /usr/local/bin/enforce-rps.sh
    cat > /etc/systemd/system/rps-optimize.service << 'EOF'
[Unit]
Description=RPS Multi-core Optimization
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/enforce-rps.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now rps-optimize.service >/dev/null 2>&1
    echo -e "  ${GREEN}[OK]${NC} RPS 已通过 systemd 写入开机自启 (rps-optimize.service)"

    echo -e "  ${GREEN}${BOLD}CPU ${cc}核全部参与网络处理，火力全开！${NC}"
    echo ""
}

apply_initcwnd() {
    local icwnd=$(grep -oP 'initcwnd=\K[0-9]+' "$SYSCTL_CONF" 2>/dev/null || echo 30)
    local iface=$(detect_interface)
    [ -z "$iface" ] && return
    local gw=$(ip route show default dev "$iface" 2>/dev/null | awk '/default/{print $3;exit}')
    [ -z "$gw" ] && return
    ip route change default via "$gw" dev "$iface" initcwnd "$icwnd" initrwnd "$icwnd" 2>/dev/null && \
        echo -e "  ${GREEN}[OK]${NC} initcwnd=${icwnd} initrwnd=${icwnd} (秒开加速)" || \
        echo -e "  ${YELLOW}[!]${NC} initcwnd设置失败(不影响使用)"
}

apply_sysctl_config() {
    local role_name="$1" config="$2"
    echo ""; echo -e "  ${BOLD}${CYAN}生成配置: $role_name${NC}"
    if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        modprobe tcp_bbr 2>/dev/null
        grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || \
            echo -e "  ${RED}[!] 内核不支持BBR (需>=4.9, 当前$(uname -r))${NC}"
    fi
    check_memory_and_swap

    modprobe nf_conntrack 2>/dev/null
    mkdir -p /etc/modules-load.d
    echo -e "tcp_bbr\nnf_conntrack" > /etc/modules-load.d/network-optimize.conf

    if confirm_action "确认写入并应用?"; then
        init_config_dir
        [ ! -f "$CONFIG_DIR/sysctl-backup.conf" ] && { sysctl -a > "$CONFIG_DIR/sysctl-backup.conf" 2>/dev/null; echo -e "  ${GREEN}[OK]${NC} 已备份"; }
        mkdir -p /etc/security/limits.d
        echo -e "* soft nofile 1048576\n* hard nofile 1048576\nroot soft nofile 1048576\nroot hard nofile 1048576" > /etc/security/limits.d/99-network-optimize.conf
        sed -i '/DefaultLimitNOFILE/d' /etc/systemd/system.conf 2>/dev/null
        echo "DefaultLimitNOFILE=1048576" >> /etc/systemd/system.conf
        systemctl daemon-reload >/dev/null 2>&1
        echo "$config" > "$SYSCTL_CONF"
        echo "SYSCTL_PROFILE_NAME=\"$role_name\"" > "$PROFILE_CONF"
        ln -sf "$SYSCTL_CONF" /etc/sysctl.d/99-network-optimize.conf
        local err=$(sysctl --system 2>&1 | grep -i "error\|cannot\|invalid" || true)
        [ -n "$err" ] && echo "$err" | head -3 | sed 's/^/    /'
        apply_initcwnd
        install_initcwnd_enforcer
        echo -e "  ${GREEN}[OK]${NC} 已生效 | $(sysctl -n net.ipv4.tcp_congestion_control) + $(sysctl -n net.core.default_qdisc)"
    else
        echo -e "  ${DIM}已取消，未写入任何配置${NC}"
        echo ""
        return 1
    fi
    echo ""
    apply_rps
    return 0
}

install_gaming_role_runtime() {
    local role_label="$1" txq="$2"
    local iface
    iface=$(detect_interface)
    [ -z "$iface" ] && iface=""

    cat > "$GAME_NET_SCRIPT" << EOF
#!/bin/bash
set -u

ROLE="${role_label}"
IFACE="${iface}"
TXQLEN="${txq}"

if [ -z "\$IFACE" ]; then
    IFACE=\$(ip route show default 2>/dev/null | awk '/default/{print \$5;exit}')
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.forwarding=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.accept_ra=2 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.accept_ra=2 >/dev/null 2>&1 || true

if [ -n "\$IFACE" ] && [ -d "/sys/class/net/\$IFACE" ]; then
    ip link set dev "\$IFACE" txqueuelen "\$TXQLEN" >/dev/null 2>&1 || true
    tc qdisc replace dev "\$IFACE" root fq >/dev/null 2>&1 || true
    sysctl -w "net.ipv6.conf.\$IFACE.accept_ra=2" >/dev/null 2>&1 || true
fi
EOF
    chmod +x "$GAME_NET_SCRIPT"

    cat > "$GAME_NET_SERVICE" << EOF
[Unit]
Description=Gaming UDP network runtime tuning (${role_label})
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${GAME_NET_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload >/dev/null 2>&1
    if systemctl enable --now gaming-net-apply.service >/dev/null 2>&1; then
        echo -e "  ${GREEN}[OK]${NC} 已应用 ${role_label} 运行时增强: txqueuelen=${txq}, fq qdisc, IPv6 RA保护 (保留网卡 offload)"
    else
        echo -e "  ${YELLOW}[!]${NC} gaming-net-apply.service 启用失败，可手动执行: ${GAME_NET_SCRIPT}"
    fi
}

apply_temp_boost() {
    echo -ne "  ${WHITE}预热:${NC}  ${DIM}临时拉满内核参数...${NC}"
    modprobe tcp_bbr 2>/dev/null
    ORIG_SYSCTL=$(sysctl -n net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default net.ipv4.tcp_window_scaling net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_no_metrics_save 2>/dev/null)
    ORIG_TCP_RMEM=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)
    ORIG_TCP_WMEM=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)
    sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr net.core.rmem_max=268435456 net.core.wmem_max=268435456 net.core.rmem_default=4194304 net.core.wmem_default=4194304 "net.ipv4.tcp_rmem=4096 4194304 268435456" "net.ipv4.tcp_wmem=4096 4194304 268435456" net.ipv4.tcp_window_scaling=1 net.ipv4.tcp_slow_start_after_idle=0 net.ipv4.tcp_no_metrics_save=1 >/dev/null 2>&1
    local iface=$(detect_interface)
    if [ -n "$iface" ]; then
        local gw=$(ip route show default dev "$iface" 2>/dev/null | awk '/default/{print $3;exit}')
        [ -n "$gw" ] && ip route change default via "$gw" dev "$iface" initcwnd 128 initrwnd 128 2>/dev/null
    fi
    echo -e "\r  ${WHITE}预热:${NC}  ${GREEN}[OK]${NC} BBR+256MB缓冲+initcwnd128        "
}

rollback_temp_boost() {
    [ -z "$ORIG_SYSCTL" ] && return
    local vals; IFS=$'\n' read -rd '' -a vals <<< "$ORIG_SYSCTL"
    sysctl -w net.core.default_qdisc="${vals[0]}" net.ipv4.tcp_congestion_control="${vals[1]}" net.core.rmem_max="${vals[2]}" net.core.wmem_max="${vals[3]}" net.core.rmem_default="${vals[4]}" net.core.wmem_default="${vals[5]}" net.ipv4.tcp_window_scaling="${vals[6]}" net.ipv4.tcp_slow_start_after_idle="${vals[7]}" net.ipv4.tcp_no_metrics_save="${vals[8]}" >/dev/null 2>&1
    [ -n "$ORIG_TCP_RMEM" ] && sysctl -w "net.ipv4.tcp_rmem=$ORIG_TCP_RMEM" >/dev/null 2>&1
    [ -n "$ORIG_TCP_WMEM" ] && sysctl -w "net.ipv4.tcp_wmem=$ORIG_TCP_WMEM" >/dev/null 2>&1
    echo -e "  ${DIM}已回滚临时参数${NC}"
}

speedtest_probe() {
    local max_mbps=0 round=0 total=3
    _test_url() {
        local url="$1" label="$2" timeout="$3"
        round=$(( round + 1 ))
        echo -ne "\r  ${WHITE}带宽:${NC}  ${DIM}[${round}/${total}] ${label}...${NC}                                    " >&2
        local speed=$(curl -so /dev/null -w '%{speed_download}' --connect-timeout 5 --max-time "$timeout" "$url" 2>/dev/null)
        [ -z "$speed" ] && return
        local mbps=$(awk "BEGIN{v=$speed*8/1000000; printf \"%.0f\",v}" 2>/dev/null)
        [ -n "$mbps" ] && [ "$mbps" -gt "$max_mbps" ] 2>/dev/null && max_mbps=$mbps
    }
    _test_url "https://speed.cloudflare.com/__down?bytes=100000000" "Cloudflare 100MB" 30
    _test_url "http://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" "Google CDN" 10
    if [ "$max_mbps" -gt 2000 ] 2>/dev/null; then
        _test_url "https://speed.cloudflare.com/__down?bytes=10000000000" "Cloudflare 10GB峰值" 12
    elif [ "$max_mbps" -gt 500 ] 2>/dev/null; then
        _test_url "https://speed.cloudflare.com/__down?bytes=1000000000" "Cloudflare 1GB" 15
    else
        _test_url "https://speed.cloudflare.com/__down?bytes=10000000" "Cloudflare 10MB" 15
    fi
    echo "$max_mbps"
}

auto_max_performance() {
    echo ""; echo -e "  ${BOLD}${CYAN}[ 一键自动配置 ]${NC}"; echo ""
    echo -e "  ${YELLOW}${BOLD}⚠️ 警告: 中转与落地高延迟请用【手动链路向导】，自动模式仅适合本地/直连建站！${NC}"
    echo -e "  ${DIM}流程: 预热内核 -> 带宽测速 -> 延迟探测 -> 选择角色 -> 生成配置${NC}"; echo ""

    local iface=$(detect_interface)
    echo -e "  ${WHITE}网卡:${NC}  ${BOLD}${iface:-unknown}${NC}"

    get_meminfo
    echo -e "  ${WHITE}内存:${NC}  ${BOLD}$(( MEM_TOTAL_KB / 1024 ))MB${NC} + Swap ${BOLD}$(( SWAP_TOTAL_KB / 1024 ))MB${NC}"

    apply_temp_boost

    local best_rtt=200
    echo -ne "  ${WHITE}延迟:${NC}  探测中..."
    for target in 8.8.8.8 1.1.1.1 142.250.80.46; do
        local ms=$(ping -c 2 -W 3 -q "$target" 2>/dev/null | awk -F'/' '/rtt/{printf "%.0f",$5}')
        if [ -n "$ms" ] && [ "$ms" -gt 0 ] 2>/dev/null; then
            local rtt_val=$ms
            [ $rtt_val -lt $best_rtt ] && best_rtt=$rtt_val
        fi
    done
    [ $best_rtt -lt 20 ] && best_rtt=20
    echo -e "\r  ${WHITE}延迟:${NC}  ${BOLD}RTT ${best_rtt}ms${NC}                    "

    echo -ne "  ${WHITE}带宽:${NC}  测速中..."
    local bw=$(speedtest_probe)
    if [ "$bw" -gt 0 ] 2>/dev/null; then
        echo -e "\r  ${WHITE}带宽:${NC}  ${BOLD}${bw}Mbps${NC} (Cloudflare/Google实测)                  "
    else
        local link_speed=100
        if [ -n "$iface" ]; then
            if command -v ethtool >/dev/null 2>&1; then
                local es=$(ethtool "$iface" 2>/dev/null | awk '/Speed:/{gsub(/[^0-9]/,"",$2);print $2}')
                [ -n "$es" ] && [ "$es" -gt 0 ] 2>/dev/null && link_speed=$es
            fi
            if [ "$link_speed" = "1000" ] || [ "$link_speed" -le 0 ] 2>/dev/null; then
                local sf="/sys/class/net/${iface}/speed"
                [ -r "$sf" ] && { local sv=$(cat "$sf" 2>/dev/null); [ -n "$sv" ] && [ "$sv" -gt 0 ] 2>/dev/null && link_speed=$sv; }
            fi
        fi
        bw=$(( link_speed / 10 ))
        [ $bw -lt 10 ] && bw=10
        echo -e "\r  ${WHITE}带宽:${NC}  ${BOLD}${bw}Mbps${NC} ${YELLOW}(测速失败,估算值)${NC}          "
    fi

    local bdp=$(( bw * best_rtt * 125 ))
    echo -e "  ${WHITE}BDP:${NC}   ${BOLD}$(( bdp / 1024 ))KB${NC} (${bw}Mbps x ${best_rtt}ms)"
    echo ""

    echo -e "  ${DIM}[ 带宽确认 ]${NC}"
    echo -e "  ${DIM}实测: ${bw}Mbps | 如果你想用商家宣称值/自己填，可以修改${NC}"
    if confirm_action "实测 ${bw}Mbps，接受此值?"; then
        :
    else
        echo ""
        local manual_bw=""
        while [ -z "$manual_bw" ]; do
            echo -ne "  ${WHITE}手动输入带宽 (Mbps) [推荐 300]: ${NC}"
            read manual_bw
            [[ "$manual_bw" =~ ^[0-9]+$ ]] && [ "$manual_bw" -gt 0 ] && { bw=$manual_bw; break; }
            echo -e "  ${RED}请输入正整数${NC}"
            manual_bw=""
        done
        bdp=$(( bw * best_rtt * 125 ))
        echo -e "  ${YELLOW}-> 使用手动值: ${bw}Mbps x ${best_rtt}ms = $(( bdp / 1024 ))KB BDP${NC}"
    fi
    echo ""

    if ! confirm_action "使用此结果生成配置?"; then
        echo -e "  ${DIM}已取消${NC}"
        rollback_temp_boost
        return
    fi

    echo ""
    echo -e "  ${DIM}用户 -> 1.前置 -> 2.IX -> 3.转发 -> 4.落地 -> 目标${NC}"; echo ""
    select_menu "本机角色" "1. 前置服务器 (用户直连入口)" "2. IX专线服务器 (上下游中转)" "3. 转发/线路服务器 (国际线路)" "4. 落地服务器 (出口访问目标)" "5. 通用 (不区分角色)"
    local role_idx=$?
    local role_name role_label
    case $role_idx in
        0) role_name="前置"; role_label="前置服务器 (用户直连入口)";;
        1) role_name="IX专线"; role_label="IX专线服务器 (上下游中转)";;
        2) role_name="转发"; role_label="转发/线路服务器 (国际线路)";;
        3) role_name="落地"; role_label="落地服务器 (出口访问目标)";;
        *) role_name="通用"; role_label="通用极速模式";;
    esac

    local up_rtt_eff=$best_rtt down_rtt_eff=$best_rtt

    local bdp_eff_up=$(( bw * up_rtt_eff * 125 ))
    local bdp_eff_dn=$(( bw * down_rtt_eff * 125 ))
    local bdp_eff=$bdp_eff_up; [ $bdp_eff_dn -gt $bdp_eff ] && bdp_eff=$bdp_eff_dn

    local h="# 角色: ${role_label} (自动检测)
# 网卡: ${iface:-unknown} | 实测带宽: ${bw}Mbps
# 内存: $(( MEM_TOTAL_KB / 1024 ))MB + Swap $(( SWAP_TOTAL_KB / 1024 ))MB
# 探测 RTT: ${best_rtt}ms
# 有效 BDP: $(( bdp_eff / 1024 ))KB"

    local cfg
    cfg="$(calculate_and_generate "${role_name} (${bw}Mx${best_rtt}ms)" "$bw" "$up_rtt_eff" "$bw" "$down_rtt_eff" "$h")"
    case $role_idx in
        1) cfg="${cfg}$(role_ix_sysctl_overrides)" ;;
        2) cfg="${cfg}$(role_relay_small_sysctl_overrides)" ;;
    esac

    if apply_sysctl_config "${role_name} (${bw}Mx${best_rtt}ms)" "$cfg"; then
        case $role_idx in
            1) install_gaming_role_runtime "IX专线/高并发UDP中转" "2000" ;;
            2) install_gaming_role_runtime "转发线路/AWS小内存保守" "1000" ;;
        esac
    fi
}

# ==================== 链路向导 ====================
wizard_main() {
    echo ""
    echo -e "  ${BOLD}${CYAN}手动链路向导${NC}"
    echo -e "  ${DIM}链路结构: 用户 -> 前置 -> IX -> 转发 -> 落地 -> 目标${NC}"
    echo ""
    select_menu "请选择本机角色" \
        "1. 前置服务器 (用户直连入口)" \
        "2. IX 专线服务器 (上下游中转)" \
        "3. 转发 / 线路服务器 (国际线路)" \
        "4. 落地服务器 (出口访问目标)" \
        "返回主菜单"
    case $? in
        0) wizard_frontend;;
        1) wizard_ix;;
        2) wizard_relay;;
        3) wizard_landing;;
    esac
}

wizard_frontend() {
    echo ""; echo -e "  ${BOLD}${CYAN}[ 1. 前置服务器 ]${NC}"; echo ""
    echo -e "  ${DIM}只需本机带宽 + 用户/下游 RTT (对端带宽不影响 BDP)${NC}"
    local mb rtt; read_int "本机带宽 (Mbps)" "" "mb"
    read_rtt_via_tcp "用户到本机" "rtt" ""
    echo ""; echo -e "  ${WHITE}${BOLD}下游线路 (RTT 决定 BDP，带宽只看本机)${NC}"
    collect_lines "下游" "IX专线/HK线路/SG直连" "$mb" ""
    local up_rtt=$rtt dn_rtt=$CL_MAIN_RTT
    [ $CL_MAIN_RTT -lt $rtt ] && dn_rtt=$rtt
    local h="# 角色: 前置服务器
# 本机 ${mb}Mbps | 用户 RTT ${rtt}ms (TCP实测)
# 下游 ${CL_COUNT} 条${CL_HEADER}"
    apply_sysctl_config "前置 (${mb}Mbps)" "$(calculate_and_generate "前置 (${mb}Mbps)" "$mb" "$rtt" "$mb" "$CL_MAIN_RTT" "$h")"
}

wizard_ix() {
    echo ""; echo -e "  ${BOLD}${CYAN}[ 2. IX专线 ]${NC}"; echo ""
    echo -e "  ${DIM}IX 透传节点：上下游各填一条最长 RTT 的线路即可${NC}"
    local mb; read_int "本机带宽 (Mbps)" "" "mb"
    echo ""; echo -e "  ${WHITE}${BOLD}上游线路${NC}"
    collect_lines "上游" "前置/中国接入" "$mb" "6"
    local un=$CL_COUNT uh="$CL_HEADER" up_rtt=$CL_MAIN_RTT
    echo ""; echo -e "  ${WHITE}${BOLD}下游线路${NC}"
    collect_lines "下游" "落地/HK转发" "$mb" ""
    local dn_rtt=$CL_MAIN_RTT
    local h="# 角色: IX专线 | 本机 ${mb}Mbps
# 上游 ${un} 条${uh}
# 下游 ${CL_COUNT} 条${CL_HEADER}"
    local cfg
    cfg="$(calculate_and_generate "IX (${mb}Mbps)" "$mb" "$up_rtt" "$mb" "$dn_rtt" "$h")$(role_ix_sysctl_overrides)"
    if apply_sysctl_config "IX (${mb}Mbps)" "$cfg"; then
        install_gaming_role_runtime "IX专线/高并发UDP中转" "2000"
    fi
}

wizard_relay() {
    echo ""; echo -e "  ${BOLD}${CYAN}[ 3. 转发/线路服务器 ]${NC}"; echo ""
    echo -e "  ${DIM}下游可填多个目的地（如日本+美国），脚本自动按 RTT 最长者算 BDP${NC}"
    local mb; read_int "本机带宽 (Mbps)" "" "mb"

    echo ""; echo -e "  ${WHITE}${BOLD}上游来源 (IX/前置 -> 本机)${NC}"
    local ur=0 ur_count=0 ur_log=""
    while true; do
        ur_count=$(( ur_count + 1 ))
        local cur_ur
        read_rtt_via_tcp "上游 #${ur_count}" "cur_ur" ""
        ur_log="${ur_log}
# 上游 #${ur_count}: RTT ${cur_ur}ms"
        [ $cur_ur -gt $ur ] && ur=$cur_ur
        echo ""; confirm_action "还有更多上游来源?" || break
    done

    echo ""; echo -e "  ${WHITE}${BOLD}下游目的地 (本机 -> 落地)${NC}"
    echo -e "  ${DIM}填 ping 命令显示的延迟数字 (RTT，无需换算)${NC}"
    echo -e "  ${DIM}典型 RTT: 国内同城 5ms / 香港 30ms / 日本 50ms / 美西 150ms / 欧洲 280ms${NC}"
    local dr=0 dr_count=0 dr_log=""
    while true; do
        dr_count=$(( dr_count + 1 ))
        local cur_dr
        read_rtt_via_tcp "下游 #${dr_count}" "cur_dr" ""
        dr_log="${dr_log}
# 下游 #${dr_count}: RTT ${cur_dr}ms"
        [ $cur_dr -gt $dr ] && dr=$cur_dr
        echo ""; confirm_action "还有更多下游目的地?" || break
    done

    echo ""
    echo -e "  ${DIM}-> 上游主导 RTT: ${ur}ms | 下游主导 RTT: ${dr}ms (取最大值算 BDP)${NC}"

    local h="# 角色: 转发/线路服务器 | 本机 ${mb}Mbps
# 上游 ${ur_count} 条${ur_log}
# 下游 ${dr_count} 条${dr_log}
# BDP 主导: 上 ${ur}ms / 下 ${dr}ms (取最长 RTT)"
    local cfg
    cfg="$(calculate_and_generate "转发 (${mb}Mbps)" "$mb" "$ur" "$mb" "$dr" "$h")$(role_relay_small_sysctl_overrides)"
    if apply_sysctl_config "转发 (${mb}Mbps)" "$cfg"; then
        install_gaming_role_runtime "转发线路/AWS小内存保守" "1000"
    fi
}

wizard_landing() {
    echo ""; echo -e "  ${BOLD}${CYAN}[ 4. 落地服务器 ]${NC}"; echo ""
    echo -e "  ${DIM}落地节点出口=本机网卡，同IDC RTT<5ms，只需上游线路即可${NC}"
    local mb; read_int "本机带宽 (Mbps)" "" "mb"
    echo ""; echo -e "  ${WHITE}${BOLD}上游线路 (跨国主导 BDP)${NC}"
    collect_lines "上游" "IX直连/转发/HK线路" "$mb" ""
    local h="# 角色: 落地服务器 | 本机 ${mb}Mbps
# 上游 ${CL_COUNT} 条${CL_HEADER}
# 出口: 同IDC RTT<5ms (默认)"
    apply_sysctl_config "落地 (${mb}Mbps)" "$(calculate_and_generate "落地 (${mb}Mbps)" "$mb" "$CL_MAIN_RTT" "$mb" "5" "$h")"
}

# ==================== 状态 ====================
show_status() {
    echo ""; echo -e "  ${BOLD}${CYAN}========== 系统状态 ==========${NC}"
    detect_bbr_version
    [ -f "$PROFILE_CONF" ] && { source "$PROFILE_CONF"; echo -e "  ${GREEN}[ON]${NC} BBR: ${WHITE}$SYSCTL_PROFILE_NAME${NC}"; } || echo -e "  ${DIM}[--] BBR: 未配置${NC}"
    echo -e "  内核 BBR 版本: ${BOLD}${BBR_VER_LABEL}${NC} (脚本自动适配)"
    echo -e "  拥塞: ${BOLD}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${NC} | 队列: ${BOLD}$(sysctl -n net.core.default_qdisc 2>/dev/null)${NC}"
    echo -e "  rmem_max: ${BOLD}$(( $(sysctl -n net.core.rmem_max 2>/dev/null) / 1048576 ))MB${NC} | lowat: ${BOLD}$(( $(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null) / 1024 ))KB${NC}"
    local icwnd=$(ip route show default 2>/dev/null | grep -oP 'initcwnd \K[0-9]+' || echo "-")
    echo -e "  initcwnd: ${BOLD}${icwnd}${NC} | ECN: ${BOLD}$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null)${NC} | TFO: ${BOLD}$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)${NC}"
    get_meminfo; echo -e "  内存: ${BOLD}$(( MEM_TOTAL_KB / 1024 ))MB${NC} | Swap: ${BOLD}$(( SWAP_TOTAL_KB / 1024 ))MB${NC}"
    local ct=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null) cm=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
    [ -n "$ct" ] && echo -e "  conntrack: ${BOLD}${ct}/${cm}${NC}"
    local enf=$(systemctl is-active initcwnd-enforcer.timer 2>/dev/null || echo "inactive")
    echo -e "  守护: ${BOLD}${enf}${NC}"
    local game_net=$(systemctl is-active gaming-net-apply.service 2>/dev/null || echo "inactive")
    echo -e "  游戏UDP增强: ${BOLD}${game_net}${NC}"
    echo ""; nstat -sz TcpRetransSegs 2>/dev/null | sed 's/^/  /' || true; echo ""
}

# ==================== initcwnd 守护进程 ====================
install_initcwnd_enforcer() {
    cat > /usr/local/bin/enforce-initcwnd.sh << 'EOF'
#!/bin/bash
CONF="/etc/network-optimizer/sysctl-optimize.conf"
[ ! -f "$CONF" ] && exit 0
ICWND=$(grep -oP 'initcwnd=\K[0-9]+' "$CONF" || echo 30)
IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5;exit}')
[ -z "$IFACE" ] && exit 0
GW=$(ip route show default dev "$IFACE" 2>/dev/null | awk '/default/{print $3;exit}')
[ -z "$GW" ] && exit 0
if ! ip route show default | grep -q "initcwnd $ICWND"; then
    ip route change default via "$GW" dev "$IFACE" initcwnd "$ICWND" initrwnd "$ICWND" >/dev/null 2>&1
fi
EOF
    chmod +x /usr/local/bin/enforce-initcwnd.sh
    cat > /etc/systemd/system/initcwnd-enforcer.service << 'EOF'
[Unit]
Description=Enforce initcwnd settings
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/enforce-initcwnd.sh
EOF
    cat > /etc/systemd/system/initcwnd-enforcer.timer << 'EOF'
[Unit]
Description=Run initcwnd enforcer every minute
[Timer]
OnBootSec=30sec
OnUnitActiveSec=1min
AccuracySec=1sec
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now initcwnd-enforcer.timer >/dev/null 2>&1
    echo -e "  ${GREEN}[OK]${NC} initcwnd 守护已启动（每分钟检查，网络断开后自动恢复秒开）"
}

reload_network() {
    echo ""; echo -e "  ${BOLD}${CYAN}刷新网络配置${NC}"; echo ""
    local MATCH='tcp_congestion_control|tcp_rmem|tcp_wmem|rmem_max|wmem_max|default_qdisc|tcp_notsent_lowat|busy_poll|busy_read|optmem_max|tcp_fastopen|tcp_tw_reuse|ip_forward|udp_rmem_min|udp_wmem_min|udp_mem|nf_conntrack_max'
    local found=0 files=""
    for f in /etc/sysctl.d/*.conf /etc/sysctl.conf; do
        [ ! -f "$f" ] || [ "$f" = "/etc/sysctl.d/99-network-optimize.conf" ] && continue
        grep -qE "$MATCH" "$f" 2>/dev/null && { echo -e "  ${YELLOW}[!]${NC} $f"; found=1; files="$files $f"; }
    done
    if [ $found -eq 1 ] && confirm_action "删除冲突文件? (备份到 $CONFIG_DIR/backup/)"; then
        mkdir -p "$CONFIG_DIR/backup"
        for f in $files; do cp "$f" "$CONFIG_DIR/backup/$(echo "$f"|tr / _).bak" 2>/dev/null; rm -f "$f"; echo -e "  ${GREEN}[OK]${NC} 删除: $f"; done
    fi
    echo ""
    # 只加载我们自己的配置文件，避免刷屏所有系统/云镜像默认（仍有效，因 99-* 已是覆盖优先级）
    [ -f "$SYSCTL_CONF" ] && run_cmd "sysctl 重载（仅本脚本配置）" sysctl -p "$SYSCTL_CONF" || echo -e "  ${DIM}无配置${NC}"
    [ -f "$SYSCTL_CONF" ] && apply_initcwnd
    install_initcwnd_enforcer
    systemctl is-enabled gaming-net-apply.service >/dev/null 2>&1 && run_cmd "游戏UDP运行时增强" systemctl restart gaming-net-apply.service
    echo -e "  ${GREEN}${BOLD}完成${NC} | $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) rmem$(( $(sysctl -n net.core.rmem_max 2>/dev/null) / 1048576 ))MB"; echo ""
}

# ==================== 端口监控 ====================
port_monitor() {
    while true; do
        echo ""
        echo -e "  ${BOLD}${CYAN}端口连接监控${NC}"; echo ""
        select_menu "请选择" \
            "查看所有监听端口的连接数" \
            "查看指定端口的来源 IP" \
            "查看 TOP 20 连接数 IP 排行" \
            "返回主菜单"
        case $? in
            0) port_all;;
            1) port_single;;
            2) port_rank;;
            3) return;;
        esac
        echo -ne "  ${DIM}回车继续...${NC}"; read -r
    done
}

_svc() { case "$1" in 22) echo SSH;; 80) echo HTTP;; 443) echo HTTPS;; 8080) echo HTTP-Alt;; 3306) echo MySQL;; 5432) echo PG;; 6379) echo Redis;; 53) echo DNS;; 1080) echo SOCKS;; 8388) echo SS;; *) echo "-";; esac; }

port_all() {
    echo ""; echo -e "  ${BOLD}${CYAN}[ 端口连接 ]${NC}"; echo ""
    printf "  ${BOLD}%-8s %-12s %-8s %-8s${NC}\n" "端口" "服务" "连接" "IP数"
    ss -tlnH 2>/dev/null|awk '{print $4}'|grep -oP '(?<=:)\d+$'|sort -un|while read p; do
        local c=$(ss -tnH 2>/dev/null|awk '{print $5}'|grep -c ":${p}$")
        local u=$(ss -tnH 2>/dev/null|awk '{print $5}'|grep ":${p}$"|awk -F: '{print $1}'|sort -u|grep -cv '^$')
        printf "  %-8s %-12s %-8s %-8s\n" "$p" "$(_svc $p)" "$c" "$u"
    done; echo ""
}
port_single() { echo ""; rst; local p; read_int "端口" "" "p"; echo -e "  ${BOLD}${CYAN}端口 $p ($(_svc $p))${NC}"; echo ""
    ss -tnH 2>/dev/null|awk '{print $5}'|grep ":${p}$"|grep -oP '^[^:]+'|sort|uniq -c|sort -rn|awk '{printf "  %-8s %s\n",$1,$2}'; echo ""; }
port_rank() { echo ""; echo -e "  ${BOLD}${CYAN}[ 排行 ]${NC}"; echo -e "  ${WHITE}${BOLD}TOP 20 IP${NC}"; echo ""
    ss -tnH 2>/dev/null|awk '{print $5}'|grep -oP '^[^:]+'|sort|uniq -c|sort -rn|head -20|awk '{printf "  %-8s %s\n",$1,$2}'
    echo ""; echo -e "  ${WHITE}${BOLD}状态分布${NC}"; echo ""
    ss -tnH 2>/dev/null|awk '{print $1}'|sort|uniq -c|sort -rn|awk '{printf "  %-15s %s\n",$2,$1}'; echo ""; }

# ==================== 主菜单 ====================
interactive_main() {
    while true; do
        clear; echo ""
        echo -e "  ${BOLD}${WHITE}专线网络优化工具 $VERSION${NC}"
        echo -e "  ${DIM}=========================${NC}"
        echo ""
        detect_bbr_version
        [ -f "$PROFILE_CONF" ] && { source "$PROFILE_CONF"; echo -e "  ${GREEN}[ON]${NC} BBR优化:  ${WHITE}$SYSCTL_PROFILE_NAME${NC}  ${DIM}[内核 ${BBR_VER_LABEL}]${NC}"; } || echo -e "  ${DIM}[--] BBR优化:  未配置  [内核 ${BBR_VER_LABEL}]${NC}"
        get_meminfo
        echo -e "  ${DIM}     系统内存:  $(( MEM_TOTAL_KB/1024 ))M  Swap $(( SWAP_TOTAL_KB/1024 ))M${NC}"
        echo ""
        select_menu "请选择操作" \
            "手动链路向导" \
            "一键自动配置 (中转与落地高延迟请用手动链路)" \
            "查看系统状态" \
            "查看端口连接" \
            "刷新当前配置" \
            "退出"
        case $? in
            0)  wizard_main ;;
            1)  auto_max_performance ;;
            2)  show_status ;;
            3)  port_monitor; continue ;;
            4)  reload_network ;;
            5)  rst; exit 0 ;;
        esac
        echo ""
        echo -ne "  ${DIM}回车返回主菜单...${NC}"; read -r
    done
}

# ==================== 入口 ====================
case "${1}" in
    status) show_status;;
    auto) auto_max_performance;;
    wizard) wizard_main;;
    ports) port_all;; ports-rank) port_rank;; "") interactive_main;;
    *) echo "$VERSION | $0 [auto|wizard|status|ports]"; exit 1;;
esac
