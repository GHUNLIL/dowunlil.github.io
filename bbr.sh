#!/bin/bash
# 一键 sysctl 配置家宽服务器不丢ipv6版 - 增加 5M 极限加速版

SYSCTL_FILE="/etc/sysctl.d/50-bbr.conf"
BBR_MODULE_FILE="/etc/modules-load.d/bbr.conf"

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; NC="\033[0m"

enable_bbr_module() {
    echo -e "${YELLOW}正在启用 BBR 模块...${NC}"
    if [ ! -f "$BBR_MODULE_FILE" ] || ! grep -q "tcp_bbr" "$BBR_MODULE_FILE"; then
        echo "tcp_bbr" | sudo tee "$BBR_MODULE_FILE" >/dev/null
        echo -e "${GREEN}已写入 ${BBR_MODULE_FILE}${NC}"
    else
        echo -e "${GREEN}BBR 模块已存在。${NC}"
    fi
    modprobe tcp_bbr 2>/dev/null
}

reload_sysctl() {
    echo -e "${YELLOW}正在应用 sysctl 配置...${NC}"
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}配置已生效。${NC}"
}

# 5Mbps 专用：防拥塞+网页高并发优化
set_shanghai_5m() {
    echo -e "${YELLOW}应用上海 5Mbps 极限加速配置...${NC}"
    enable_bbr_module
    cat > $SYSCTL_FILE <<EOF
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
# 限制缓冲区防止 Bufferbloat，保证 6ms 低延迟不抖动
net.ipv4.tcp_rmem = 4096 8192 262144
net.ipv4.tcp_wmem = 4096 8192 262144
net.core.rmem_max = 524288
net.core.wmem_max = 524288
# 提升并发处理能力
net.core.somaxconn = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 20000
# 快速回收连接，适合网页刷新
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
kernel.panic = -1
vm.swappiness = 0
EOF
    reload_sysctl
}

set_hk() {
    echo -e "${YELLOW}应用香港机配置...${NC}"
    enable_bbr_module
    cat > $SYSCTL_FILE <<EOF
net.core.default_qdisc = fq
net.core.rmem_max = 67108848
net.core.wmem_max = 67108848
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
kernel.panic = -1
vm.swappiness = 0
EOF
    reload_sysctl
}

set_nonhk() {
    echo -e "${YELLOW}应用非香港机/大带宽配置...${NC}"
    enable_bbr_module
    cat > $SYSCTL_FILE <<EOF
net.core.default_qdisc = fq
net.core.rmem_max = 67108848
net.core.wmem_max = 67108848
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 16384 16777216 536870912
net.ipv4.tcp_wmem = 16384 16777216 536870912
net.ipv4.tcp_adv_win_scale = -2
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
kernel.panic = -1
vm.swappiness = 0
EOF
    reload_sysctl
}

edit() {
    echo -e "${YELLOW}输入新配置，Ctrl+D 保存:${NC}"
    cat > $SYSCTL_FILE
    reload_sysctl
}

view() {
    echo -e "${YELLOW}当前配置文件 ($SYSCTL_FILE):${NC}"
    [ -f "$SYSCTL_FILE" ] && cat $SYSCTL_FILE || echo -e "${RED}文件不存在。${NC}"
}

menu() {
    echo -e "${YELLOW}请选择操作:${NC}"
    echo "1) 手动编辑"
    echo "2) 一键香港机配置 (中等带宽)"
    echo "3) 一键日本/大带宽配置 (DMIT可用)"
    echo "4) 一键上海 5M 极限加速配置 (小带宽入口专供)"
    echo "5) 查看当前配置"
    echo "0) 退出"
}

while true; do
    menu
    read -p "输入选项: " c
    case $c in
        1) edit ;;
        2) set_hk ;;
        3) set_nonhk ;;
        4) set_shanghai_5m ;;
        5) view ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项。${NC}" ;;
    esac
done
