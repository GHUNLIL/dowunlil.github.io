#!/bin/bash

#===============#
#  配置参数区域  #
#===============#

TARGET_IP="103.177.163.128"
PORT_START=23
PORT_END=65000

# 获取本机出口 IP
LOCAL_IP=$(ip route get 1 | awk '{print $7; exit}')

echo "本地出口IP: $LOCAL_IP"
echo "目标IP: $TARGET_IP"
echo "端口范围: $PORT_START-$PORT_END"

#===============#
#  开启 IP 转发  #
#===============#

echo "开启 IP 转发..."
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
sysctl -p

#===============#
#  添加转发规则  #
#===============#

echo "添加 iptables 规则..."

# 清除旧规则（可选）
iptables -t nat -F

# PREROUTING 规则（进入流量 → 目标 IP）
iptables -t nat -A PREROUTING -p tcp --dport ${PORT_START}:${PORT_END} -j DNAT --to-destination ${TARGET_IP}
iptables -t nat -A PREROUTING -p udp --dport ${PORT_START}:${PORT_END} -j DNAT --to-destination ${TARGET_IP}

# POSTROUTING（出站 SNAT，让回包走 VPS）
iptables -t nat -A POSTROUTING -p tcp -d ${TARGET_IP} --dport ${PORT_START}:${PORT_END} -j SNAT --to-source ${LOCAL_IP}
iptables -t nat -A POSTROUTING -p udp -d ${TARGET_IP} --dport ${PORT_START}:${PORT_END} -j SNAT --to-source ${LOCAL_IP}

#===============#
#   保存规则     #
#===============#

echo "保存规则到 /etc/iptables.up.rules ..."
iptables-save > /etc/iptables.up.rules

# 自动加载（Debian）
cat >/etc/network/if-pre-up.d/iptables <<EOF
#!/bin/sh
iptables-restore < /etc/iptables.up.rules
EOF

chmod +x /etc/network/if-pre-up.d/iptables

echo "配置完成！规则已永久生效。"
