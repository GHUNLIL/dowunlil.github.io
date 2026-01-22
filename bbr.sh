#!/bin/bash
# 一键 sysctl 配置（适配 Debian 13 及旧版本兼容）

SYSCTL_FILE="/etc/sysctl.d/50-bbr.conf"
BBR_MODULE_FILE="/etc/modules-load.d/bbr.conf"

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; NC="\033[0m"

enable_bbr_module() {
    echo -e "${YELLOW}正在启用 BBR 模块...${NC}"

    # 写入模块加载文件（防重复）
    if [ ! -f "$BBR_MODULE_FILE" ] || ! grep -q "tcp_bbr" "$BBR_MODULE_FILE"; then
        echo "tcp_bbr" | sudo tee "$BBR_MODULE_FILE" >/dev/null
        echo -e "${GREEN}已写入 ${BBR_MODULE_FILE}${NC}"
    else
        echo -e "${GREEN}BBR 模块已存在，无需重复添加。${NC}"
    fi

    # 立即加载 BBR
    modprobe tcp_bbr 2>/dev/null && \
        echo -e "${GREEN}BBR 模块已立即加载。${NC}" || \
        echo -e "${RED}modprobe 加载 BBR 失败，可能是内核不支持。${NC}"
}

reload_sysctl() {
    echo -e "${YELLOW}正在应用 sysctl 配置（systemd-sysctl）...${NC}"
    sysctl --system >/dev/null 2>&1
    echo -e "${GREEN}配置已生效。${NC}"
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
    echo -e "${GREEN}香港机配置已生效。${NC}"
}

set_nonhk() {
    echo -e "${YELLOW}应用非香港机配置...${NC}"

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
    echo -e "${GREEN}非香港机配置已生效。${NC}"
}

edit() {
    echo -e "${YELLOW}输入新配置，Ctrl+D 保存:${NC}"
    cat > $SYSCTL_FILE
    reload_sysctl
    echo -e "${GREEN}配置已更新。${NC}"
}

view() {
    echo -e "${YELLOW}当前配置文件 ($SYSCTL_FILE):${NC}"
    echo "--------------------------------"
    [ -f "$SYSCTL_FILE" ] && cat $SYSCTL_FILE || echo -e "${RED}文件不存在。${NC}"
    echo "--------------------------------"
}

menu() {
    echo -e "${YELLOW}请选择操作:${NC}"
    echo "1) 手动编辑"
    echo "2) 一键香港机配置"
    echo "3) 一键日本机配置"
    echo "4) 查看当前配置"
    echo "0) 退出"
}

while true; do
    menu
    read -p "输入选项: " c
    case $c in
        1) edit ;;
        2) set_hk ;;
        3) set_nonhk ;;
        4) view ;;
        0) exit 0 ;;
        *) echo -e "${RED}无效选项。${NC}" ;;
    esac
done
