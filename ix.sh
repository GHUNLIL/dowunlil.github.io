#!/bin/bash

#=====================#
#  1. Configuration   #
#=====================#

TARGET_IP="IX的IP"
PORT_START=23
PORT_END=65535

echo "-----------------------------------"
echo "Target IP: $TARGET_IP"
echo "Port Range: $PORT_START-$PORT_END (TCP & UDP)"
echo "Mode: nftables (Modern Kernel Forwarding)"
echo "-----------------------------------"

#=====================#
#  2. Kernel Tuning   #
#=====================#

echo "Forcing IP Forwarding at Kernel Level..."
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/99-ipforward.conf
sysctl -p /etc/sysctl.d/99-ipforward.conf > /dev/null

#=====================#
#  3. Install nftables#
#=====================#

echo "Installing and enabling nftables..."
if [ -x "$(command -v apt)" ]; then
    apt update -yqq && apt install -y nftables
elif [ -x "$(command -v yum)" ]; then
    yum install -y nftables
fi

systemctl enable nftables
systemctl start nftables

#=====================#
#  4. Apply Rules     #
#=====================#

echo "Writing native nftables rules..."

# Generate the nftables configuration file
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f

flush ruleset

table ip filter {
    chain forward {
        type filter hook forward priority 0; policy accept;
    }
}

table ip nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport ${PORT_START}-${PORT_END} dnat to ${TARGET_IP}
        udp dport ${PORT_START}-${PORT_END} dnat to ${TARGET_IP}
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr ${TARGET_IP} tcp dport ${PORT_START}-${PORT_END} masquerade
        ip daddr ${TARGET_IP} udp dport ${PORT_START}-${PORT_END} masquerade
    }
}
EOF

echo "Loading rules into kernel..."
nft -f /etc/nftables.conf

echo "==================================="
echo "nftables configuration forced and applied!"
echo "==================================="
