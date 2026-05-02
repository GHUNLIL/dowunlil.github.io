#!/bin/bash
# ============================================================
# 专线网络优化工具 v4.0 (RTT精准无修改版 + Systemd现代化版)
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

# TCP 握手实测 RTT
read_rtt_via_tcp() {
    local label="$1" varname="$2" rtt_def="$3"; rst
    echo ""
    echo -e "  ${DIM}-- ${label} 延迟测量 --${NC}"
    echo -e "  ${DIM}填 ping 命令显示的 time= 数字（即 RTT）即可，无需任何换算${NC}"
    echo -e "  ${DIM}建议端口: 22(SSH) / 80(HTTP) / 443(HTTPS) / 任何监听端口${NC}"
    local ip port
    while true; do
        local hint=""
        [ -n "$rtt_def" ] && hint=" [留空=用默认 ${rtt_def}ms]" || hint=" [留空=手动填 ping 数字]"
        echo -ne "  ${WHITE}对端 IP${hint}: ${NC}"; read ip
        if [ -z "$ip" ]; then
            if [ -n "$rtt_def" ]; then
                eval "$varname=$rtt_def"
                echo -e "  ${YELLOW}-> 使用默认 RTT ${rtt_def}ms${NC}"
                return
            fi
            local p; read_int "${label} 延迟 (ping 命令显示的数字, ms)" "" "p"
            eval "$varname=$p"
            echo -e "  ${DIM}-> 采用 ${p}ms 作为 RTT${NC}"
            return
        fi
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
        echo -e "  ${RED}IP 格式错误（应为 X.X.X.X）${NC}"
    done
    echo -ne "  ${WHITE}端口 [默认 22]: ${NC}"; read port
    [ -z "$port" ] && port=22
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { echo -e "  ${YELLOW}端口无效，改用 22${NC}"; port=22; }

    _tcp_ns() {
        local t=$(date +%s%N 2>/dev/null)
        if [[ "$t" =~ ^[0-9]+$ ]] && [ ${#t} -ge 13 ]; then
            echo "$t"; return
        fi
        t=$(python3 -c "import time;print(int(time.time()*1e9))" 2>/dev/null)
        [ -n "$t" ] && { echo "$t"; return; }
        t=$(perl -MTime::HiRes -e 'print int(Time::HiRes::time()*1e9)' 2>/dev/null)
        [ -n "$t" ] && { echo "$t"; return; }
        echo $(( $(date +%s) * 1000000000 ))
    }

    echo -ne "  ${DIM}TCP 握手探测 ${ip}:${port} (6 次取最小值)...${NC}"
    local total=0 success=0 min_ms=99999
    for i in 1 2 3 4 5 6; do
        local s=$(_tcp_ns)
        if timeout 2 bash -c "exec 9<>/dev/tcp/$ip/$port; exec 9<&-; exec 9>&-" 2>/dev/null; then
            local e=$(_tcp_ns)
            if [ "$s" != "0" ] && [ "$e" != "0" ] && [ "$e" -gt "$s" ]; then
                local ms=$(( (e - s) / 1000000 ))
                [ $ms -lt 1 ] && ms=1
                [ $ms -lt $min_ms ] && min_ms=$ms
                total=$(( total + ms ))
                success=$(( success + 1 ))
            fi
        fi
        sleep 0.2 2>/dev/null
    done

    if [ $success -eq 0 ]; then
        echo -e "\r  ${RED}[X] TCP 探测失败${NC} ${DIM}(${ip}:${port} 不可达，端口过滤?)${NC}     "
        if [ -n "$rtt_def" ]; then
            echo -e "  ${YELLOW}-> 回退默认 RTT ${rtt_def}ms${NC}"
            eval "$varname=$rtt_def"
        else
            local p; read_int "${label} 延迟 (ping 命令显示的数字, ms)" "" "p"
            eval "$varname=$p"
        fi
        return
    fi

    local avg=$(( total / success ))
    echo -e "\r  ${GREEN}[OK]${NC} ${ip}:${port}                                                         "
    echo -e "       延迟: 平均 ${avg}ms / ${BOLD}最小 ${min_ms}ms${NC} (与 ping 命令显示的数字同义)"
    echo -e "       ${DIM}-> 采用 ${min_ms}ms 作为 RTT (BBR 友好，去抖动)${NC}"
    eval "$varname=$min_ms"
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

    local bdp_up=$(( up_bw * up_rtt * 125 ))
    local bdp_dn=$(( down_bw * down_rtt * 125 ))
    local bdp=$bdp_up; [ $bdp_dn -gt $bdp ] && bdp=$bdp_dn
    local mbw=$up_bw; [ $down_bw -gt $mbw ] && mbw=$down_bw

    local max=$(( (bdp * 8 + 1048575) / 1048576 * 1048576 ))
    [ $max -lt 16777216 ] && max=16777216
    [ $max -gt 536870912 ] && max=536870912

    local lowat_min=$(( mbw * 32 )); [ $lowat_min -lt 4096 ] && lowat_min=4096
    local lowat=$(clamp $(( mbw * 256 )) $lowat_min 1048576)

    local udpr=$bdp
    local udpr_b=$(( mbw * 8192 ))
    [ $udpr_b -gt $udpr ] && udpr=$udpr_b
    udpr=$(clamp $udpr 2097152 16777216)

    local udp_max_pages=$(( MEM_AVAIL_KB * 1024 / 4096 * 40 / 100 ))
    [ $udp_max_pages -lt 524288 ] && udp_max_pages=524288
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
net.ipv4.tcp_ecn = 0
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

port_forward_main() {
    while true; do
        echo ""
        local f_status="未配置"; iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q DNAT && f_status="运行中"
        echo -e "  ${BOLD}${CYAN}端口转发 (IX/中转/前置专用)${NC}"
        echo -e "  ${DIM}当前状态: ${WHITE}$f_status${NC}"; echo ""
        select_menu "请选择" \
            "查看当前转发规则" \
            "添加 / 覆盖全端口转发" \
            "清空所有转发规则" \
            "返回主菜单"
        case $? in
            0) port_forward_status ;;
            1) port_forward_setup ;;
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
    echo -e "  ${DIM}-> 开启 IP 转发...${NC}"
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
    echo -e "  ${DIM}-> 注入 iptables 规则...${NC}"
    iptables -t nat -D PREROUTING -p tcp --dport "$ps_ipt" -j DNAT --to-destination "${tip}:${tport_ipt}" 2>/dev/null || true
    iptables -t nat -D PREROUTING -p udp --dport "$ps_ipt" -j DNAT --to-destination "${tip}:${tport_ipt}" 2>/dev/null || true
    iptables -D FORWARD -p tcp -d "$tip" --dport "$tport_ipt" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -p udp -d "$tip" --dport "$tport_ipt" -j ACCEPT 2>/dev/null || true
    iptables -I FORWARD -p tcp -d "$tip" --dport "$tport_ipt" -j ACCEPT
    iptables -I FORWARD -p udp -d "$tip" --dport "$tport_ipt" -j ACCEPT
    if [ "$tport_ipt" = "$ps_ipt" ]; then
        iptables -t nat -A PREROUTING -p tcp --dport "$ps_ipt" -j DNAT --to-destination "$tip"
        iptables -t nat -A PREROUTING -p udp --dport "$ps_ipt" -j DNAT --to-destination "$tip"
    else
        if command -v iptables-legacy >/dev/null 2>&1; then
            iptables-legacy -t nat -A PREROUTING -p tcp --dport "$ps":"$pe" -j DNAT --to-destination "${tip}:${tport}"
            iptables-legacy -t nat -A PREROUTING -p udp --dport "$ps":"$pe" -j DNAT --to-destination "${tip}:${tport}"
        else
            echo -e "  ${YELLOW}[!] 不同端口转发需 iptables-legacy，当前不支持${NC}"
        fi
    fi
    iptables -t nat -A POSTROUTING -p tcp -d "$tip" --dport "$tport_ipt" -j MASQUERADE
    iptables -t nat -A POSTROUTING -p udp -d "$tip" --dport "$tport_ipt" -j MASQUERADE
    echo -e "  ${DIM}-> 保存并配置开机加载...${NC}"
    mkdir -p /etc/network/if-pre-up.d
    iptables-save > /etc/iptables.up.rules
    cat >/etc/network/if-pre-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.up.rules
EOF
    chmod +x /etc/network/if-pre-up.d/iptables
    echo -e "  ${GREEN}[OK] 配置成功！流量已无损转发至 $tip${NC}"
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
    echo -e "  ${GREEN}[OK] 转发规则已清空${NC}"
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
    fi
    echo ""
    apply_rps
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

    apply_sysctl_config "${role_name} (${bw}Mx${best_rtt}ms)" \
        "$(calculate_and_generate "${role_name} (${bw}Mx${best_rtt}ms)" "$bw" "$up_rtt_eff" "$bw" "$down_rtt_eff" "$h")"
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
    apply_sysctl_config "IX (${mb}Mbps)" "$(calculate_and_generate "IX (${mb}Mbps)" "$mb" "$up_rtt" "$mb" "$dn_rtt" "$h")"
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
    echo -e "  ${DIM}例: 日本 ping ~30ms / 美西 ping ~80ms / 欧洲 ping ~140ms${NC}"
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
    apply_sysctl_config "转发 (${mb}Mbps)" "$(calculate_and_generate "转发 (${mb}Mbps)" "$mb" "$ur" "$mb" "$dr" "$h")"
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
    [ -f "$PROFILE_CONF" ] && { source "$PROFILE_CONF"; echo -e "  ${GREEN}[ON]${NC} BBR: ${WHITE}$SYSCTL_PROFILE_NAME${NC}"; } || echo -e "  ${DIM}[--] BBR: 未配置${NC}"
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
        echo -e "  ${GREEN}[ON]${NC} 白名单: ${WHITE}${GEO_COUNTRIES:-启用}${NC}"
        echo -e "  拦截: ${BOLD}$(nft list chain inet geo_filter input 2>/dev/null|grep -oP 'counter packets \K[0-9]+'|tail -1||echo 0)${NC} 包"
    else echo -e "  ${DIM}[--] 白名单: 未启用${NC}"; fi
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

# ==================== BBR 内核管理 (BBR / BBR2 / BBR3) ====================

bbr_detect_version() {
    local algos=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    local current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    local kernel=$(uname -r)

    local bbr_ver="bbr1"
    if echo "$kernel" | grep -qiE 'xanmod'; then
        bbr_ver="bbr3 (XanMod)"
    elif modinfo tcp_bbr 2>/dev/null | grep -qiE 'version.*3'; then
        bbr_ver="bbr3"
    elif echo "$algos" | grep -q "bbr2"; then
        bbr_ver="bbr2"
    elif echo "$algos" | grep -q "bbr"; then
        bbr_ver="bbr1 (Linux 主线)"
    else
        bbr_ver="未支持"
    fi

    BBR_VERSION="$bbr_ver"
    BBR_CURRENT="$current"
    BBR_KERNEL="$kernel"
    BBR_AVAILABLE="$algos"
}

bbr_status_show() {
    echo ""
    echo -e "  ${BOLD}${CYAN}BBR 内核状态${NC}"
    bbr_detect_version
    echo -e "  当前内核:     ${BOLD}${BBR_KERNEL}${NC}"
    echo -e "  BBR 版本:     ${BOLD}${BBR_VERSION}${NC}"
    echo -e "  当前算法:     ${BOLD}${BBR_CURRENT}${NC}"
    echo -e "  可用算法:     ${DIM}${BBR_AVAILABLE}${NC}"
    echo ""
    if echo "$BBR_VERSION" | grep -q "bbr3"; then
        echo -e "  ${GREEN}[OK]${NC} 已支持 BBR3"
    elif echo "$BBR_VERSION" | grep -q "bbr2"; then
        echo -e "  ${YELLOW}[!]${NC} 当前 BBR2，建议升级 BBR3"
    elif echo "$BBR_VERSION" | grep -q "bbr1"; then
        echo -e "  ${YELLOW}[!]${NC} 当前 BBR1（Linux 主线版），可升级 BBR3 (XanMod 内核)"
    else
        echo -e "  ${RED}[X]${NC} 内核不支持 BBR (需要 >=4.9)"
    fi
    echo ""
}

bbr_install_xanmod() {
    echo ""; echo -e "  ${BOLD}${CYAN}安装 XanMod 内核 (BBR3)${NC}"; echo ""
    if ! command -v apt >/dev/null 2>&1; then
        echo -e "  ${RED}[X] XanMod 仅支持 Debian/Ubuntu 系${NC}"
        echo -e "  ${DIM}CentOS/RHEL 用户请考虑 ELRepo 或自行编译${NC}"
        return 1
    fi
    echo -e "  ${YELLOW}[!] 警告:${NC}"
    echo -e "  - 将更换内核，需要重启生效"
    echo -e "  - 旧内核保留，可在 GRUB 选择回退"
    echo -e "  - 容器(LXC/OpenVZ)环境无法换内核"
    echo ""
    local virt=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt 2>/dev/null)
    fi
    if [ "$virt" = "openvz" ] || [ "$virt" = "lxc" ]; then
        echo -e "  ${RED}[X] 检测到 ${virt} 容器，无法换内核${NC}"
        return 1
    fi
    [ -n "$virt" ] && [ "$virt" != "none" ] && echo -e "  ${DIM}虚拟化: $virt (KVM/Xen 等支持换内核)${NC}"
    echo ""
    confirm_action "确认安装 XanMod 内核 (BBR3)?" || return 0

    local cpu_level=""
    if grep -q ' avx512' /proc/cpuinfo 2>/dev/null; then
        cpu_level="x64v4"
    elif grep -qE ' avx2' /proc/cpuinfo 2>/dev/null; then
        cpu_level="x64v3"
    elif grep -qE ' sse4_2' /proc/cpuinfo 2>/dev/null; then
        cpu_level="x64v2"
    else
        cpu_level="x64v1"
    fi
    echo -e "  ${WHITE}CPU 等级:${NC} ${BOLD}${cpu_level}${NC}"

    echo -e "  ${DIM}1/4 添加 XanMod 仓库密钥...${NC}"
    wget -qO - https://dl.xanmod.org/archive.key 2>/dev/null | gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg 2>/dev/null
    if [ ! -f /usr/share/keyrings/xanmod-archive-keyring.gpg ]; then
        echo -e "  ${RED}[X] 下载密钥失败${NC}"
        return 1
    fi

    echo -e "  ${DIM}2/4 添加 XanMod APT 源...${NC}"
    echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' \
        > /etc/apt/sources.list.d/xanmod-release.list

    echo -e "  ${DIM}3/4 apt update...${NC}"
    apt update >/dev/null 2>&1 || { echo -e "  ${RED}[X] apt update 失败${NC}"; return 1; }

    echo -e "  ${DIM}4/4 安装 linux-xanmod-${cpu_level}...${NC}"
    DEBIAN_FRONTEND=noninteractive apt install -y "linux-xanmod-${cpu_level}" 2>&1 | tail -5
    if dpkg -l | grep -q "linux-xanmod-${cpu_level}"; then
        echo ""
        echo -e "  ${GREEN}[OK] XanMod 内核安装成功${NC}"
        echo -e "  ${YELLOW}[!] 必须重启才能生效，重启后再次运行本脚本应用 BBR3${NC}"
        echo ""
        if confirm_action "现在重启?"; then
            reboot
        fi
    else
        echo -e "  ${RED}[X] 安装失败，检查 /var/log/apt/history.log${NC}"
        return 1
    fi
}

bbr_uninstall_xanmod() {
    echo ""
    if ! dpkg -l 2>/dev/null | grep -q "linux-xanmod"; then
        echo -e "  ${DIM}未检测到 XanMod 内核，无需卸载${NC}"
        return 0
    fi
    confirm_action "卸载 XanMod 内核 (回退到发行版默认)?" || return 0
    apt purge -y 'linux-xanmod-*' 2>&1 | tail -5
    rm -f /etc/apt/sources.list.d/xanmod-release.list /usr/share/keyrings/xanmod-archive-keyring.gpg
    update-grub 2>/dev/null
    echo -e "  ${GREEN}[OK] XanMod 已卸载，重启后回到原版内核${NC}"
}

bbr_switch_algo() {
    bbr_detect_version
    local opts=()
    echo "$BBR_AVAILABLE" | grep -qw "bbr"  && opts+=("bbr (主线 BBRv1)")
    echo "$BBR_AVAILABLE" | grep -qw "bbr2" && opts+=("bbr2")
    echo "$BBR_AVAILABLE" | grep -qw "bbr3" && opts+=("bbr3")
    echo "$BBR_AVAILABLE" | grep -qw "cubic" && opts+=("cubic (回退默认)")
    opts+=("取消")
    echo ""
    select_menu "选择拥塞控制算法 (当前: $BBR_CURRENT)" "${opts[@]}"
    local sel=$?
    [ $sel -eq $(( ${#opts[@]} - 1 )) ] && return
    local target=$(echo "${opts[$sel]}" | awk '{print $1}')
    sysctl -w net.ipv4.tcp_congestion_control="$target" >/dev/null 2>&1
    if [ -f "$SYSCTL_CONF" ]; then
        sed -i "s|^net.ipv4.tcp_congestion_control = .*|net.ipv4.tcp_congestion_control = $target|" "$SYSCTL_CONF"
    fi
    echo -e "  ${GREEN}[OK]${NC} 已切换到 ${BOLD}${target}${NC}"
}

bbr_main() {
    while true; do
        bbr_status_show
        local opts=("查看当前状态" "切换 BBR 算法 (bbr/bbr2/bbr3)")
        if command -v apt >/dev/null 2>&1; then
            if dpkg -l 2>/dev/null | grep -q "linux-xanmod"; then
                opts+=("卸载 XanMod 内核")
            else
                opts+=("安装 XanMod 内核 (升级到 BBR3)")
            fi
        fi
        opts+=("返回主菜单")
        select_menu "BBR 内核管理" "${opts[@]}"
        local sel=$?
        case "${opts[$sel]}" in
            "查看当前状态") bbr_status_show ;;
            "切换 BBR 算法"*) bbr_switch_algo ;;
            "安装 XanMod"*) bbr_install_xanmod ;;
            "卸载 XanMod"*) bbr_uninstall_xanmod ;;
            "返回主菜单") return ;;
        esac
        echo -ne "  ${DIM}回车继续...${NC}"; read -r
    done
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
    echo -e "  ${GREEN}[OK] 自启已安装${NC}"
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
    for s in network-optimizer geo-whitelist rps-optimize; do systemctl disable ${s}.service 2>/dev/null; rm -f /etc/systemd/system/${s}.service; done
    systemctl daemon-reload 2>/dev/null; nft delete table inet geo_filter 2>/dev/null
    rm -f /usr/local/bin/enforce-rps.sh
    [ -f "$CONFIG_DIR/sysctl-backup.conf" ] && echo -e "  ${DIM}备份保留: $CONFIG_DIR/sysctl-backup.conf${NC}"
    rm -f "$SYSCTL_CONF" "$PROFILE_CONF" "$GEO_CONF" "$GEO_NFT"; rm -rf "$GEO_DIR"
    echo -e "  ${GREEN}已恢复${NC}"
}

# ==================== 国家白名单 ====================
geo_main() {
    while true; do
        echo ""
        echo -e "  ${BOLD}${CYAN}国家 IP 白名单${NC}"
        if nft list table inet geo_filter >/dev/null 2>&1; then
            [ -f "$GEO_CONF" ] && source "$GEO_CONF"
            echo -e "  ${GREEN}[ON]${NC} 白名单: ${WHITE}${GEO_COUNTRIES:-启用}${NC}"
        else
            echo -e "  ${DIM}[--] 白名单: 未启用${NC}"
        fi
        echo ""
        local pl="切换为禁止 Ping"
        [ -f "$GEO_CONF" ] && source "$GEO_CONF" && [ "${GEO_ALLOW_PING:-yes}" = "no" ] && pl="切换为允许 Ping"
        select_menu "请选择" \
            "查看当前状态" \
            "新建 / 修改白名单" \
            "更新 IP 库" \
            "$pl" \
            "关闭白名单" \
            "返回主菜单"
        case $? in
            0) geo_status;;
            1) geo_setup;;
            2) geo_update;;
            3) geo_toggle_ping;;
            4) geo_remove;;
            5) return;;
        esac
        echo -ne "  ${DIM}回车继续...${NC}"; read -r
    done
}

geo_setup() {
    echo ""
    command -v nft >/dev/null || { echo -e "  ${RED}需 nftables${NC}"; return; }
    command -v curl >/dev/null || { echo -e "  ${RED}需 curl${NC}"; return; }
    echo -e "  ${RED}${BOLD}[!] 确保SSH端口正确${NC}"; echo ""
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
            && echo -e "${GREEN}[OK]${NC}" || { echo -e "${RED}[X]${NC}"; ((fails++)); }; fi
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
    echo ""; echo -e "  ${BOLD}${CYAN}[ 白名单 ]${NC}"
    if nft list table inet geo_filter >/dev/null 2>&1; then
        echo -e "  ${GREEN}[ON]${NC} 启用"; [ -f "$GEO_CONF" ] && { source "$GEO_CONF"; echo -e "  $GEO_COUNTRIES | SSH:$GEO_SSH_PORT | Ping:${GEO_ALLOW_PING:-yes}"; [ -n "${GEO_LAST_UPDATE:-}" ] && echo -e "  更新: $GEO_LAST_UPDATE"; }
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
    echo -e "  ${GREEN}[OK]${NC} 已设置: ${BOLD}${label}${NC} (持久化到 $PING_CONF)"
}

ping_main() {
    while true; do
        echo ""
        echo -e "  ${BOLD}${CYAN}Ping (ICMP) 屏蔽控制${NC}"
        echo -e "  ${DIM}独立功能，不依赖国家白名单${NC}"
        local cur=$(ping_status_str)
        case "$cur" in
            "全禁") echo -e "  ${RED}[ON]${NC} 当前: 全屏蔽 (v4+v6 都不响应)";;
            "禁v4") echo -e "  ${YELLOW}[ON]${NC} 当前: 仅屏蔽 IPv4";;
            "禁v6") echo -e "  ${YELLOW}[ON]${NC} 当前: 仅屏蔽 IPv6";;
            *)      echo -e "  ${GREEN}[--]${NC} 当前: 全允许";;
        esac
        echo ""
        select_menu "请选择" \
            "查看详细状态" \
            "全屏蔽 (v4 + v6)" \
            "全允许 (v4 + v6)" \
            "仅屏蔽 IPv4 (允许 v6)" \
            "仅屏蔽 IPv6 (允许 v4)" \
            "返回主菜单"
        case $? in
            0) ping_status_show;;
            1) ping_apply 1 1 "全屏蔽 v4+v6";;
            2) ping_apply 0 0 "全允许 v4+v6";;
            3) ping_apply 1 0 "屏蔽 v4 / 允许 v6";;
            4) ping_apply 0 1 "允许 v4 / 屏蔽 v6";;
            5) return;;
        esac
        echo -ne "  ${DIM}回车继续...${NC}"; read -r
    done
}

ping_status_show() {
    echo ""
    echo -e "  ${BOLD}${CYAN}[ Ping 当前状态 ]${NC}"
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
        [ -f "$PROFILE_CONF" ] && { source "$PROFILE_CONF"; echo -e "  ${GREEN}[ON]${NC} BBR优化:  ${WHITE}$SYSCTL_PROFILE_NAME${NC}"; } || echo -e "  ${DIM}[--] BBR优化:  未配置${NC}"
        nft list table inet geo_filter >/dev/null 2>&1 && { [ -f "$GEO_CONF" ] && source "$GEO_CONF"; echo -e "  ${GREEN}[ON]${NC} 国家白名单: ${WHITE}${GEO_COUNTRIES:-启用}${NC}"; } || echo -e "  ${DIM}[--] 国家白名单: 未启用${NC}"
        local fwd_state="未启用"; iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q DNAT && fwd_state="运行中"
        [ "$fwd_state" = "运行中" ] && echo -e "  ${GREEN}[ON]${NC} 端口转发:  ${WHITE}${fwd_state}${NC}" || echo -e "  ${DIM}[--] 端口转发:  ${fwd_state}${NC}"
        local pcur=$(ping_status_str)
        case "$pcur" in
            "全允许") echo -e "  ${DIM}[--] Ping屏蔽:  全允许${NC}";;
            *)       echo -e "  ${GREEN}[ON]${NC} Ping屏蔽:  ${WHITE}${pcur}${NC}";;
        esac
        local al="安装开机自启"; systemctl is-enabled network-optimizer.service >/dev/null 2>&1 && { echo -e "  ${GREEN}[ON]${NC} 开机自启:  启用"; al="关闭开机自启"; } || echo -e "  ${DIM}[--] 开机自启:  未启用${NC}"
        get_meminfo
        echo -e "  ${DIM}     系统内存:  $(( MEM_TOTAL_KB/1024 ))M  Swap $(( SWAP_TOTAL_KB/1024 ))M${NC}"
        echo ""
        bbr_detect_version
        select_menu "请选择操作" \
            "一键自动配置 (中转与落地高延迟请用手动链路)" \
            "手动链路向导" \
            "BBR 内核管理 (当前: ${BBR_VERSION%% *})" \
            "端口转发" \
            "国家白名单" \
            "Ping 屏蔽控制 (当前: ${pcur})" \
            "查看系统状态" \
            "查看端口连接" \
            "刷新当前配置" \
            "$al" \
            "恢复系统默认" \
            "退出"
        case $? in
            0)  auto_max_performance ;;
            1)  wizard_main ;;
            2)  bbr_main; continue ;;
            3)  port_forward_main ;;
            4)  geo_main; continue ;;
            5)  ping_main; continue ;;
            6)  show_status ;;
            7)  port_monitor; continue ;;
            8)  reload_network ;;
            9)  toggle_service ;;
            10) restore_defaults ;;
            11) rst; exit 0 ;;
        esac
        echo ""
        echo -ne "  ${DIM}回车返回主菜单...${NC}"; read -r
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
    bbr-status) bbr_status_show;;
    bbr3-install) bbr_install_xanmod;;
    bbr3-remove) bbr_uninstall_xanmod;;
    ports) port_all;; ports-rank) port_rank;; "") interactive_main;;
    *) echo "$VERSION | $0 [auto|wizard|status|ports|install|restore|geo-update|geo-remove|ping-block|ping-allow|ping-status|bbr-status|bbr3-install|bbr3-remove]"; exit 1;;
esac
