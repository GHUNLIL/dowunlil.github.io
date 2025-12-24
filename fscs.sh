#!/bin/bash
# ============================================================
# 一键管理脚本：封锁 BT / 挖矿 / 测速 流量关键字
# 支持 install / uninstall / reload / watchdog
# ============================================================

SCRIPT_PATH="/usr/local/bin/block-bt-mining-speedtest.sh"
SERVICE_PATH="/etc/systemd/system/block-bt.service"
WATCHDOG_SERVICE="/etc/systemd/system/block-bt-watchdog.service"

RULES=(
"torrent" ".torrent" "peer_id=" "announce" "info_hash" "get_peers" "find_node"
"BitTorrent" "announce_peer" "BitTorrent protocol" "announce.php?passkey=" "magnet:"
"xunlei" "sandai" "Thunder" "XLLiveUD" "ethermine.com" "antpool.one" "antpool.com"
"pool.bar" "seed_hash" ".speed" "speed." ".speed." "fast.com" "speedtest.net"
"speedtest.com" "speedtest.cn" "test.ustc.edu.cn" "10000.gd.cn" "db.laomoe.com"
"jiyou.cloud" "ovo.speedtestcustom.com" "speed.cloudflare.com" "speedtest"
)

create_main_script() {
cat > "$SCRIPT_PATH" <<'EOF'
#!/bin/bash
RULES=(
"torrent" ".torrent" "peer_id=" "announce" "info_hash" "get_peers" "find_node"
"BitTorrent" "announce_peer" "BitTorrent protocol" "announce.php?passkey=" "magnet:"
"xunlei" "sandai" "Thunder" "XLLiveUD" "ethermine.com" "antpool.one" "antpool.com"
"pool.bar" "seed_hash" ".speed" "speed." ".speed." "fast.com" "speedtest.net"
"speedtest.com" "speedtest.cn" "test.ustc.edu.cn" "10000.gd.cn" "db.laomoe.com"
"jiyou.cloud" "ovo.speedtestcustom.com" "speed.cloudflare.com" "speedtest"
)

# 删除旧规则
for str in "${RULES[@]}"; do
    iptables -D OUTPUT -m string --string "$str" --algo bm -j DROP 2>/dev/null || true
    ip6tables -D OUTPUT -m string --string "$str" --algo bm -j DROP 2>/dev/null || true
done

# 添加新规则
for str in "${RULES[@]}"; do
    iptables -A OUTPUT -m string --string "$str" --algo bm -j DROP
    ip6tables -A OUTPUT -m string --string "$str" --algo bm -j DROP
done

echo "✅ 已应用屏蔽规则 (IPv4 + IPv6)"
EOF
chmod +x "$SCRIPT_PATH"
}

create_service() {
cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=Block BitTorrent / Mining / Speedtest Traffic
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

create_watchdog() {
cat > "$WATCHDOG_SERVICE" <<EOF
[Unit]
Description=BT Blocker Auto Restore
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'while true; do
    if ! iptables -L OUTPUT | grep -q "BitTorrent"; then
        echo "⚠️ 检测到规则缺失，正在恢复..."
        bash $SCRIPT_PATH
    fi
    sleep 60
done'

[Install]
WantedBy=multi-user.target
EOF
}

install_rules() {
    echo "🔧 正在安装屏蔽规则..."
    if ! command -v iptables >/dev/null; then
        if command -v apt >/dev/null; then
            apt update -y && apt install -y iptables
        elif command -v yum >/dev/null; then
            yum install -y iptables
        fi
    fi

    create_main_script
    create_service

    systemctl daemon-reload
    systemctl enable block-bt.service
    systemctl start block-bt.service
    echo "🚀 已启用封锁服务"
}

uninstall_rules() {
    echo "🧹 正在卸载规则与服务..."
    systemctl stop block-bt.service 2>/dev/null || true
    systemctl disable block-bt.service 2>/dev/null || true
    systemctl stop block-bt-watchdog.service 2>/dev/null || true
    systemctl disable block-bt-watchdog.service 2>/dev/null || true
    rm -f "$SCRIPT_PATH" "$SERVICE_PATH" "$WATCHDOG_SERVICE"
    systemctl daemon-reload

    for str in "${RULES[@]}"; do
        iptables -D OUTPUT -m string --string "$str" --algo bm -j DROP 2>/dev/null || true
        ip6tables -D OUTPUT -m string --string "$str" --algo bm -j DROP 2>/dev/null || true
    done

    echo "✅ 已清除所有屏蔽规则和服务"
}

reload_rules() {
    echo "♻️ 重新加载规则..."
    bash "$SCRIPT_PATH"
}

enable_watchdog() {
    echo "🛡️ 启用自动恢复守护功能..."
    create_watchdog
    systemctl daemon-reload
    systemctl enable block-bt-watchdog.service
    systemctl start block-bt-watchdog.service
    echo "✅ 守护已启动，每分钟检测规则是否丢失"
}

disable_watchdog() {
    echo "⛔ 停用自动恢复守护..."
    systemctl stop block-bt-watchdog.service 2>/dev/null || true
    systemctl disable block-bt-watchdog.service 2>/dev/null || true
    rm -f "$WATCHDOG_SERVICE"
    systemctl daemon-reload
    echo "✅ 守护功能已关闭"
}

case "$1" in
    install)
        install_rules
        ;;
    uninstall)
        uninstall_rules
        ;;
    reload)
        reload_rules
        ;;
    watchdog)
        enable_watchdog
        ;;
    stopwatch)
        disable_watchdog
        ;;
    *)
        echo "用法：$0 {install|uninstall|reload|watchdog|stopwatch}"
        echo "说明："
        echo "  install   安装并启用封锁规则"
        echo "  uninstall 卸载规则与服务"
        echo "  reload    手动重载规则"
        echo "  watchdog  开启自动检测与恢复"
        echo "  stopwatch 停止自动检测"
        ;;
esac
