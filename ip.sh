#!/bin/bash
# ============================================================
# Debian 13 VPS 防火墙安全精简版
# IPv4 + IPv6 | 国家 + ASN
# SSH 22 永远放行 | 手动更新
# ============================================================

Green="\033[32m"
Yellow="\033[33m"
Red="\033[31m"
Font="\033[0m"

WORKDIR="/etc/vps-fw"
COUNTRY_FILE="$WORKDIR/countries.conf"
ASN_FILE="$WORKDIR/asn.conf"

root_need(){
    if [[ $EUID -ne 0 ]]; then
        echo -e "${Red}必须使用 root 运行${Font}"
        exit 1
    fi
}

check_tools(){
    echo -e "${Yellow}检查依赖...${Font}"
    apt update -y || true
    apt install -y iptables ipset whois wget || true
}

pause(){
    read -p "按回车继续..."
}

# ============================================================
# 更新国家 IP（IPv4 + IPv6）
update_country(){
    echo -e "${Yellow}更新 国家 IP (IPv4 + IPv6)...${Font}"
    ipset destroy allow_region4 2>/dev/null
    ipset destroy allow_region6 2>/dev/null
    ipset create allow_region4 hash:net family inet -exist
    ipset create allow_region6 hash:net family inet6 -exist

    while read cc; do
        cc=$(echo "$cc" | tr 'A-Z' 'a-z')
        # IPv4
        wget -q -O /tmp/${cc}.zone http://www.ipdeny.com/ipblocks/data/countries/${cc}.zone || continue
        while read ip; do ipset add allow_region4 "$ip" -exist; done < /tmp/${cc}.zone
        rm -f /tmp/${cc}.zone
        # IPv6
        wget -q -O /tmp/${cc}.zone6 http://www.ipdeny.com/ipv6/ipaddresses/blocks/${cc}.zone || continue
        while read ip; do ipset add allow_region6 "$ip" -exist; done < /tmp/${cc}.zone6
        rm -f /tmp/${cc}.zone6
    done < "$COUNTRY_FILE"
    echo -e "${Green}国家 IP 更新完成${Font}"
    pause
}

# ============================================================
# 更新 ASN（IPv4 + IPv6）
update_asn(){
    echo -e "${Yellow}更新 ASN (IPv4 + IPv6)...${Font}"
    ipset destroy asn_allow4 2>/dev/null
    ipset destroy asn_allow6 2>/dev/null
    ipset create asn_allow4 hash:net family inet -exist
    ipset create asn_allow6 hash:net family inet6 -exist

    while read asn; do
        whois -h whois.radb.net -- "-i origin $asn" | awk '/^route:/ {print $2}' | while read net; do ipset add asn_allow4 "$net" -exist; done
        whois -h whois.radb.net -- "-i origin $asn" | awk '/^route6:/ {print $2}' | while read net; do ipset add asn_allow6 "$net" -exist; done
    done < "$ASN_FILE"
    echo -e "${Green}ASN 更新完成${Font}"
    pause
}

# ============================================================
# 应用防火墙规则
apply_rules(){
    echo -e "${Yellow}应用 IPv4 / IPv6 防火墙规则...${Font}"
    for CMD in iptables ip6tables; do
        $CMD -F
        $CMD -X
        $CMD -P INPUT DROP
        $CMD -P FORWARD DROP
        $CMD -P OUTPUT ACCEPT
        $CMD -A INPUT -p tcp --dport 22 -j ACCEPT
        $CMD -A INPUT -i lo -j ACCEPT
        $CMD -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    done
    # IPv4 ipset
    ipset list asn_allow4 &>/dev/null && iptables -A INPUT -m set --match-set asn_allow4 src -j ACCEPT
    ipset list allow_region4 &>/dev/null && iptables -A INPUT -m set --match-set allow_region4 src -j ACCEPT
    # IPv6 ipset
    ipset list asn_allow6 &>/dev/null && ip6tables -A INPUT -m set --match-set asn_allow6 src -j ACCEPT
    ipset list allow_region6 &>/dev/null && ip6tables -A INPUT -m set --match-set allow_region6 src -j ACCEPT
    echo -e "${Green}规则已生效${Font}"
    pause
}

# ============================================================
# 清空规则
clear_all(){
    iptables -F
    ip6tables -F
    iptables -P INPUT ACCEPT
    ip6tables -P INPUT ACCEPT
    ipset destroy allow_region4 2>/dev/null
    ipset destroy allow_region6 2>/dev/null
    ipset destroy asn_allow4 2>/dev/null
    ipset destroy asn_allow6 2>/dev/null
    echo -e "${Red}已清空所有规则${Font}"
    pause
}

# ============================================================
# 主菜单
main_menu(){
while true; do
    clear
    echo "===================================="
    echo " VPS 防火墙 Debian 13 精简版"
    echo "===================================="
    echo "1) 设置允许国家 / ASN"
    echo "2) 更新 IP 列表"
    echo "3) 应用防火墙规则"
    echo "4) 清空所有规则"
    echo "0) 退出"
    read -p "选择: " n
    case "$n" in
        1)
            echo "国家代码(如 cn us jp):"
            read -p "> " c
            mkdir -p "$WORKDIR"
            echo "$c" | tr ' ' '\n' > "$COUNTRY_FILE"
            echo "ASN(如 AS4134 AS4837):"
            read -p "> " a
            echo "$a" | tr ' ' '\n' > "$ASN_FILE"
            ;;
        2)
            update_country
            update_asn
            ;;
        3)
            apply_rules
            ;;
        4)
            clear_all
            ;;
        0) exit ;;
        *) echo "请输入正确选项"; sleep 2 ;;
    esac
done
}

# ============================================================
root_need
mkdir -p "$WORKDIR"
check_tools
main_menu
