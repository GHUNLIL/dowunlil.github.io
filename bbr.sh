#!/bin/bash
# ============================================================
# 专线网络优化工具 v4.0
# wget -O bbr.sh https://raw.githubusercontent.com/GHUNLIL/dowunlil.github.io/main/bbr.sh && chmod +x bbr.sh && sudo bash bbr.sh
# 用法: sudo bash bbr.sh [命令]
# ============================================================

VERSION="v4.0"
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
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
WHITE='\033[1;37m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

rst() { tput cnorm 2>/dev/null; stty sane 2>/dev/null; }

run_cmd() {
    local msg="$1"; shift
    echo -ne "  ${WHITE}${msg} ... ${NC}"
    "$@" && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; return 1; }
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

# ==================== 交互组件 ====================
select_menu() {
    local title="$1"; shift; local opts=("$@") cnt=${#opts[@]} sel=0
    tput civis 2>/dev/null
    _d() {
        for ((i=0;i<cnt+4;i++)); do tput cuu1 2>/dev/null; tput el 2>/dev/null; done
        echo ""; echo -e "  ${BOLD}${CYAN}$title${NC}"; echo -e "  ${DIM}上下键选择，回车确认${NC}"; echo ""
        for ((i=0;i<cnt;i++)); do
            [ $i -eq $sel ] && echo -e "  ${GREEN}▸ ${WHITE}${BOLD}${opts[$i]}${NC}" || echo -e "    ${DIM}${opts[$i]}${NC}"
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

# ==================== 多线路收集器 ====================
# 结果: CL_COUNT CL_HEADER CL_MAX_BDP CL_MAX_BW CL_MAIN_BW CL_MAIN_RTT
collect_lines() {
    local dir_name="$1" name_hint="$2" bw_def="$3" ping_def="$4"
    CL_COUNT=0; CL_HEADER=""; CL_MAX_BDP=0; CL_MAX_BW=0; CL_MAIN_BW=0; CL_MAIN_RTT=0
    while true; do
        CL_COUNT=$(( CL_COUNT + 1 ))
        echo -e "  ${BOLD}${YELLOW}── ${dir_name} #${CL_COUNT} ──${NC}"; rst
        echo -ne "  ${WHITE}线路名称 (${name_hint}): ${NC}"; read ln
        [ -z "$ln" ] && ln="${dir_name}${CL_COUNT}"
        local bw ping
        read_int "  ${ln} 带宽 (Mbps)" "$bw_def" "bw"
        read_int "  ${ln} 单程ping (ms)" "$ping_def" "ping"
        local rtt=$(( ping * 2 )) bdp=$(( bw * rtt * 125 ))
        echo -e "  ${DIM}→ ${ln}: ${bw}Mbps × ${rtt}ms = $(( bdp / 1024 ))KB BDP${NC}"
        [ $bdp -gt $CL_MAX_BDP ] && { CL_MAX_BDP=$bdp; CL_MAIN_BW=$bw; CL_MAIN_RTT=$rtt; }
        [ $bw -gt $CL_MAX_BW ] && CL_MAX_BW=$bw
        CL_HEADER="${CL_HEADER}
# ${dir_name}${CL_COUNT}: ${ln} | ${bw}Mbps | RTT ${rtt}ms | BDP $(( bdp / 1024 ))KB"
        echo ""; confirm_action "还有更多${dir_name}?" || break; echo ""
    done
}

# ==================== 内存评估 ====================
check_memory_and_swap() {
    echo ""; echo -e "  ${BOLD}${CYAN}━━━ 内存评估 ━━━${NC}"
    get_meminfo
    echo -e "  ${WHITE}物理内存: ${BOLD}$(( MEM_TOTAL_KB / 1024 ))MB${NC}"
    [ $SWAP_TOTAL_KB -gt 0 ] && echo -e "  ${WHITE}Swap:     ${BOLD}$(( SWAP_TOTAL_KB / 1024 ))MB${NC}" || echo -e "  ${DIM}Swap:     未配置${NC}"
    echo ""
    if [ $(( MEM_AVAIL_KB / 1024 )) -lt 1024 ]; then
        echo -e "  ${YELLOW}⚠ 内存较小${NC}"
        if confirm_action "创建2GB Swap?"; then
            if [ ! -f /swapfile ]; then
                fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
                chmod 600 /swapfile; mkswap /swapfile >/dev/null 2>&1; swapon /swapfile >/dev/null 2>&1
                grep -q /swapfile /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
                echo -e "  ${GREEN}✓ Swap已创建${NC}"
            else echo -e "  ${DIM}已存在${NC}"; fi
        fi
    else echo -e "  ${GREEN}✓ 内存充足${NC}"; fi
}

# ================================================================
#              BDP动态计算与sysctl生成 (1Mbps~10Gbps)
# ================================================================

calculate_and_generate() {
    local role_name="$1" up_bw="$2" up_rtt="$3" down_bw="$4" down_rtt="$5" extra_header="$6"

    local bdp_up=$(( up_bw * up_rtt * 125 ))
    local bdp_dn=$(( down_bw * down_rtt * 125 ))
    local bdp=$bdp_up; [ $bdp_dn -gt $bdp ] && bdp=$bdp_dn
    local mbw=$up_bw; [ $down_bw -gt $mbw ] && mbw=$down_bw

    # 缓冲区 (超激进: BDP×8 给中转多流并发预留余量，下限 16MB 而非 2MB)
    local max=$(( (bdp * 8 + 1048575) / 1048576 * 1048576 ))
    [ $max -lt 16777216 ] && max=16777216                 # 超激进: 下限 16MB（原 2MB）
    [ $max -gt 536870912 ] && max=536870912                # 上限 512MB
    local def=$(( (bdp / 65536 + 1) * 65536 ))
    [ $def -lt 1048576 ] && def=1048576                    # 超激进: def 下限 1MB（原 256KB）
    [ $def -lt $(( max / 4 )) ] && def=$(( max / 4 ))     # def 不低于 max/4
    [ $def -gt 33554432 ] && def=33554432                  # 上限 32MB
    [ $def -gt $(( max / 2 )) ] && def=$(( max / 2 ))

    # tcp_mem 激进版: 可用内存的 25%/50%/75%（不再保守，充分利用内存跑满带宽）
    get_meminfo
    local pg=$(( MEM_AVAIL_KB / 4 ))
    local ml=$(( pg * 25 / 100 )) mp=$(( pg * 50 / 100 )) mh=$(( pg * 75 / 100 ))
    local mnh=$(( max * 2 / 1024 * 50 / 4 ))
    # Fix: mnh不能超过物理内存75%对应的pages，防止OOM
    local mem_page_limit=$(( MEM_TOTAL_KB * 1024 / 4096 * 75 / 100 ))
    [ $mnh -gt $mem_page_limit ] && mnh=$mem_page_limit
    [ $mh -lt $mnh ] && mh=$mnh
    [ $mp -lt $(( mh * 6 / 10 )) ] && mp=$(( mh * 6 / 10 ))
    [ $ml -lt $(( mh * 3 / 10 )) ] && ml=$(( mh * 3 / 10 ))
    [ $ml -lt 65536 ] && ml=65536; [ $mp -lt 131072 ] && mp=131072; [ $mh -lt 262144 ] && mh=262144

    # 动态参数
    # 秒开缓存激进: lowat=mbw×256，高RTT线路需要更大写缓存流水线化
    local lowat_min=$(( mbw * 32 )); [ $lowat_min -lt 4096 ] && lowat_min=4096
    local lowat=$(clamp $(( mbw * 256 )) $lowat_min 1048576)
    local smc=$(clamp $(( mbw * 80 )) 512 65535)
    local synbl=$(clamp $(( mbw * 48 )) 1024 262144)
    local ndbl=$(clamp $(( mbw * 96 )) 2000 1048576)
    local tw=$(clamp $(( mbw * 5000 )) 131072 16000000)
    local orph=$(clamp $(( mbw * 160 )) 4096 524288)
    local fmax=$(clamp $(( mbw * 2048 )) 131072 10485760)
    # UDP 单socket缓冲: 激进版，按 BDP/2 算，下限 256KB 上限 8MB（高并发 UDP 中转专用）
    local udpr=$(clamp $(( bdp / 2 )) 262144 8388608)
    # UDP 内存池激进版: 占可用内存 30%（IXP/转发节点 UDP 流量大），三级阈值 50%/75%/100%
    local udp_max_pages=$(( MEM_AVAIL_KB * 1024 / 4096 * 30 / 100 ))
    [ $udp_max_pages -lt 262144 ] && udp_max_pages=262144   # 保底 1GB pages
    local udpml=$(( udp_max_pages / 2 ))                    # min: 50% 才开始 pressure
    local udpmm=$(( udp_max_pages * 3 / 4 ))                # pressure: 75%
    local udpmax=$udp_max_pages                             # max: 100%

    # nf_conntrack 连接跟踪池按内存动态算，防转发丢包
    local nfconn=$(clamp $(( MEM_TOTAL_KB / 2 )) 1048576 8388608)

    # RPS 检测：网卡队列数
    local iface_rps=$(detect_interface)
    local queue_count=1
    [ -n "$iface_rps" ] && queue_count=$(ls -d /sys/class/net/$iface_rps/queues/rx-* 2>/dev/null | wc -l)
    [ $queue_count -lt 1 ] && queue_count=1
    local cpu_cores=$(nproc 2>/dev/null || echo 1)
    # Fix: fin_timeout公式改为 /50，中等带宽下才有实际变化
    local fin=$(clamp $(( 30 - mbw / 50 )) 10 30)
    local omem=$(clamp $(( mbw * 128 )) 131072 2097152)
    # Fix: netdev_budget上限从4000提高到8000，支持4Gbps
    local ndb=$(clamp $(( mbw * 2 + 600 )) 600 8000)
    # dev_weight 激进: 高带宽需要更大单次收包量
    local dw=$(clamp $(( mbw / 8 + 64 )) 64 512)
    # busy_poll: 只用于低延迟(<10ms)机房，高RTT下开它反而浪费CPU
    local bp=0 br=0
    if [ "$up_rtt" -le 10 ] && [ "$down_rtt" -le 10 ] 2>/dev/null; then
        [ $mbw -ge 20 ] && { bp=$(clamp $(( mbw / 5 )) 20 200); br=$bp; }
    fi
    # initcwnd 直接拉到内核硬上限 128 (Linux 4.x+ 上限) — YouTube/Netflix/CDN 标配
    local initcwnd=128

    cat << EOF
# ============================================================
# ${role_name} - 网络优化配置
${extra_header}
# BDP: ${up_bw}M×${up_rtt}ms=$(( bdp_up / 1024 ))KB / ${down_bw}M×${down_rtt}ms=$(( bdp_dn / 1024 ))KB
# 缓冲: def=$(( def / 1024 ))KB max=$(( max / 1048576 ))MB | 内存$(( MEM_TOTAL_KB / 1024 ))MB
# 生成: $VERSION $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# --- 拥塞控制 ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- 缓冲区 ---
net.core.rmem_max = $max
net.core.wmem_max = $max
net.core.rmem_default = $def
net.core.wmem_default = $def
net.ipv4.tcp_rmem = 4096 $def $max
net.ipv4.tcp_wmem = 4096 $def $max
net.core.optmem_max = $omem
net.ipv4.tcp_mem = $ml $mp $mh

# --- 低延迟 (秒开核心) ---
net.ipv4.tcp_notsent_lowat = $lowat
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_autocorking = 1

# --- 重传 (跨国链路优化) ---
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_frto = 2
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_orphan_retries = 2
# RACK + 时间戳乱序检测，跨国链路必备
net.ipv4.tcp_recovery = 1
# 容忍跨国乱序，避免触发不必要重传
net.ipv4.tcp_max_reordering = 1000
# 失败连接快速放弃，省 SYN 等待
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 2
# 小流(视频信令、控制流)快速恢复
net.ipv4.tcp_thin_linear_timeouts = 1

# --- ECN (关闭避免兼容性问题) ---
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_ecn_fallback = 1

# --- MTU ---
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_base_mss = 1460
net.ipv4.tcp_min_snd_mss = 536

# --- TCP行为 (稳定优先) ---
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = $fin
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
# BBR pacing 激进版: 慢启动阶段 200% 速率，巡航阶段 120%（YouTube 视频流必备）
net.ipv4.tcp_pacing_ss_ratio = 200
net.ipv4.tcp_pacing_ca_ratio = 120
# 单流 qdisc 输出限制拉到 4MB（默认 1MB 卡 4K视频）
net.ipv4.tcp_limit_output_bytes = 4194304
# 防 RST 攻击但不限速合法流量
net.ipv4.tcp_challenge_ack_limit = 999999
# 不限速无效 ACK（抖动场景关闭限速更稳）
net.ipv4.tcp_invalid_ratelimit = 0

# --- 连接队列 (全部拉满) ---
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65536
net.core.netdev_max_backlog = $ndbl
net.ipv4.tcp_max_tw_buckets = $tw
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_orphans = $orph

# --- 网卡调度 ---
net.core.netdev_budget = $ndb
net.core.netdev_budget_usecs = 8000
net.core.dev_weight = $dw
net.core.busy_poll = $bp
net.core.busy_read = $br
# RPS 流表拉大，多核分流更细
net.core.flow_limit_table_len = 8192

# --- UDP (激进 - 视频/语音/QUIC 大池) ---
net.ipv4.udp_rmem_min = $udpr
net.ipv4.udp_wmem_min = $udpr
net.ipv4.udp_mem = $udpml $udpmm $udpmax
# UDP 早期分段重组（QUIC/HTTP3 必备）
net.ipv4.udp_l3mdev_accept = 0

# --- 转发与 nf_conntrack 防丢包 ---
net.ipv4.ip_forward = 1
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# --- 安全 ---
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.netfilter.nf_conntrack_max = $nfconn
net.netfilter.nf_conntrack_buckets = $(( nfconn / 4 ))
net.netfilter.nf_conntrack_tcp_timeout_established = 1200
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120

# --- 系统 (拉满) ---
vm.swappiness = 1
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
fs.file-max = $fmax
fs.nr_open = 1073741816

# --- initcwnd (秒开核心, 通过ip route设置) ---
# initcwnd=$initcwnd initrwnd=$initcwnd
EOF
}

# RPS 自动配置（多核负载均衡）
apply_rps() {
    local iface=$(detect_interface)
    [ -z "$iface" ] && return
    local qc=$(ls -d /sys/class/net/$iface/queues/rx-* 2>/dev/null | wc -l)
    [ -z "$qc" ] && qc=1
    local cc=$(nproc 2>/dev/null || echo 1)
    [ "$qc" -ge "$cc" ] && return
    [ "$cc" -lt 2 ] && return

    echo ""
    echo -e "  ${BOLD}${YELLOW}━━━ 多核负载均衡 (RPS) ━━━${NC}"
    echo -e "  ${DIM}网卡 ${qc}队列 < CPU ${cc}核，自动开启 RPS 分散中断${NC}"
    echo ""

    local mask=$(printf '%x' $(( (1 << cc) - 1 )))

    # 配满 rps_sock_flow_entries（全局）
    echo 65536 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null

    # 每个队列配 rps_cpus + rps_flow_cnt
    for ((i=0; i<qc; i++)); do
        local rx="/sys/class/net/${iface}/queues/rx-${i}"
        [ -d "$rx" ] || continue
        echo "$mask" > "$rx/rps_cpus" 2>/dev/null && echo -e "  ${GREEN}✓${NC} rx-${i} → CPU mask ${mask}"
        echo 4096 > "$rx/rps_flow_cnt" 2>/dev/null
    done

    # 持久化到 rc.local
    if ! grep -q "rps_cpus" /etc/rc.local 2>/dev/null; then
        [ ! -f /etc/rc.local ] && echo "#!/bin/bash" > /etc/rc.local
        sed -i '/^exit 0/d' /etc/rc.local 2>/dev/null
        cat >> /etc/rc.local << EOF
# RPS 多核负载均衡 (由 bbr-v4.0 自动配置)
echo 65536 > /proc/sys/net/core/rps_sock_flow_entries
EOF
        for ((i=0; i<qc; i++)); do
            local rx="/sys/class/net/${iface}/queues/rx-${i}"
            [ -d "$rx" ] || continue
            echo "echo ${mask} > ${rx}/rps_cpus" >> /etc/rc.local
            echo "echo 4096 > ${rx}/rps_flow_cnt" >> /etc/rc.local
        done
        echo "exit 0" >> /etc/rc.local
        chmod +x /etc/rc.local
        echo -e "  ${GREEN}✓${NC} RPS 已写入 /etc/rc.local（开机自启）"
    else
        echo -e "  ${DIM}ℹ RPS 配置已存在 rc.local，跳过${NC}"
    fi
    echo -e "  ${GREEN}${BOLD}CPU ${cc}核全部参与网络处理，火力全开！${NC}"
    echo ""
}

# ==================== iptables 端口转发 ====================
port_forward_main() {
    while true; do
        echo ""
        local f_status="未配置"; iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q DNAT && f_status="运行中"
        echo -e "  ${BOLD}${CYAN}━━━ 端口转发 (IX/中转/前置) ━━━${NC}"
        echo -e "  ${DIM}当前状态: ${WHITE}$f_status${NC}"; echo ""
        select_menu "转发管理" "添加/覆盖全端口转发 (iptables)" "查看当前转发规则" "清空所有转发规则" "返回主菜单"
        case $? in
            0) port_forward_setup ;;
            1) port_forward_status ;;
            2) port_forward_clear ;;
            3) return ;;
        esac
        echo -ne "  ${DIM}回车继续...${NC}"; read -r
    done
}

port_forward_setup() {
    echo ""; echo -e "  ${BOLD}${CYAN}配置 iptables 端口转发${NC}"; echo ""
    local tip; echo -ne "  ${WHITE}目标机器IP (如 103.177.x.x): ${NC}"; read tip
    [[ "$tip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo -e "  ${RED}无效IP格式${NC}"; return; }
    local ps; read_int "本机起始端口 (建议避开22, 推荐23)" "23" "ps"
    local pe; read_int "本机结束端口" "65535" "pe"
    echo ""
    echo -e "  ${DIM}目标端口范围 (可回车默认同端口, 或填不同范围如 10000-11000)${NC}"
    local tport=""
    while [ -z "$tport" ]; do
        echo -ne "  ${WHITE}目标端口范围 [默认 ${ps}-${pe}]: ${NC}"; read tport
        [ -z "$tport" ] && tport="${ps}-${pe}"
        if echo "$tport" | grep -qP '^\d+[-:]\d+$'; then
            local ts=$(echo "$tport" | sed 's/-/:/' | cut -d: -f1)
            local te=$(echo "$tport" | sed 's/-/:/' | cut -d: -f2)
            [ "$ts" -gt 0 ] 2>/dev/null && [ "$te" -ge "$ts" ] 2>/dev/null && break
        fi
        echo -e "  ${RED}无效格式，请输入如 10000-11000${NC}"
        tport=""
    done
    # 统一转成冒号格式（iptables 用 23:65535，不支持 23-65535）
    local tport_ipt=$(echo "$tport" | sed 's/-/:/g')
    local ps_ipt=$(echo "${ps}-${pe}" | sed 's/-/:/g')
    local lip=$(ip -4 route get 223.5.5.5 2>/dev/null | awk '{print $7; exit}')
    [ -z "$lip" ] && lip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
    echo -e "  ${DIM}-----------------------------------"
    echo -e "  本机IP:     $lip"
    echo -e "  本机端口:   $ps-$pe"
    echo -e "  目标机IP:   $tip"
    echo -e "  目标端口:   $tport"
    echo -e "  协议:       TCP & UDP"
    echo -e "  -----------------------------------${NC}"
    confirm_action "确认执行配置?" || return
    echo -e "  ${DIM}→ 开启 IP 转发...${NC}"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    echo -e "  ${DIM}→ 注入 iptables 规则...${NC}"
    # 先删旧的同目标规则再添加，避免重复
    iptables -t nat -D PREROUTING -p tcp --dport "$ps_ipt" -j DNAT --to-destination "${tip}:${tport_ipt}" 2>/dev/null || true
    iptables -t nat -D PREROUTING -p udp --dport "$ps_ipt" -j DNAT --to-destination "${tip}:${tport_ipt}" 2>/dev/null || true
    iptables -D FORWARD -p tcp -d "$tip" --dport "$tport_ipt" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p udp -d "$tip" --dport "$tport_ipt" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD -p tcp -d "$tip" --dport "$tport_ipt" -j ACCEPT
    iptables -I FORWARD -p udp -d "$tip" --dport "$tport_ipt" -j ACCEPT
    # DNAT: 同端口转发直接到IP，不同端口需指定目标端口
    if [ "$tport_ipt" = "$ps_ipt" ]; then
        iptables -t nat -A PREROUTING -p tcp --dport "$ps_ipt" -j DNAT --to-destination "$tip"
        iptables -t nat -A PREROUTING -p udp --dport "$ps_ipt" -j DNAT --to-destination "$tip"
    else
        # nf_tables 不支持 DNAT IP:port-range，转用 iptables-legacy
        if command -v iptables-legacy >/dev/null 2>&1; then
            iptables-legacy -t nat -A PREROUTING -p tcp --dport "$ps":"$pe" -j DNAT --to-destination "${tip}:${tport}"
            iptables-legacy -t nat -A PREROUTING -p udp --dport "$ps":"$pe" -j DNAT --to-destination "${tip}:${tport}"
        else
            echo -e "  ${YELLOW}⚠ 不同端口转发需 iptables-legacy，当前不支持${NC}"
            echo -e "  ${DIM}  建议: apt install iptables-legacy 或手动配置${NC}"
        fi
    fi
    iptables -t nat -A POSTROUTING -p tcp -d "$tip" --dport "$tport_ipt" -j MASQUERADE
    iptables -t nat -A POSTROUTING -p udp -d "$tip" --dport "$tport_ipt" -j MASQUERADE
    echo -e "  ${DIM}→ 保存并配置开机加载...${NC}"
    mkdir -p /etc/network/if-pre-up.d
    iptables-save > /etc/iptables.up.rules
    cat >/etc/network/if-pre-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.up.rules
EOF
    chmod +x /etc/network/if-pre-up.d/iptables
    echo -e "  ${GREEN}✓ 配置成功！流量已无损转发至 $tip${NC}"
}

port_forward_status() {
    echo ""; echo -e "  ${BOLD}${CYAN}当前 NAT 转发规则:${NC}"
    echo -e "  ${DIM}PREROUTING (入口转换):${NC}"
    iptables -t nat -nL PREROUTING --line-numbers | grep DNAT || echo "  无"
    echo -e "  ${DIM}POSTROUTING (出口伪装):${NC}"
    iptables -t nat -nL POSTROUTING --line-numbers | grep -E "SNAT|MASQUERADE" || echo "  无"
    echo ""
}

port_forward_clear() {
    confirm_action "确定清空所有 iptables NAT 转发规则?" || return
    iptables -t nat -F
    rm -f /etc/iptables.up.rules /etc/network/if-pre-up.d/iptables
    echo -e "  ${GREEN}✓ 转发规则已清空${NC}"
}

# ==================== 应用配置 ====================
apply_initcwnd() {
    local icwnd=$(grep -oP 'initcwnd=\K[0-9]+' "$SYSCTL_CONF" 2>/dev/null || echo 30)
    local iface=$(detect_interface)
    [ -z "$iface" ] && return
    local gw=$(ip route show default dev "$iface" 2>/dev/null | awk '/default/{print $3;exit}')
    [ -z "$gw" ] && return
    ip route change default via "$gw" dev "$iface" initcwnd "$icwnd" initrwnd "$icwnd" 2>/dev/null && \
        echo -e "  ${GREEN}✓${NC} initcwnd=${icwnd} initrwnd=${icwnd} (秒开加速)" || \
        echo -e "  ${YELLOW}⚠${NC} initcwnd设置失败(不影响使用)"
}

apply_sysctl_config() {
    local role_name="$1" config="$2"
    echo ""; echo -e "  ${BOLD}${CYAN}生成配置: $role_name${NC}"
    if ! grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        modprobe tcp_bbr 2>/dev/null
        grep -q bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || \
            echo -e "  ${RED}⚠ 内核不支持BBR (需>=4.9, 当前$(uname -r))${NC}"
    fi
    check_memory_and_swap

    # 自动加载内核模块（开机自启）
    modprobe nf_conntrack 2>/dev/null
    mkdir -p /etc/modules-load.d
    echo -e "tcp_bbr\nnf_conntrack" > /etc/modules-load.d/network-optimize.conf

    if confirm_action "确认写入并应用?"; then
        init_config_dir
        [ ! -f "$CONFIG_DIR/sysctl-backup.conf" ] && { sysctl -a > "$CONFIG_DIR/sysctl-backup.conf" 2>/dev/null; echo -e "  ${GREEN}✓${NC} 已备份"; }
        # Too many open files 修复（高并发场景）
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
        echo -e "  ${GREEN}✓${NC} 已生效 | $(sysctl -n net.ipv4.tcp_congestion_control) + $(sysctl -n net.core.default_qdisc)"
    else
        echo -e "  ${DIM}已取消，未写入任何配置${NC}"
    fi
    echo ""
    apply_rps
}

# ==================== 一键自动配置 ====================

# 临时应用极限参数(仅内存，不落盘)，让测速不被默认小缓冲卡住
apply_temp_boost() {
    echo -ne "  ${WHITE}预热:${NC}  ${DIM}临时拉满内核参数...${NC}"
    modprobe tcp_bbr 2>/dev/null
    # 保存原始值用于回滚
    ORIG_SYSCTL=$(sysctl -n \
        net.core.default_qdisc \
        net.ipv4.tcp_congestion_control \
        net.core.rmem_max \
        net.core.wmem_max \
        net.core.rmem_default \
        net.core.wmem_default \
        net.ipv4.tcp_window_scaling \
        net.ipv4.tcp_slow_start_after_idle \
        net.ipv4.tcp_no_metrics_save 2>/dev/null)
    # Fix: 单独保存 tcp_rmem/wmem，避免多值字段在数组中格式错乱
    ORIG_TCP_RMEM=$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)
    ORIG_TCP_WMEM=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)
    # 临时写入极限值(sysctl -w 仅运行时，重启即失效)
    sysctl -w \
        net.core.default_qdisc=fq \
        net.ipv4.tcp_congestion_control=bbr \
        net.core.rmem_max=268435456 \
        net.core.wmem_max=268435456 \
        net.core.rmem_default=4194304 \
        net.core.wmem_default=4194304 \
        "net.ipv4.tcp_rmem=4096 4194304 268435456" \
        "net.ipv4.tcp_wmem=4096 4194304 268435456" \
        net.ipv4.tcp_window_scaling=1 \
        net.ipv4.tcp_slow_start_after_idle=0 \
        net.ipv4.tcp_no_metrics_save=1 \
        >/dev/null 2>&1
    # 临时initcwnd
    local iface=$(detect_interface)
    if [ -n "$iface" ]; then
        local gw=$(ip route show default dev "$iface" 2>/dev/null | awk '/default/{print $3;exit}')
        [ -n "$gw" ] && ip route change default via "$gw" dev "$iface" initcwnd 128 initrwnd 128 2>/dev/null
    fi
    echo -e "\r  ${WHITE}预热:${NC}  ${GREEN}✓${NC} BBR+256MB缓冲+initcwnd128        "
}

# 回滚临时参数
rollback_temp_boost() {
    [ -z "$ORIG_SYSCTL" ] && return
    local vals; IFS=$'\n' read -rd '' -a vals <<< "$ORIG_SYSCTL"
    sysctl -w \
        net.core.default_qdisc="${vals[0]}" \
        net.ipv4.tcp_congestion_control="${vals[1]}" \
        net.core.rmem_max="${vals[2]}" \
        net.core.wmem_max="${vals[3]}" \
        net.core.rmem_default="${vals[4]}" \
        net.core.wmem_default="${vals[5]}" \
        net.ipv4.tcp_window_scaling="${vals[6]}" \
        net.ipv4.tcp_slow_start_after_idle="${vals[7]}" \
        net.ipv4.tcp_no_metrics_save="${vals[8]}" \
        >/dev/null 2>&1
    # Fix: 用单独保存的变量恢复 tcp_rmem/wmem，格式正确
    [ -n "$ORIG_TCP_RMEM" ] && sysctl -w "net.ipv4.tcp_rmem=$ORIG_TCP_RMEM" >/dev/null 2>&1
    [ -n "$ORIG_TCP_WMEM" ] && sysctl -w "net.ipv4.tcp_wmem=$ORIG_TCP_WMEM" >/dev/null 2>&1
    echo -e "  ${DIM}已回滚临时参数${NC}"
}

# 自适应测速: 100MB×1 + 10MB×1 + 自适应追加(高带宽用大文件)
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

    # 第1轮: Cloudflare 100MB
    _test_url "https://speed.cloudflare.com/__down?bytes=100000000" "Cloudflare 100MB" 30
    # 第2轮: Google CDN
    _test_url "http://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb" "Google CDN" 10
    # 第3轮: 自适应追加
    if [ "$max_mbps" -gt 2000 ] 2>/dev/null; then
        # >2Gbps: 10GB限时12秒，测持续吞吐
        _test_url "https://speed.cloudflare.com/__down?bytes=10000000000" "Cloudflare 10GB峰值" 12
    elif [ "$max_mbps" -gt 500 ] 2>/dev/null; then
        # >500Mbps: 1GB精确测
        _test_url "https://speed.cloudflare.com/__down?bytes=1000000000" "Cloudflare 1GB" 15
    else
        # <=500Mbps: 10MB补测
        _test_url "https://speed.cloudflare.com/__down?bytes=10000000" "Cloudflare 10MB" 15
    fi

    echo "$max_mbps"
}

auto_max_performance() {
    echo ""; echo -e "  ${BOLD}${CYAN}━━━ 一键自动配置 ━━━${NC}"; echo ""
    echo -e "  ${DIM}流程: 预热内核 → 带宽测速 → 延迟探测 → 选择角色 → 生成配置${NC}"; echo ""

    local iface=$(detect_interface)
    echo -e "  ${WHITE}网卡:${NC}  ${BOLD}${iface:-unknown}${NC}"

    get_meminfo
    echo -e "  ${WHITE}内存:${NC}  ${BOLD}$(( MEM_TOTAL_KB / 1024 ))MB${NC} + Swap ${BOLD}$(( SWAP_TOTAL_KB / 1024 ))MB${NC}"

    # ① 临时拉满内核参数
    apply_temp_boost

    # ② 探测延迟
    local best_rtt=200
    echo -ne "  ${WHITE}延迟:${NC}  探测中..."
    for target in 8.8.8.8 1.1.1.1 142.250.80.46; do
        local ms=$(ping -c 2 -W 3 -q "$target" 2>/dev/null | awk -F'/' '/rtt/{printf "%.0f",$5}')
        if [ -n "$ms" ] && [ "$ms" -gt 0 ] 2>/dev/null; then
            local rtt_val=$(( ms * 2 ))
            [ $rtt_val -lt $best_rtt ] && best_rtt=$rtt_val
        fi
    done
    [ $best_rtt -lt 20 ] && best_rtt=20
    echo -e "\r  ${WHITE}延迟:${NC}  ${BOLD}RTT ${best_rtt}ms${NC}                    "

    # ③ 真实带宽测速
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

    # BDP
    local bdp=$(( bw * best_rtt * 125 ))
    echo -e "  ${WHITE}BDP:${NC}   ${BOLD}$(( bdp / 1024 ))KB${NC} (${bw}Mbps × ${best_rtt}ms)"
    echo ""

    # ④ 手动修正带宽（实测不准时可以填商家宣称值）
    echo -e "  ${DIM}━━ 带宽确认 ━━${NC}"
    echo -e "  ${DIM}实测: ${bw}Mbps | 如果你想用商家宣称值/自己填，可以修改${NC}"
    if confirm_action "实测 ${bw}Mbps，接受此值?"; then
        : # 保持 bw 不变
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
        echo -e "  ${YELLOW}→ 使用手动值: ${bw}Mbps × ${best_rtt}ms = $(( bdp / 1024 ))KB BDP${NC}"
    fi
    echo ""

    # ⑤ 确认测速结果
    if ! confirm_action "使用此结果生成配置?"; then
        echo -e "  ${DIM}已取消${NC}"
        rollback_temp_boost
        return
    fi

    # ⑥ 选择服务器角色
    echo ""
    echo -e "  ${DIM}用户 → ①前置 → ②IX → ③转发 → ④落地 → 目标${NC}"; echo ""
    select_menu "本机角色" "① 前置服务器 (用户直连入口)" "② IX专线服务器 (上下游中转)" "③ 转发/线路服务器 (国际线路)" "④ 落地服务器 (出口访问目标)" "⑤ 通用 (不区分角色)"
    local role_idx=$?
    local role_name role_label
    case $role_idx in
        0) role_name="前置"; role_label="前置服务器 (用户直连入口)";;
        1) role_name="IX专线"; role_label="IX专线服务器 (上下游中转)";;
        2) role_name="转发"; role_label="转发/线路服务器 (国际线路)";;
        3) role_name="落地"; role_label="落地服务器 (出口访问目标)";;
        *) role_name="通用"; role_label="通用极速模式";;
    esac

    local h="# 角色: ${role_label} (自动检测)
# 网卡: ${iface:-unknown} | 实测带宽: ${bw}Mbps
# 内存: $(( MEM_TOTAL_KB / 1024 ))MB + Swap $(( SWAP_TOTAL_KB / 1024 ))MB
# RTT: ${best_rtt}ms (探测) | BDP: $(( bdp / 1024 ))KB"

    # ⑥ 生成并应用最终配置(替换临时参数)
    apply_sysctl_config "${role_name} (${bw}Mbps×${best_rtt}ms)" \
        "$(calculate_and_generate "${role_name} (${bw}Mbps×${best_rtt}ms)" "$bw" "$best_rtt" "$bw" "$best_rtt" "$h")"
}

# ==================== 链路向导 ====================
wizard_main() {
    echo ""; echo -e "  ${BOLD}${CYAN}━━━ BBR优化 - 链路向导 ━━━${NC}"
    echo -e "  ${DIM}用户 → 前置 → IX → 转发 → 落地 → 目标${NC}"; echo ""
    select_menu "选择节点" "前置服务器" "IX专线服务器" "国际转发/线路服务器" "落地服务器" "返回"
    case $? in 0) wizard_frontend;; 1) wizard_ix;; 2) wizard_relay;; 3) wizard_landing;; esac
}

wizard_frontend() {
    echo ""; echo -e "  ${BOLD}${CYAN}━━━ ① 前置服务器 ━━━${NC}"; echo ""
    echo -e "  ${DIM}多用户共享前置? 用户带宽可留空跳过，直接按本机带宽算${NC}"
    local ul ur up; read_int "本机上行 (Mbps)" "" "ul"
    echo -ne "  ${WHITE}用户带宽 (Mbps) [留空=同本机带宽]: ${NC}"; read ur
    [ -z "$ur" ] && ur=$ul
    read_int "用户到本机ping (ms)" "" "up"
    local rtt=$(( up * 2 )) bw=$ul; [ $ur -lt $bw ] && bw=$ur
    echo ""; echo -e "  ${WHITE}${BOLD}下游线路${NC}"
    collect_lines "下游" "IX专线/HK线路/SG直连" "$ul" ""
    local bu=$(( bw * rtt * 125 )) eb=$bw er=$rtt
    [ $CL_MAX_BDP -gt $bu ] && { eb=$CL_MAIN_BW; er=$CL_MAIN_RTT; }
    local h="# 角色: 前置服务器
# 用户: ${ul}M/${ur}M → ${bw}Mbps RTT${rtt}ms
# 下游${CL_COUNT}条${CL_HEADER}"
    apply_sysctl_config "前置 (${eb}Mbps)" "$(calculate_and_generate "前置 (${eb}Mbps)" "$bw" "$rtt" "$CL_MAIN_BW" "$CL_MAIN_RTT" "$h")"
}

wizard_ix() {
    echo ""; echo -e "  ${BOLD}${CYAN}━━━ ② IX专线 ━━━${NC}"; echo ""
    echo -e "  ${WHITE}${BOLD}上游线路${NC}"
    collect_lines "上游" "前置5M/55M/300M" "" "6"
    local un=$CL_COUNT uh="$CL_HEADER" mb=$CL_MAIN_BW mr=$CL_MAIN_RTT md=$CL_MAX_BDP xb=$CL_MAX_BW
    echo ""; echo -e "  ${WHITE}${BOLD}下游线路${NC}"
    collect_lines "下游" "东京落地/HK转发" "" ""
    [ $CL_MAX_BDP -gt $md ] && { md=$CL_MAX_BDP; mb=$CL_MAIN_BW; mr=$CL_MAIN_RTT; }
    [ $CL_MAX_BW -gt $xb ] && xb=$CL_MAX_BW
    local sr=12; [ $mr -eq 12 ] && sr=50
    local h="# 角色: IX专线
# 上游${un}条${uh}
# 下游${CL_COUNT}条${CL_HEADER}"
    apply_sysctl_config "IX (${un}上/${CL_COUNT}下)" "$(calculate_and_generate "IX (${un}上/${CL_COUNT}下)" "$mb" "$mr" "$xb" "$sr" "$h")"
}

wizard_relay() {
    echo ""; echo -e "  ${BOLD}${CYAN}━━━ ③ 转发/线路服务器 ━━━${NC}"; echo ""
    local mb; read_int "本机带宽 (Mbps)" "" "mb"
    local cb=0 cr=0 crem=0
    echo ""
    if confirm_action "同时做中国优化节点?"; then
        echo ""; read_int "前置带宽 (Mbps)" "" "crem"; local cp; read_int "前置到本机ping (ms)" "" "cp"
        cr=$(( cp * 2 )); cb=$mb; [ $crem -lt $cb ] && cb=$crem
    fi
    echo ""; local ir ip; read_int "IX带宽 (Mbps)" "300" "ir"; read_int "IX到本机ping (ms)" "" "ip"
    local ur=$(( ip * 2 )) ub=$mb; [ $ir -lt $ub ] && ub=$ir
    echo ""; local lr lp; read_int "落地带宽 (Mbps)" "" "lr"; read_int "到落地ping (ms)" "" "lp"
    local dr=$(( lp * 2 )) db=$mb; [ $lr -lt $db ] && db=$lr
    local bu=$(( ub * ur * 125 )) bd=$(( db * dr * 125 )) bc=0; [ $cr -gt 0 ] && bc=$(( cb * cr * 125 ))
    local pw=$ub pr=$ur sw=$db sr=$dr
    if [ $bc -ge $bu ] && [ $bc -ge $bd ]; then pw=$cb; pr=$cr
    elif [ $bd -ge $bu ]; then pw=$db; pr=$dr; sw=$ub; sr=$ur; fi
    local h="# 角色: 转发/线路服务器
# 本机${mb}M | IX→${ub}M×${ur}ms | →落地${db}M×${dr}ms"
    apply_sysctl_config "转发 (${pw}Mbps)" "$(calculate_and_generate "转发 (${pw}Mbps)" "$pw" "$pr" "$sw" "$sr" "$h")"
}

wizard_landing() {
    echo ""; echo -e "  ${BOLD}${CYAN}━━━ ④ 落地服务器 ━━━${NC}"; echo ""
    echo -e "  ${WHITE}${BOLD}上游线路${NC}"
    collect_lines "上游" "IX直连/转发/HK线路" "" ""
    echo ""; local db dp; read_int "出口带宽 (Mbps)" "$CL_MAX_BW" "db"; read_int "到目标ping (ms)" "3" "dp"
    local dr=$(( dp * 2 ))
    local h="# 角色: 落地服务器
# 上游${CL_COUNT}条${CL_HEADER}
# 出口: ${db}M×${dr}ms"
    apply_sysctl_config "落地 (${CL_COUNT}条上游)" "$(calculate_and_generate "落地 (${CL_COUNT}条上游)" "$CL_MAIN_BW" "$CL_MAIN_RTT" "$db" "$dr" "$h")"
}

# ==================== 状态 ====================
show_status() {
    echo ""; echo -e "  ${BOLD}${CYAN}========== 系统状态 ==========${NC}"
    [ -f "$PROFILE_CONF" ] && { source "$PROFILE_CONF"; echo -e "  ${GREEN}●${NC} BBR: ${WHITE}$SYSCTL_PROFILE_NAME${NC}"; } || echo -e "  ${DIM}○ BBR: 未配置${NC}"
    echo -e "  拥塞: ${BOLD}$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)${NC} | 队列: ${BOLD}$(sysctl -n net.core.default_qdisc 2>/dev/null)${NC}"
    echo -e "  rmem_max: ${BOLD}$(( $(sysctl -n net.core.rmem_max 2>/dev/null) / 1048576 ))MB${NC} | lowat: ${BOLD}$(( $(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null) / 1024 ))KB${NC}"
    local icwnd=$(ip route show default 2>/dev/null | grep -oP 'initcwnd \K[0-9]+' || echo "-")
    echo -e "  initcwnd: ${BOLD}${icwnd}${NC} | ECN: ${BOLD}$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null)${NC} | TFO: ${BOLD}$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null)${NC}"
    get_meminfo; echo -e "  内存: ${BOLD}$(( MEM_TOTAL_KB / 1024 ))MB${NC} | Swap: ${BOLD}$(( SWAP_TOTAL_KB / 1024 ))MB${NC}"
    local ct=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null) cm=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
    [ -n "$ct" ] && echo -e "  conntrack: ${BOLD}${ct}/${cm}${NC}"
    local enf=$(systemctl is-active initcwnd-enforcer.timer 2>/dev/null || echo "inactive")
    echo -e "  守护: ${BOLD}${enf}${NC}"
    local fwd_status=$(iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q DNAT && echo "运行中" || echo "未启用")
    echo -e "  转发: ${BOLD}${fwd_status}${NC} | Ping: ${BOLD}$(ping_status_str)${NC}"
    echo ""
    if nft list table inet geo_filter >/dev/null 2>&1; then
        [ -f "$GEO_CONF" ] && source "$GEO_CONF"
        echo -e "  ${GREEN}●${NC} 白名单: ${WHITE}${GEO_COUNTRIES:-启用}${NC}"
        echo -e "  拦截: ${BOLD}$(nft list chain inet geo_filter input 2>/dev/null|grep -oP 'counter packets \K[0-9]+'|tail -1||echo 0)${NC} 包"
    else echo -e "  ${DIM}○ 白名单: 未启用${NC}"; fi
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
    echo -e "  ${GREEN}✓${NC} initcwnd 守护已启动（每分钟检查，网络断开后自动恢复秒开）"
}

# ==================== 服务管理 ====================
install_service() {
    init_config_dir
    cat > /etc/systemd/system/network-optimizer.service << EOF
[Unit]
Description=专线网络优化
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$(readlink -f "$0") service-start
ExecStop=$(readlink -f "$0") service-stop
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable network-optimizer.service
    echo -e "  ${GREEN}✓ 自启已安装${NC}"
}

toggle_service() {
    systemctl is-enabled network-optimizer.service >/dev/null 2>&1 \
        && { confirm_action "关闭自启?" && systemctl disable network-optimizer.service 2>/dev/null && echo -e "  ${GREEN}已关闭${NC}"; } \
        || install_service
}

service_start() {
    [ -f "$SYSCTL_CONF" ] && sysctl --system >/dev/null 2>&1
    [ -f "$SYSCTL_CONF" ] && apply_initcwnd >/dev/null 2>&1
    install_initcwnd_enforcer >/dev/null 2>&1
    [ -f "$GEO_NFT" ] && nft -f "$GEO_NFT" 2>/dev/null
}
service_stop() { :; }

reload_network() {
    echo ""; echo -e "  ${BOLD}${CYAN}刷新网络配置${NC}"; echo ""
    local MATCH='tcp_congestion_control|tcp_rmem|tcp_wmem|rmem_max|wmem_max|default_qdisc|tcp_notsent_lowat|busy_poll|busy_read|netdev_budget|dev_weight|optmem_max|tcp_fastopen|tcp_tw_reuse|ip_forward'
    local found=0 files=""
    for f in /etc/sysctl.d/*.conf /etc/sysctl.conf; do
        [ ! -f "$f" ] || [ "$f" = "/etc/sysctl.d/99-network-optimize.conf" ] && continue
        grep -qE "$MATCH" "$f" 2>/dev/null && { echo -e "  ${YELLOW}⚠${NC} $f"; found=1; files="$files $f"; }
    done
    if [ $found -eq 1 ] && confirm_action "删除冲突文件? (备份到 $CONFIG_DIR/backup/)"; then
        mkdir -p "$CONFIG_DIR/backup"
        for f in $files; do cp "$f" "$CONFIG_DIR/backup/$(echo "$f"|tr / _).bak" 2>/dev/null; rm -f "$f"; echo -e "  ${GREEN}✓${NC} 删除: $f"; done
    fi
    echo ""
    [ -f "$SYSCTL_CONF" ] && run_cmd "sysctl重载" sysctl --system || echo -e "  ${DIM}无配置${NC}"
    [ -f "$SYSCTL_CONF" ] && apply_initcwnd
    install_initcwnd_enforcer
    [ -f "$GEO_NFT" ] && run_cmd "白名单重载" nft -f "$GEO_NFT"
    echo -e "  ${GREEN}${BOLD}完成${NC} | $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) rmem$(( $(sysctl -n net.core.rmem_max 2>/dev/null) / 1048576 ))MB"; echo ""
}

restore_defaults() {
    echo ""; confirm_action "恢复默认? (删除所有优化)" || return
    rm -f /etc/sysctl.d/99-network-optimize.conf "$PING_CONF"; sysctl --system >/dev/null 2>&1
    rm -f /etc/security/limits.d/99-network-optimize.conf
    systemctl disable --now initcwnd-enforcer.timer >/dev/null 2>&1
    rm -f /etc/systemd/system/initcwnd-enforcer.* /usr/local/bin/enforce-initcwnd.sh
    for s in network-optimizer geo-whitelist; do systemctl disable ${s}.service 2>/dev/null; rm -f /etc/systemd/system/${s}.service; done
    systemctl daemon-reload 2>/dev/null; nft delete table inet geo_filter 2>/dev/null
    [ -f "$CONFIG_DIR/sysctl-backup.conf" ] && echo -e "  ${DIM}备份保留: $CONFIG_DIR/sysctl-backup.conf${NC}"
    rm -f "$SYSCTL_CONF" "$PROFILE_CONF" "$GEO_CONF" "$GEO_NFT"; rm -rf "$GEO_DIR"
    echo -e "  ${GREEN}已恢复${NC}"
}

# ==================== 国家白名单 ====================
geo_main() {
    while true; do echo ""
        if nft list table inet geo_filter >/dev/null 2>&1; then
            [ -f "$GEO_CONF" ] && source "$GEO_CONF"; echo -e "  ${GREEN}●${NC} 白名单: ${WHITE}${GEO_COUNTRIES:-启用}${NC}"
        else echo -e "  ${DIM}○ 未启用${NC}"; fi; echo ""
        local pl="禁止Ping"; [ -f "$GEO_CONF" ] && source "$GEO_CONF" && [ "${GEO_ALLOW_PING:-yes}" = "no" ] && pl="允许Ping"
        select_menu "白名单" "设置" "更新IP库" "$pl" "查看" "关闭" "返回"
        case $? in 0) geo_setup;; 1) geo_update;; 2) geo_toggle_ping;; 3) geo_status;; 4) geo_remove;; 5) return;; esac
        echo -ne "  ${DIM}回车继续...${NC}"; read -r
    done
}

geo_setup() {
    echo ""
    command -v nft >/dev/null || { echo -e "  ${RED}需 nftables${NC}"; return; }
    command -v curl >/dev/null || { echo -e "  ${RED}需 curl${NC}"; return; }
    echo -e "  ${RED}${BOLD}⚠ 确保SSH端口正确${NC}"; echo ""
    local sp; read_int "SSH端口" "22" "sp"
    echo ""; select_menu "流量方向" "只控制入站" "入站+转发"; local cm="input"; [ $? -eq 1 ] && cm="input+forward"
    echo ""; select_menu "Ping" "允许" "禁止"; local ap="yes"; [ $? -eq 1 ] && ap="no"
    echo ""; echo -e "  ${DIM}cn hk jp kr sg us de gb fr au ca ru th my vn id ph in nl${NC}"; rst
    local cc=""
    while [ -z "$cc" ]; do echo -ne "  ${WHITE}国家代码: ${NC}"; read cc; cc=$(echo "$cc"|tr '[:upper:]' '[:lower:]'|tr ',' ' '|xargs)
        for c in $cc; do [[ "$c" =~ ^[a-z]{2}$ ]] || { echo -e "  ${RED}无效: $c${NC}"; cc=""; break; }; done
    done
    echo ""; rst; echo -ne "  ${WHITE}额外IP (可选): ${NC}"; read ci
    [ -n "$ci" ] && { local x=""; for i in $ci; do [[ "$i" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$ ]] && x="$x $i"; done; ci=$(echo "$x"|xargs); }
    echo ""; confirm_action "确认? SSH=$sp 国家=$cc" || return
    init_config_dir; mkdir -p "$GEO_DIR"
    echo "GEO_COUNTRIES=\"$cc\"
GEO_SSH_PORT=\"$sp\"
GEO_CUSTOM_IPS=\"$ci\"
GEO_CHAIN_MODE=\"$cm\"
GEO_ALLOW_PING=\"$ap\"" > "$GEO_CONF"
    geo_load_and_apply "$cc" "$sp" "$ci" "$cm" "$ap" "no"
}

geo_load_and_apply() {
    local countries="$1" sp="$2" ci="$3" cm="${4:-input}" ap="${5:-yes}" force="${6:-no}"
    echo ""; mkdir -p "$GEO_DIR"; local ips="" fails=0
    for cc in $countries; do
        local zf="$GEO_DIR/${cc}.zone" nm="${COUNTRY_NAMES[$cc]:-$cc}"
        if [ "$force" = "no" ] && [ -s "$zf" ]; then echo -e "  $cc($nm) ${GREEN}缓存${NC}"
        else echo -ne "  $cc($nm)..."; curl -sf --connect-timeout 10 --max-time 60 "${GEO_IP_SOURCE}/${cc}-aggregated.zone" -o "$zf" 2>/dev/null \
            && echo -e "${GREEN}✓${NC}" || { echo -e "${RED}✗${NC}"; ((fails++)); }; fi
        [ -f "$zf" ] && while IFS= read -r l; do [[ "$l" =~ ^#|^$ ]] || ips="${ips}${l},"; done < "$zf"
    done
    ips="${ips%,}"; [ -z "$ips" ] && { echo -e "  ${RED}无数据${NC}"; return 1; }
    local cir="" cfr=""
    [ -n "$ci" ] && for ip in $ci; do cir="$cir
        ip saddr $ip accept"; cfr="$cfr
        ip saddr $ip accept"; done
    local icmp; [ "$ap" = "yes" ] && icmp="ip protocol icmp accept" || icmp="ip protocol icmp drop"
    local fwd=""; [ "$cm" = "input+forward" ] && fwd="
    chain forward {
        type filter hook forward priority 10; policy accept;
        ct state established,related accept
        ip saddr {10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10} accept
        ip saddr @wl accept${cfr}
        counter drop
    }"
    cat > "$GEO_NFT" << NFTEOF
#!/usr/sbin/nft -f
table inet geo_filter
delete table inet geo_filter
table inet geo_filter {
    set wl { type ipv4_addr; flags interval; auto-merge; elements = { ${ips} } }
    chain input {
        type filter hook input priority 10; policy accept;
        ct state established,related accept
        iif "lo" accept
        ip saddr {10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,127.0.0.0/8} accept
        tcp dport ${sp} accept
        ${icmp}
        ip saddr @wl accept${cir}
        counter drop
    }${fwd}
}
NFTEOF
    run_cmd "应用规则" nft -f "$GEO_NFT" || return 1
    cat > /etc/systemd/system/geo-whitelist.service << EOF
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
EOF
    systemctl daemon-reload; systemctl enable geo-whitelist.service 2>/dev/null
    sed -i '/^GEO_LAST_UPDATE=/d' "$GEO_CONF" 2>/dev/null
    echo "GEO_LAST_UPDATE=\"$(date '+%Y-%m-%d %H:%M:%S')\"" >> "$GEO_CONF"
    echo -e "  ${GREEN}${BOLD}白名单生效: $countries | SSH $sp${NC}"; echo ""
}

geo_update() { [ -f "$GEO_CONF" ] || { echo -e "  ${RED}请先设置${NC}"; return; }; source "$GEO_CONF"; geo_load_and_apply "$GEO_COUNTRIES" "$GEO_SSH_PORT" "$GEO_CUSTOM_IPS" "${GEO_CHAIN_MODE:-input}" "${GEO_ALLOW_PING:-yes}" "yes"; }
geo_toggle_ping() { [ -f "$GEO_CONF" ] || { echo -e "  ${RED}请先设置${NC}"; return; }; source "$GEO_CONF"; local np; [ "${GEO_ALLOW_PING:-yes}" = "yes" ] && np="no" || np="yes"; sed -i "s/^GEO_ALLOW_PING=.*/GEO_ALLOW_PING=\"$np\"/" "$GEO_CONF"; source "$GEO_CONF"; geo_load_and_apply "$GEO_COUNTRIES" "$GEO_SSH_PORT" "$GEO_CUSTOM_IPS" "${GEO_CHAIN_MODE:-input}" "$np" "no"; }
geo_status() {
    echo ""; echo -e "  ${BOLD}${CYAN}━━━ 白名单 ━━━${NC}"
    if nft list table inet geo_filter >/dev/null 2>&1; then
        echo -e "  ${GREEN}●${NC} 启用"; [ -f "$GEO_CONF" ] && { source "$GEO_CONF"; echo -e "  $GEO_COUNTRIES | SSH:$GEO_SSH_PORT | Ping:${GEO_ALLOW_PING:-yes}"; [ -n "${GEO_LAST_UPDATE:-}" ] && echo -e "  更新: $GEO_LAST_UPDATE"; }
        echo ""; nft list chain inet geo_filter input 2>/dev/null | grep -E "accept|drop" | head -5 | sed 's/^/  /'
    else echo -e "  ${DIM}未启用${NC}"; fi; echo ""
}
geo_remove() { nft list table inet geo_filter >/dev/null 2>&1 || { echo -e "  ${DIM}未启用${NC}"; return; }; confirm_action "关闭白名单?" && { nft delete table inet geo_filter 2>/dev/null; systemctl disable geo-whitelist.service 2>/dev/null; rm -f /etc/systemd/system/geo-whitelist.service; systemctl daemon-reload 2>/dev/null; echo -e "  ${GREEN}已关闭${NC}"; }; }

# ==================== Ping 控制 (独立) ====================
PING_CONF="/etc/sysctl.d/97-icmp-control.conf"

ping_status_str() {
    local v4=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)
    local v6=$(sysctl -n net.ipv6.icmp.echo_ignore_all 2>/dev/null)
    [ "$v4" = "1" ] && [ "$v6" = "1" ] && { echo "全禁"; return; }
    [ "$v4" = "1" ] && [ "$v6" != "1" ] && { echo "禁v4"; return; }
    [ "$v4" != "1" ] && [ "$v6" = "1" ] && { echo "禁v6"; return; }
    echo "全允许"
}

ping_apply() {
    local v4="$1" v6="$2" label="$3"
    cat > "$PING_CONF" << EOF
# ICMP echo control - 由 bbr.sh 管理 ($label)
net.ipv4.icmp_echo_ignore_all = $v4
net.ipv6.icmp.echo_ignore_all = $v6
EOF
    sysctl -p "$PING_CONF" >/dev/null 2>&1
    echo -e "  ${GREEN}✓${NC} 已设置: ${BOLD}${label}${NC} (持久化到 $PING_CONF)"
}

ping_main() {
    while true; do
        echo ""
        echo -e "  ${BOLD}${CYAN}━━━ Ping (ICMP) 控制 ━━━${NC}"
        echo -e "  ${DIM}独立控制，不依赖白名单${NC}"
        local cur=$(ping_status_str)
        case "$cur" in
            "全禁") echo -e "  ${RED}● 当前: 全禁 (v4+v6 都不响应)${NC}";;
            "禁v4") echo -e "  ${YELLOW}● 当前: 仅禁 IPv4${NC}";;
            "禁v6") echo -e "  ${YELLOW}● 当前: 仅禁 IPv6${NC}";;
            *) echo -e "  ${GREEN}● 当前: 全允许${NC}";;
        esac
        echo ""
        select_menu "Ping 操作" "🚫 禁止 Ping (v4+v6)" "✅ 允许 Ping (v4+v6)" "仅禁 IPv4 (允许 v6)" "仅禁 IPv6 (允许 v4)" "查看当前状态" "返回"
        case $? in
            0) ping_apply 1 1 "禁止 v4+v6";;
            1) ping_apply 0 0 "允许 v4+v6";;
            2) ping_apply 1 0 "禁 v4 / 允许 v6";;
            3) ping_apply 0 1 "允许 v4 / 禁 v6";;
            4) ping_status_show;;
            5) return;;
        esac
        echo -ne "  ${DIM}回车继续...${NC}"; read -r
    done
}

ping_status_show() {
    echo ""
    echo -e "  ${BOLD}${CYAN}━━━ Ping 当前状态 ━━━${NC}"
    local v4=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)
    local v6=$(sysctl -n net.ipv6.icmp.echo_ignore_all 2>/dev/null)
    echo -e "  IPv4 ICMP echo: ${BOLD}$([ "$v4" = "1" ] && echo "禁止" || echo "允许")${NC} (=$v4)"
    echo -e "  IPv6 ICMP echo: ${BOLD}$([ "$v6" = "1" ] && echo "禁止" || echo "允许")${NC} (=$v6)"
    [ -f "$PING_CONF" ] && echo -e "  持久化文件: ${DIM}$PING_CONF${NC}" || echo -e "  ${DIM}无持久化文件 (当前为系统/其他配置默认值)${NC}"
    if nft list table inet geo_filter >/dev/null 2>&1 && [ -f "$GEO_CONF" ]; then
        source "$GEO_CONF"
        echo -e "  ${DIM}白名单内 ping 策略: ${GEO_ALLOW_PING:-yes} (与本独立控制叠加，最严格者生效)${NC}"
    fi
    echo ""
}

# ==================== 端口监控 ====================
port_monitor() { while true; do echo ""; select_menu "端口监控" "所有端口" "指定端口" "连接排行" "返回"; case $? in 0) port_all;; 1) port_single;; 2) port_rank;; 3) return;; esac; echo -ne "  ${DIM}回车继续...${NC}"; read -r; done; }

_svc() { case "$1" in 22) echo SSH;; 80) echo HTTP;; 443) echo HTTPS;; 8080) echo HTTP-Alt;; 3306) echo MySQL;; 5432) echo PG;; 6379) echo Redis;; 53) echo DNS;; 1080) echo SOCKS;; 8388) echo SS;; *) echo "-";; esac; }

port_all() {
    echo ""; echo -e "  ${BOLD}${CYAN}━━━ 端口连接 ━━━${NC}"; echo ""
    printf "  ${BOLD}%-8s %-12s %-8s %-8s${NC}\n" "端口" "服务" "连接" "IP数"
    ss -tlnH 2>/dev/null|awk '{print $4}'|grep -oP '(?<=:)\d+$'|sort -un|while read p; do
        local c=$(ss -tnH 2>/dev/null|awk '{print $5}'|grep -c ":${p}$")
        local u=$(ss -tnH 2>/dev/null|awk '{print $5}'|grep ":${p}$"|awk -F: '{print $1}'|sort -u|grep -cv '^$')
        printf "  %-8s %-12s %-8s %-8s\n" "$p" "$(_svc $p)" "$c" "$u"
    done; echo ""
}
port_single() { echo ""; rst; local p; read_int "端口" "" "p"; echo -e "  ${BOLD}${CYAN}端口 $p ($(_svc $p))${NC}"; echo ""
    ss -tnH 2>/dev/null|awk '{print $5}'|grep ":${p}$"|grep -oP '^[^:]+'|sort|uniq -c|sort -rn|awk '{printf "  %-8s %s\n",$1,$2}'; echo ""; }
port_rank() { echo ""; echo -e "  ${BOLD}${CYAN}━━━ 排行 ━━━${NC}"; echo -e "  ${WHITE}${BOLD}TOP 20 IP${NC}"; echo ""
    ss -tnH 2>/dev/null|awk '{print $5}'|grep -oP '^[^:]+'|sort|uniq -c|sort -rn|head -20|awk '{printf "  %-8s %s\n",$1,$2}'
    echo ""; echo -e "  ${WHITE}${BOLD}状态分布${NC}"; echo ""
    ss -tnH 2>/dev/null|awk '{print $1}'|sort|uniq -c|sort -rn|awk '{printf "  %-15s %s\n",$2,$1}'; echo ""; }

# ==================== 主菜单 ====================
interactive_main() {
    while true; do
        clear; echo ""
        echo -e "  ${BOLD}${WHITE}╔═══════════════════════════════════════╗${NC}"
        echo -e "  ${BOLD}${WHITE}║     专线网络优化工具 $VERSION          ║${NC}"
        echo -e "  ${BOLD}${WHITE}╚═══════════════════════════════════════╝${NC}"; echo ""
        [ -f "$PROFILE_CONF" ] && { source "$PROFILE_CONF"; echo -e "  ${GREEN}●${NC} BBR: ${WHITE}$SYSCTL_PROFILE_NAME${NC}"; } || echo -e "  ${DIM}○ BBR: 未配置${NC}"
        nft list table inet geo_filter >/dev/null 2>&1 && { [ -f "$GEO_CONF" ] && source "$GEO_CONF"; echo -e "  ${GREEN}●${NC} 白名单: ${WHITE}${GEO_COUNTRIES:-启用}${NC}"; } || echo -e "  ${DIM}○ 白名单: 未启用${NC}"
        local al="安装自启"; systemctl is-enabled network-optimizer.service >/dev/null 2>&1 && { echo -e "  ${GREEN}●${NC} 自启: 启用"; al="关闭自启"; } || echo -e "  ${DIM}○ 自启: 未启用${NC}"
        get_meminfo; echo -e "  ${DIM}内存$(( MEM_TOTAL_KB/1024 ))M Swap$(( SWAP_TOTAL_KB/1024 ))M${NC}"; echo ""
        local pcur=$(ping_status_str)
        local plabel="🚫 Ping控制 (当前:${pcur})"
        select_menu "操作" "⚡ 一键自动配置" "🔄 端口转发" "$plabel" "手动链路向导" "白名单" "状态" "端口监控" "刷新配置" "$al" "恢复默认" "退出"
        case $? in 0) auto_max_performance;; 1) port_forward_main;; 2) ping_main;continue;; 3) wizard_main;; 4) geo_main;continue;; 5) show_status;; 6) port_monitor;continue;; 7) reload_network;; 8) toggle_service;; 9) restore_defaults;; 10) rst;exit 0;; esac
        echo -ne "  ${DIM}回车返回...${NC}"; read -r
    done
}

# ==================== 入口 ====================
case "${1}" in
    start|service-start) service_start;; stop|service-stop) service_stop;; status) show_status;;
    auto) auto_max_performance;;
    install) install_service;; restore) restore_defaults;; wizard) wizard_main;;
    geo-update) geo_update;; geo-remove) geo_remove;; geo-status) geo_status;;
    ping-block) ping_apply 1 1 "禁止 v4+v6";;
    ping-allow) ping_apply 0 0 "允许 v4+v6";;
    ping-status) ping_status_show;;
    ports) port_all;; ports-rank) port_rank;; "") interactive_main;;
    *) echo "$VERSION | $0 [auto|wizard|status|ports|install|restore|geo-update|geo-remove|ping-block|ping-allow|ping-status]"; exit 1;;
esac
