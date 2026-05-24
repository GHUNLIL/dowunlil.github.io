#!/usr/bin/env bash
set -euo pipefail

VERSION="2026.05.24"
MIB=1048576
GIB=$((1024 * MIB))
AUTO_TCP_CAP=$((2047 * MIB))

ROLE=""
SCENE=""
TARGET="speed"
BUSINESS="mixed"
STATEFUL="yes"
LANDING_ROUTES="no"
IPV6_RA="ask"
MULTIPATH="yes"
HANDSHAKE="yes"
TFO_GLOBAL="no"
LOCAL_TCP_TERMINATION="auto"
BUSY_MODE="auto"
APPLY_MODE="ask"
UI_MODE="menu"
OUT_DIR=""

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

if [[ -t 1 && -n "${TERM:-}" && "${TERM:-}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
  BOLD=$(tput bold || true)
  DIM=$(tput dim || true)
  RED=$(tput setaf 1 || true)
  GREEN=$(tput setaf 2 || true)
  YELLOW=$(tput setaf 3 || true)
  BLUE=$(tput setaf 4 || true)
  CYAN=$(tput setaf 6 || true)
  RESET=$(tput sgr0 || true)
else
  BOLD=""
  DIM=""
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  CYAN=""
  RESET=""
fi

hr() {
  printf '%*s\n' "${COLUMNS:-80}" '' | tr ' ' '-'
}

pause_ui() {
  local _
  read -r -p "按 Enter 继续..." _ || true
}

clear_ui() {
  if [[ -t 1 ]]; then
    printf '\033[H\033[2J'
  fi
}

banner() {
  clear_ui
  printf '%sNetwork BBR Optimizer%s  %s%s%s\n' "$BOLD" "$RESET" "$CYAN" "$VERSION" "$RESET"
  printf '目标: 极致满速 + 可控低抖动 | 默认不启用应用层 mux\n'
  hr
}

yn_label() {
  [[ "${1:-no}" == "yes" ]] && printf '是' || printf '否'
}

role_label() {
  case "${ROLE:-forwarding}" in
    forwarding) printf '转发节点' ;;
    landing) printf '落地节点' ;;
    *) printf '%s' "$ROLE" ;;
  esac
}

scene_label() {
  case "${SCENE:-plain}" in
    front) printf '前置入口' ;;
    ix) printf 'IX 专线' ;;
    relay) printf '线路中继' ;;
    international) printf '国际互联' ;;
    plain) printf '普通 nftables 转发' ;;
    landing) printf '落地' ;;
    *) printf '%s' "$SCENE" ;;
  esac
}

target_label() {
  case "${TARGET:-speed}" in
    speed) printf '极致满速' ;;
    throughput) printf '极致吞吐' ;;
    *) printf '%s' "$TARGET" ;;
  esac
}

business_label() {
  case "${BUSINESS:-mixed}" in
    mixed) printf '混合代理/中转' ;;
    tcp) printf 'TCP 长连接' ;;
    udp_game) printf 'UDP 游戏/实时' ;;
    web) printf 'Web/HTTPS' ;;
    *) printf '%s' "$BUSINESS" ;;
  esac
}

show_summary() {
  printf '%s当前参数%s\n' "$BOLD" "$RESET"
  printf '  角色/场景      : %s / %s\n' "$(role_label)" "$(scene_label)"
  printf '  目标/业务      : %s / %s\n' "$(target_label)" "$(business_label)"
  printf '  带宽 Mbps      : 上行 %s / 下行 %s\n' "$UP_MBPS" "$DOWN_MBPS"
  printf '  RTT ms         : 上游 %s / 下游 %s\n' "$UP_RTT" "$DOWN_RTT"
  printf '  丢包/抖动      : %s%% / %sms\n' "$LOSS_PCT" "$JITTER_MS"
  printf '  网卡/队列      : %s / RX %s / TX %s / CPU %s\n' "$DEFAULT_IFACE" "$RX_QUEUES" "$TX_QUEUES" "$CPU_COUNT"
  printf '  转发状态       : stateful=%s, landing_routes=%s, multipath=%s, ipv6_ra=%s\n' \
    "$(yn_label "$STATEFUL")" "$(yn_label "$LANDING_ROUTES")" "$(yn_label "$MULTIPATH")" "$(yn_label "$IPV6_RA")"
  printf '  握手优化       : TFO=%s, local_tcp=%s, global_tfo=%s, busy_poll=%s\n' \
    "$(yn_label "$HANDSHAKE")" "$(yn_label "$LOCAL_TCP_TERMINATION")" "$(yn_label "$TFO_GLOBAL")" "$BUSY_MODE"
  printf '  手动覆盖       : tcp_cap=%sMB, bdp_mult=%s, tcp=%s, udp=%s, cps=%s\n' \
    "$MANUAL_TCP_CAP_MB" "$MANUAL_BDP_MULT" "$TCP_CONNS_OVERRIDE" "$UDP_SESSIONS_OVERRIDE" "$CPS_OVERRIDE"
  [[ -n "$SERVICE_NAME" ]] && printf '  服务 nofile    : %s\n' "$SERVICE_NAME"
}

edit_role_scene() {
  banner
  printf '%s角色与场景%s\n' "$BOLD" "$RESET"
  ROLE=$(ask_choice "机器角色 forwarding=转发 landing=落地" "$ROLE" forwarding landing)
  if [[ "$ROLE" == "forwarding" ]]; then
    SCENE=$(ask_choice "转发场景 front/ix/relay/international/plain" "${SCENE:-plain}" front ix relay international plain)
    STATEFUL=$(ask_yes_no "是否 NAT/TProxy/状态 nftables 规则" "$STATEFUL")
    LANDING_ROUTES="no"
    LOCAL_TCP_TERMINATION=$(ask_yes_no "这台转发机是否也终止 TCP，例如还有代理/Web listener" "$LOCAL_TCP_TERMINATION")
  else
    SCENE="landing"
    LANDING_ROUTES=$(ask_yes_no "落地机是否同时做 NAT/路由" "$LANDING_ROUTES")
    [[ "$LANDING_ROUTES" == "yes" ]] && STATEFUL="yes" || STATEFUL="no"
    LOCAL_TCP_TERMINATION=$(ask_yes_no "落地机是否本机终止 TCP，例如 Xray/Web/代理 listener" "$LOCAL_TCP_TERMINATION")
  fi
  TARGET=$(ask_choice "优化目标 speed=极致满速 throughput=极致吞吐" "$TARGET" speed throughput)
  BUSINESS=$(ask_choice "业务类型 mixed/tcp/udp_game/web" "$BUSINESS" mixed tcp udp_game web)
}

edit_link() {
  banner
  printf '%s链路参数%s\n' "$BOLD" "$RESET"
  UP_MBPS=$(to_int "$(ask "上行/入口 Mbps" "$UP_MBPS")")
  DOWN_MBPS=$(to_int "$(ask "下行/出口 Mbps" "$DOWN_MBPS")")
  UP_RTT=$(to_int "$(ask "上游 RTT ms" "$UP_RTT")")
  DOWN_RTT=$(to_int "$(ask "下游 RTT ms" "$DOWN_RTT")")
  LOSS_PCT=$(ask "丢包率百分比，例如 0 或 0.3" "$LOSS_PCT")
  JITTER_MS=$(to_int "$(ask "抖动 ms" "$JITTER_MS")")
  MULTIPATH=$(ask_yes_no "是否多出口/策略路由/非对称回程" "$MULTIPATH")
  IPV6_RA=$(ask_yes_no "IPv6 默认路由是否依赖 RA" "$IPV6_RA")
}

edit_runtime() {
  banner
  printf '%s网卡与运行时%s\n' "$BOLD" "$RESET"
  CPU_COUNT=$(to_int "$(ask "CPU 核数" "$CPU_COUNT")")
  DEFAULT_IFACE=$(ask "主网卡 interface" "$DEFAULT_IFACE")
  RX_QUEUES=$(to_int "$(ask "RX 队列数" "$RX_QUEUES")")
  TX_QUEUES=$(to_int "$(ask "TX 队列数" "$TX_QUEUES")")
  BUSY_MODE=$(ask_choice "busy_poll 模式 auto/force/off" "$BUSY_MODE" auto force off)
}

edit_handshake() {
  banner
  printf '%s握手与应用层选项%s\n' "$BOLD" "$RESET"
  HANDSHAKE=$(ask_yes_no "是否启用 TFO 等建连优化" "$HANDSHAKE")
  LOCAL_TCP_TERMINATION=$(ask_yes_no "本机是否终止 TCP" "$LOCAL_TCP_TERMINATION")
  TFO_GLOBAL=$(ask_yes_no "是否启用全局 listener TFO 1024 bit" "$TFO_GLOBAL")
  printf '\n应用层 mux/smux/yamux/multiplex 默认不启用，本脚本不会写 mux 配置。\n'
  pause_ui
}

edit_capacity() {
  banner
  printf '%s容量与高级覆盖%s\n' "$BOLD" "$RESET"
  TCP_CONNS_OVERRIDE=$(to_int "$(ask "TCP 并发覆盖，0=自动" "$TCP_CONNS_OVERRIDE")")
  UDP_SESSIONS_OVERRIDE=$(to_int "$(ask "UDP 会话覆盖，0=自动" "$UDP_SESSIONS_OVERRIDE")")
  CPS_OVERRIDE=$(to_int "$(ask "每秒新建连接覆盖，0=自动" "$CPS_OVERRIDE")")
  MANUAL_TCP_CAP_MB=$(to_int "$(ask "单连接 tcp_max 上限 MB，0=自动" "$MANUAL_TCP_CAP_MB")")
  MANUAL_BDP_MULT=$(to_int "$(ask "BDP 倍数覆盖，0=自动" "$MANUAL_BDP_MULT")")
  BBR_KIND=$(ask_choice "BBR 版本假设 bbr1/bbr3/unknown" "$BBR_KIND" bbr1 bbr3 unknown)
  SERVICE_NAME=$(ask "可选 systemd 服务名，用于 LimitNOFILE drop-in，空=跳过" "$SERVICE_NAME")
}

interactive_menu() {
  local choice
  while true; do
    banner
    show_summary
    hr
    printf '  1) 角色/场景/业务\n'
    printf '  2) 链路带宽/RTT/丢包抖动\n'
    printf '  3) 网卡/RPS/busy_poll\n'
    printf '  4) TFO/握手优化/应用层说明\n'
    printf '  5) 并发容量/高级覆盖\n'
    printf '  6) 生成配置\n'
    printf '  7) 退出\n'
    read -r -p "请选择 [6]: " choice || true
    choice="${choice:-6}"
    case "$choice" in
      1) edit_role_scene ;;
      2) edit_link ;;
      3) edit_runtime ;;
      4) edit_handshake ;;
      5) edit_capacity ;;
      6) break ;;
      7|q|Q) exit 0 ;;
      *) warn "无效选择"; pause_ui ;;
    esac
  done
}

linear_wizard() {
  ROLE=$(ask_choice "Role: forwarding or landing" "$ROLE" forwarding landing)
  if [[ "$ROLE" == "forwarding" ]]; then
    SCENE=$(ask_choice "Forwarding scene: front, ix, relay, international, plain" "$SCENE" front ix relay international plain)
    STATEFUL=$(ask_yes_no "Does this node use NAT/TProxy/stateful nftables rules?" "$STATEFUL")
    LANDING_ROUTES="no"
  else
    SCENE="landing"
    LANDING_ROUTES=$(ask_yes_no "Does this landing node also do NAT/routing?" "$LANDING_ROUTES")
    [[ "$LANDING_ROUTES" == "yes" ]] && STATEFUL="yes" || STATEFUL="no"
  fi

  TARGET=$(ask_choice "Target: speed or throughput" "$TARGET" speed throughput)
  BUSINESS=$(ask_choice "Business: mixed, tcp, udp_game, web" "$BUSINESS" mixed tcp udp_game web)

  UP_MBPS=$(to_int "$(ask "Upstream/upload Mbps" "$UP_MBPS")")
  DOWN_MBPS=$(to_int "$(ask "Downstream/download Mbps" "$DOWN_MBPS")")
  UP_RTT=$(to_int "$(ask "Upstream RTT ms" "$UP_RTT")")
  DOWN_RTT=$(to_int "$(ask "Downstream RTT ms" "$DOWN_RTT")")
  LOSS_PCT=$(ask "Loss percent, e.g. 0 or 0.3" "$LOSS_PCT")
  JITTER_MS=$(to_int "$(ask "Jitter ms" "$JITTER_MS")")

  CPU_COUNT=$(to_int "$(ask "CPU cores" "$CPU_COUNT")")
  DEFAULT_IFACE=$(ask "Primary interface for txqueuelen/RPS" "$DEFAULT_IFACE")
  RX_QUEUES=$(to_int "$(ask "RX queue count" "$RX_QUEUES")")
  TX_QUEUES=$(to_int "$(ask "TX queue count" "$TX_QUEUES")")

  MULTIPATH=$(ask_yes_no "Multi-path, policy routing, or asymmetric return?" "$MULTIPATH")
  IPV6_RA=$(ask_yes_no "Does IPv6 default route depend on RA on this interface?" "$IPV6_RA")
  HANDSHAKE=$(ask_yes_no "Enable handshake optimizations where applicable, e.g. TFO?" "$HANDSHAKE")
  if [[ "$ROLE" == "landing" ]]; then
    LOCAL_TCP_TERMINATION=$(ask_yes_no "Does this node terminate TCP locally, e.g. Xray/Web/proxy listener?" "$LOCAL_TCP_TERMINATION")
  else
    LOCAL_TCP_TERMINATION=$(ask_yes_no "Does this forwarding node also terminate TCP locally?" "$LOCAL_TCP_TERMINATION")
  fi
  TFO_GLOBAL=$(ask_yes_no "Enable global listener TFO 1024 bit? Usually no" "$TFO_GLOBAL")
  BUSY_MODE=$(ask_choice "busy_poll mode: auto, force, off" "$BUSY_MODE" auto force off)
  MANUAL_TCP_CAP_MB=$(to_int "$(ask "Manual tcp_max cap MB, 0 = auto" "$MANUAL_TCP_CAP_MB")")
  MANUAL_BDP_MULT=$(to_int "$(ask "Manual BDP multiplier, 0 = auto" "$MANUAL_BDP_MULT")")
  BBR_KIND=$(ask_choice "BBR version assumption: bbr1, bbr3, unknown" "$BBR_KIND" bbr1 bbr3 unknown)
  TCP_CONNS_OVERRIDE=$(to_int "$(ask "TCP concurrent connections, 0 = auto" "$TCP_CONNS_OVERRIDE")")
  UDP_SESSIONS_OVERRIDE=$(to_int "$(ask "UDP sessions, 0 = auto" "$UDP_SESSIONS_OVERRIDE")")
  CPS_OVERRIDE=$(to_int "$(ask "New connections per second, 0 = auto" "$CPS_OVERRIDE")")
  SERVICE_NAME=$(ask "Optional service name for LimitNOFILE drop-in, empty = skip" "$SERVICE_NAME")
}

usage() {
  cat <<'USAGE'
Network BBR Optimizer bbr.sh

交互式 Linux 网络优化脚本，面向极致专用转发节点和落地节点。

用法:
  bash bbr.sh             # 菜单式交互界面，先生成配置，再确认是否应用
  bash bbr.sh --quick     # 线性问答模式
  bash bbr.sh --dry-run   # 只生成配置文件，不应用
  bash bbr.sh --apply     # 生成后默认询问应用
  bash bbr.sh --help

默认不启用应用层 mux/multiplex。
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) UI_MODE="wizard" ;;
    --dry-run) APPLY_MODE="no" ;;
    --apply) APPLY_MODE="yes" ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

is_linux() { [[ "$(uname -s 2>/dev/null || true)" == "Linux" ]]; }

need_linux() {
  is_linux || die "This script is intended to run on Linux."
}

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

ask() {
  local prompt="$1" default="$2" value
  read -r -p "$prompt [$default]: " value || true
  printf '%s' "${value:-$default}"
}

ask_yes_no() {
  local prompt="$1" default="$2" value
  while true; do
    read -r -p "$prompt [$default]: " value || true
    value="${value:-$default}"
    case "$value" in
      y|Y|yes|YES|Yes) printf 'yes'; return ;;
      n|N|no|NO|No) printf 'no'; return ;;
      *) printf 'Please answer yes or no.\n' >&2 ;;
    esac
  done
}

ask_choice() {
  local prompt="$1" default="$2" value valid
  shift 2
  while true; do
    read -r -p "$prompt [$default]: " value || true
    value="${value:-$default}"
    for valid in "$@"; do
      if [[ "$value" == "$valid" ]]; then
        printf '%s' "$value"
        return
      fi
    done
    printf 'Valid choices: %s\n' "$*" >&2
  done
}

to_int() {
  awk -v n="${1:-0}" 'BEGIN { if (n < 0) n = 0; printf "%.0f", n }'
}

loss_to_bp() {
  awk -v n="${1:-0}" 'BEGIN { if (n < 0) n = 0; printf "%.0f", n * 100 }'
}

min() { (( $1 < $2 )) && printf '%s' "$1" || printf '%s' "$2"; }
max() { (( $1 > $2 )) && printf '%s' "$1" || printf '%s' "$2"; }

clamp() {
  local n="$1" lo="$2" hi="$3"
  if (( n < lo )); then
    printf '%s' "$lo"
  elif (( n > hi )); then
    printf '%s' "$hi"
  else
    printf '%s' "$n"
  fi
}

ceil_div() {
  local n="$1" d="$2"
  (( d > 0 )) || d=1
  printf '%s' $(((n + d - 1) / d))
}

pow2ceil() {
  local n="$1" p=1
  (( n < 1 )) && n=1
  while (( p < n )); do
    p=$((p << 1))
  done
  printf '%s' "$p"
}

round_up_mib() {
  local n="$1"
  printf '%s' $(( ((n + MIB - 1) / MIB) * MIB ))
}

sysctl_exists() {
  local key="$1" path
  path="/proc/sys/${key//./\/}"
  [[ -e "$path" ]]
}

read_sysctl() {
  local key="$1" fallback="$2"
  sysctl -n "$key" 2>/dev/null || printf '%s\n' "$fallback"
}

mem_kb() {
  awk -v key="$1" '$1 == key ":" { print $2; found=1 } END { if (!found) print 0 }' /proc/meminfo
}

detect_default_iface() {
  ip route show default 2>/dev/null | awk '{
    for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit }
  }'
}

count_queues() {
  local iface="$1" type="$2" dir count
  dir="/sys/class/net/$iface/queues"
  if [[ -d "$dir" ]]; then
    count=$(find "$dir" -maxdepth 1 -type d -name "${type}-*" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )) && printf '%s' "$count" && return
  fi
  printf '1'
}

cpu_count() {
  nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || printf '1'
}

cpumask_all() {
  local cpus="$1" full rem i lower=() upper
  (( cpus < 1 )) && cpus=1
  full=$((cpus / 32))
  rem=$((cpus % 32))
  for ((i=0; i<full; i++)); do
    lower+=("ffffffff")
  done
  if (( rem > 0 )); then
    upper=$(printf '%x' $(((1 << rem) - 1)))
    lower+=("$upper")
  fi
  for ((i=${#lower[@]}-1; i>=0; i--)); do
    if (( i != ${#lower[@]}-1 )); then printf ','; fi
    printf '%s' "${lower[$i]}"
  done
}

emit_sysctl() {
  local key="$1" value="$2"
  if sysctl_exists "$key"; then
    printf '%s = %s\n' "$key" "$value" >> "$SYSCTL_OUT"
  else
    printf '# skipped missing: %s = %s\n' "$key" "$value" >> "$SYSCTL_OUT"
  fi
}

backup_file() {
  local file="$1" backup_dir="$2"
  if [[ -e "$file" ]]; then
    mkdir -p "$backup_dir$(dirname "$file")"
    cp -a "$file" "$backup_dir$file"
  fi
}

install_file() {
  local src="$1" dst="$2" mode="$3" backup_dir="$4"
  backup_file "$dst" "$backup_dir"
  install -D -m "$mode" "$src" "$dst"
}

write_rollback() {
  local rollback="$OUT_DIR/rollback.sh" backup_dir="$1"
  cat > "$rollback" <<EOF
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="$backup_dir"
restore_or_remove() {
  local path="\$1"
  if [[ -e "\$BACKUP_DIR\$path" ]]; then
    install -D -m 0644 "\$BACKUP_DIR\$path" "\$path"
  else
    rm -f "\$path"
  fi
}
restore_or_remove /etc/sysctl.d/99-network-optimize.conf
restore_or_remove /etc/security/limits.d/99-network-optimize.conf
restore_or_remove /etc/systemd/system.conf.d/99-network-optimize.conf
restore_or_remove /etc/modprobe.d/nf_conntrack.conf
restore_or_remove /usr/local/sbin/network-optimize-route.sh
restore_or_remove /usr/local/sbin/network-optimize-nic.sh
restore_or_remove /etc/systemd/system/network-optimize-route.service
restore_or_remove /etc/systemd/system/network-optimize-nic.service
systemctl daemon-reexec 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
sysctl --system
echo "Rollback files restored. Reboot may be needed for conntrack hashsize and route/NIC runtime state."
EOF
  chmod +x "$rollback"
}

need_linux

TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${OUT_DIR:-$PWD/bbr-output-$TS}"
mkdir -p "$OUT_DIR"
SYSCTL_OUT="$OUT_DIR/99-network-optimize.conf"
LIMITS_OUT="$OUT_DIR/99-network-optimize-limits.conf"
SYSTEMD_OUT="$OUT_DIR/99-network-optimize-system.conf"
MODPROBE_OUT="$OUT_DIR/nf_conntrack.conf"
ROUTE_OUT="$OUT_DIR/network-optimize-route.sh"
NIC_OUT="$OUT_DIR/network-optimize-nic.sh"
REPORT_OUT="$OUT_DIR/report.txt"

printf 'Network BBR Optimizer bbr.sh %s\n' "$VERSION"
printf 'Output directory: %s\n\n' "$OUT_DIR"

MEM_TOTAL_KB=$(mem_kb MemTotal)
MEM_AVAIL_KB=$(mem_kb MemAvailable)
if (( MEM_AVAIL_KB <= 0 )); then MEM_AVAIL_KB="$MEM_TOTAL_KB"; fi
CPU_COUNT=$(cpu_count)
DEFAULT_IFACE=$(detect_default_iface)
DEFAULT_IFACE="${DEFAULT_IFACE:-eth0}"
RX_QUEUES=$(count_queues "$DEFAULT_IFACE" rx)
TX_QUEUES=$(count_queues "$DEFAULT_IFACE" tx)

ROLE="forwarding"
SCENE="plain"
TARGET="speed"
BUSINESS="mixed"
STATEFUL="yes"
LANDING_ROUTES="no"
IPV6_RA="no"
MULTIPATH="yes"
HANDSHAKE="yes"
TFO_GLOBAL="no"
LOCAL_TCP_TERMINATION="no"
BUSY_MODE="auto"
UP_MBPS=1000
DOWN_MBPS=1000
UP_RTT=80
DOWN_RTT=80
LOSS_PCT=0
JITTER_MS=0
MANUAL_TCP_CAP_MB=0
MANUAL_BDP_MULT=0
BBR_KIND="unknown"
TCP_CONNS_OVERRIDE=0
UDP_SESSIONS_OVERRIDE=0
CPS_OVERRIDE=0
SERVICE_NAME=""

if [[ "$UI_MODE" == "menu" && -t 0 ]]; then
  interactive_menu
else
  linear_wizard
fi

LOSS_BP=$(loss_to_bp "$LOSS_PCT")

TCP_CONNS=350000
UDP_SESSIONS=150000
CPS=6000
MEM_PCT=64
if [[ "$ROLE" == "landing" ]]; then
  TCP_CONNS=260000
  UDP_SESSIONS=80000
  CPS=4500
fi

if (( MEM_TOTAL_KB < 1024 * 1024 )); then
  TCP_CONNS=$((TCP_CONNS / 4))
  UDP_SESSIONS=$((UDP_SESSIONS / 4))
  MEM_PCT=25
elif (( MEM_TOTAL_KB < 2048 * 1024 )); then
  TCP_CONNS=$((TCP_CONNS / 2))
  UDP_SESSIONS=$((UDP_SESSIONS / 2))
  MEM_PCT=40
fi

case "$BUSINESS" in
  udp_game)
    UDP_SESSIONS=$((UDP_SESSIONS * 2))
    CPS=$((CPS * 3 / 2))
    ;;
  web)
    UDP_SESSIONS=$((UDP_SESSIONS / 2))
    CPS=$((CPS * 2))
    ;;
esac

if [[ "$ROLE" == "forwarding" ]]; then
  case "$SCENE" in
    front)
      TCP_CONNS=$((TCP_CONNS * 11 / 10))
      CPS=$((CPS * 14 / 10))
      ;;
    ix)
      TCP_CONNS=$((TCP_CONNS * 18 / 10))
      UDP_SESSIONS=$((UDP_SESSIONS * 2))
      CPS=$((CPS * 18 / 10))
      MEM_PCT=$((MEM_PCT + 12))
      ;;
    relay)
      TCP_CONNS=$((TCP_CONNS * 12 / 10))
      MEM_PCT=$((MEM_PCT + 6))
      ;;
    international)
      TCP_CONNS=$((TCP_CONNS * 11 / 10))
      UDP_SESSIONS=$((UDP_SESSIONS * 12 / 10))
      MEM_PCT=$((MEM_PCT + 4))
      ;;
  esac
fi

MEM_PCT=$((MEM_PCT + 14))
MEM_PCT=$(clamp "$MEM_PCT" 35 78)
if (( MEM_TOTAL_KB < 1024 * 1024 )); then
  MEM_PCT=$(clamp "$MEM_PCT" 1 25)
elif (( MEM_TOTAL_KB < 2048 * 1024 )); then
  MEM_PCT=$(clamp "$MEM_PCT" 1 40)
fi

if (( TCP_CONNS_OVERRIDE > 0 )); then TCP_CONNS="$TCP_CONNS_OVERRIDE"; fi
if (( UDP_SESSIONS_OVERRIDE > 0 )); then UDP_SESSIONS="$UDP_SESSIONS_OVERRIDE"; fi
if (( CPS_OVERRIDE > 0 )); then CPS="$CPS_OVERRIDE"; fi

UP_BDP=$((UP_MBPS * UP_RTT * 125))
DOWN_BDP=$((DOWN_MBPS * DOWN_RTT * 125))
BDP=$(max "$UP_BDP" "$DOWN_BDP")
MBW=$(max "$UP_MBPS" "$DOWN_MBPS")
MAXRTT=$(max "$UP_RTT" "$DOWN_RTT")

if [[ "$BBR_KIND" == "bbr3" ]]; then
  BDP_MULT=8
else
  BDP_MULT=10
fi
BDP_MULT=$((BDP_MULT + 2))
[[ "$BUSINESS" == "udp_game" ]] && BDP_MULT=$((BDP_MULT + 1))
(( LOSS_BP >= 100 )) && BDP_MULT=$((BDP_MULT + 1))
(( LOSS_BP >= 300 )) && BDP_MULT=$((BDP_MULT + 1))
JITTER_GUARD="no"
if (( JITTER_MS > MAXRTT / 2 + 1 )); then
  BDP_MULT=$((BDP_MULT + 1))
  JITTER_GUARD="yes"
fi
if [[ "$SCENE" == "ix" ]] && (( LOSS_BP < 100 )); then
  BDP_MULT=$((BDP_MULT + 2))
fi
if [[ "$SCENE" == "international" ]] && { (( LOSS_BP >= 100 )) || [[ "$JITTER_GUARD" == "yes" ]]; }; then
  BDP_MULT=$(min "$BDP_MULT" 12)
fi
if (( MANUAL_BDP_MULT > 0 )); then
  BDP_MULT="$MANUAL_BDP_MULT"
fi
BDP_MULT=$(clamp "$BDP_MULT" 2 16)
if (( LOSS_BP >= 100 )) || [[ "$JITTER_GUARD" == "yes" ]] || [[ "$BUSINESS" == "udp_game" ]]; then
  QUEUE_JITTER_GUARD="yes"
  BDP_MULT=$(min "$BDP_MULT" 12)
  NETDEV_BACKLOG_CAP=524288
  TXQUEUELEN_CAP=12000
  NETDEV_BUDGET_USECS_CAP=10000
else
  QUEUE_JITTER_GUARD="no"
  NETDEV_BACKLOG_CAP=1048576
  TXQUEUELEN_CAP=20000
  NETDEV_BUDGET_USECS_CAP=12000
fi

ACTIVE_DIV_RAW=$((TCP_CONNS / 5000 + UDP_SESSIONS / 25000 + 4))
ACTIVE_DIV_CAP=128
if [[ "$SCENE" == "ix" ]]; then
  ACTIVE_DIV_RAW=$((TCP_CONNS / 6000 + UDP_SESSIONS / 30000 + 4))
  ACTIVE_DIV_CAP=96
fi
ACTIVE_DIV=$(clamp "$ACTIVE_DIV_RAW" 4 "$ACTIVE_DIV_CAP")
MEM_AVAIL_BYTES=$((MEM_AVAIL_KB * 1024))
MEM_TOTAL_BYTES=$((MEM_TOTAL_KB * 1024))
MEM_CAP=$((MEM_AVAIL_BYTES * MEM_PCT / 100 / ACTIVE_DIV))
if (( MANUAL_TCP_CAP_MB > 0 )); then
  HARD_CAP=$((MANUAL_TCP_CAP_MB * MIB))
else
  HARD_CAP=$(min "$AUTO_TCP_CAP" "$MEM_CAP")
fi
HARD_CAP=$(max "$HARD_CAP" $((8 * MIB)))
DESIRED=$((BDP * BDP_MULT))
TCP_MAX=$(round_up_mib "$DESIRED")
TCP_MAX=$(max "$TCP_MAX" $((16 * MIB)))
TCP_MAX=$(min "$TCP_MAX" "$HARD_CAP")
TCP_MAX=$(max "$TCP_MAX" $((8 * MIB)))

read -r TCP_RMEM_MIN TCP_RMEM_DEFAULT _ <<< "$(read_sysctl net.ipv4.tcp_rmem '4096 87380 6291456')"
read -r TCP_WMEM_MIN TCP_WMEM_DEFAULT _ <<< "$(read_sysctl net.ipv4.tcp_wmem '4096 65536 4194304')"

ECN=0
[[ "$BBR_KIND" == "bbr3" ]] && ECN=2

TFO_VALUE=""
TFO_BLACKHOLE=""
if [[ "$HANDSHAKE" == "yes" ]]; then
  if [[ "$LOCAL_TCP_TERMINATION" == "yes" ]]; then
    TFO_VALUE=3
  else
    TFO_VALUE=""
  fi
  if [[ "$TFO_GLOBAL" == "yes" && -n "$TFO_VALUE" ]]; then
    TFO_VALUE=$((TFO_VALUE | 1024))
  fi
  if [[ -n "$TFO_VALUE" ]]; then
    if [[ "$SCENE" == "ix" && "$LOSS_BP" -lt 50 && "$QUEUE_JITTER_GUARD" == "no" ]]; then
      TFO_BLACKHOLE=0
    else
      TFO_BLACKHOLE=60
    fi
  fi
fi

if [[ "$TARGET" == "throughput" ]]; then
  LOWAT_FACTOR=384
  LOWAT_LO=$((128 * 1024))
  LOWAT_HI=$((2 * MIB))
else
  LOWAT_FACTOR=256
  LOWAT_LO=$((64 * 1024))
  LOWAT_HI=$((1 * MIB))
fi
LOWAT=$(clamp $((MBW * LOWAT_FACTOR)) "$LOWAT_LO" "$LOWAT_HI")

UDP_FACTOR=8192
[[ "$TARGET" == "throughput" ]] && UDP_FACTOR=12288
[[ "$BUSINESS" == "udp_game" ]] && UDP_FACTOR=16384
UDPR="$BDP"
[[ "$BUSINESS" == "udp_game" ]] && UDPR=$((BDP * 2))
UDPR=$(max "$UDPR" $((MBW * UDP_FACTOR)))
if [[ "$BUSINESS" == "udp_game" ]]; then
  UDP_SOCKET_CAP="$TCP_MAX"
else
  UDP_SOCKET_CAP=$((TCP_MAX / 2))
fi
UDP_SOCKET_CAP=$(max "$UDP_SOCKET_CAP" "$MIB")
UDPR=$(clamp "$UDPR" "$MIB" "$UDP_SOCKET_CAP")
UDP_MIN=4096
[[ "$BUSINESS" == "udp_game" ]] && UDP_MIN=16384
if [[ "$TARGET" == "throughput" || "$UDP_SESSIONS" -gt 50000 ]]; then UDP_MIN=8192; fi
UDP_MIN=$(clamp "$UDP_MIN" 4096 65536)
UDP_MAX_PAGES=$((MEM_AVAIL_KB / 4 * MEM_PCT / 100))
UDP_FLOOR=$(max $(( ($(ceil_div "$UDPR" 4096)) * 4 )) 4096)
UDP_CAP=$(max $((MEM_TOTAL_KB / 4 * MEM_PCT / 100)) "$UDP_FLOOR")
UDP_MAX_PAGES=$(clamp "$UDP_MAX_PAGES" "$UDP_FLOOR" "$UDP_CAP")
UDP_LOW=$((UDP_MAX_PAGES / 2))
UDP_PRESSURE=$((UDP_MAX_PAGES * 3 / 4))

OMEM_CAP=$(clamp $((TCP_MAX / 8)) "$MIB" $((16 * MIB)))
OPTMEM=$(clamp $((MBW * 256 + UDP_SESSIONS / 4)) $((256 * 1024)) "$OMEM_CAP")

if [[ "$BUSY_MODE" == "force" ]] || { [[ "$BUSY_MODE" == "auto" ]] && (( MBW >= 20 )) && { (( MAXRTT <= 20 )) || [[ "$BUSINESS" == "udp_game" && "$MAXRTT" -le 10 ]]; }; }; then
  BUSY_POLL=$(clamp $((20 + MBW / (CPU_COUNT + 1))) 20 400)
else
  BUSY_POLL=""
fi

if (( MAXRTT <= 10 )); then
  INITCWND=512
elif (( MAXRTT <= 50 )); then
  INITCWND=384
elif (( MAXRTT <= 120 )); then
  INITCWND=256
else
  INITCWND=160
fi
INITCWND=$(clamp "$INITCWND" 32 512)

MIN_RTT_WLEN=120
[[ "$TARGET" == "throughput" ]] && MIN_RTT_WLEN=180
MIN_RTT_WLEN=$((MIN_RTT_WLEN + (JITTER_MS + 9) / 10))
MIN_RTT_WLEN=$(clamp "$MIN_RTT_WLEN" 20 300)

REORDERING=$((128 + MAXRTT * 2 + JITTER_MS * 8 + LOSS_BP))
if [[ "$TARGET" == "throughput" ]]; then
  REORDERING=$((REORDERING * 13 / 10))
else
  REORDERING=$((REORDERING * 12 / 10))
fi
REORDERING=$(clamp "$REORDERING" 128 2000)

KEEP_TIME=30
KEEP_INTVL=10
KEEP_PROBES=3
if [[ "$BUSINESS" == "web" ]]; then
  KEEP_TIME=120
  KEEP_INTVL=20
  KEEP_PROBES=5
elif (( TCP_CONNS > 200000 )); then
  KEEP_TIME=45
  KEEP_INTVL=15
  KEEP_PROBES=4
fi

TCP_LIMIT_FACTOR=6
[[ "$TARGET" == "throughput" ]] && TCP_LIMIT_FACTOR=8
if [[ "$SCENE" == "ix" && "$LOSS_BP" -lt 50 ]]; then TCP_LIMIT_FACTOR=8; fi
if [[ "$SCENE" == "international" ]]; then TCP_LIMIT_FACTOR=5; fi
if (( LOSS_BP >= 100 )) || [[ "$QUEUE_JITTER_GUARD" == "yes" ]]; then TCP_LIMIT_FACTOR=4; fi
if [[ "$BUSINESS" == "udp_game" ]]; then TCP_LIMIT_FACTOR=3; fi
LIMIT_UPPER=$(clamp $((TCP_MAX / 2)) $((4 * MIB)) $((64 * MIB)))
TCP_LIMIT=$(clamp $((BDP * TCP_LIMIT_FACTOR)) "$MIB" "$LIMIT_UPPER")

SOMAXCONN=$(pow2ceil "$(clamp $((CPS * 4 + TCP_CONNS / 16)) 4096 1048576)")
SYN_BACKLOG=$(pow2ceil "$(clamp $((CPS * 8 + TCP_CONNS / 8)) 8192 1048576)")
FLOW_LIMIT=$(pow2ceil "$(clamp $((TCP_CONNS / 16 + UDP_SESSIONS / 8 + CPS * 2)) 4096 1048576)")
NOFILE=$(pow2ceil "$(clamp $(((TCP_CONNS + UDP_SESSIONS + CPS * 10) * 2 + 4096)) 65536 8388608)")
FS_FILE_MAX=$(pow2ceil "$(clamp $((NOFILE * 2)) 1048576 16777216)")

NETDEV_RAW=$((MBW * 16 + CPS * 8 + UDP_SESSIONS / 8))
NETDEV_RAW=$((NETDEV_RAW * 15 / 10))
[[ "$SCENE" == "ix" ]] && NETDEV_RAW=$((NETDEV_RAW * 2))
[[ "$TARGET" == "throughput" ]] && NETDEV_RAW=$((NETDEV_RAW * 15 / 10))
[[ "$BUSINESS" == "udp_game" ]] && NETDEV_RAW=$((NETDEV_RAW + UDP_SESSIONS / 3))
NETDEV_BACKLOG=$(pow2ceil "$(clamp "$NETDEV_RAW" 4096 "$NETDEV_BACKLOG_CAP")")

CT_NEEDED="no"
if [[ "$ROLE" == "forwarding" && "$STATEFUL" == "yes" ]]; then CT_NEEDED="yes"; fi
if [[ "$ROLE" == "landing" && "$LANDING_ROUTES" == "yes" ]]; then CT_NEEDED="yes"; fi
CT_RAW=$((TCP_CONNS + UDP_SESSIONS * 2 + CPS * 90))
[[ "$SCENE" == "ix" ]] && CT_RAW=$((CT_RAW * 15 / 10))
[[ "$TARGET" == "throughput" ]] && CT_RAW=$((CT_RAW * 125 / 100))
[[ "$BUSINESS" == "udp_game" ]] && CT_RAW=$((CT_RAW + UDP_SESSIONS))
CT_MEM_CAP=$((MEM_TOTAL_BYTES * MEM_PCT / 100 / 512))
CT_UPPER=$(min 16777216 "$(max 131072 "$CT_MEM_CAP")")
NF_CONNTRACK_MAX=$(clamp "$(pow2ceil "$CT_RAW")" 131072 "$CT_UPPER")
NF_CONNTRACK_BUCKETS=$(pow2ceil "$(clamp "$NF_CONNTRACK_MAX" 32768 16777216)")

CT_TCP_EST=900
[[ "$BUSINESS" == "web" ]] && CT_TCP_EST=1200
(( TCP_CONNS > 500000 )) && CT_TCP_EST=600
CT_UDP=45
[[ "$BUSINESS" == "udp_game" ]] && CT_UDP=30
CT_UDP_STREAM=180

TXQUEUELEN=$((MBW / 2 + MAXRTT * 10 + UDP_SESSIONS / 1000))
TXQUEUELEN=$((TXQUEUELEN * 15 / 10))
[[ "$TARGET" == "throughput" ]] && TXQUEUELEN=$((TXQUEUELEN * 13 / 10))
[[ "$BUSINESS" == "udp_game" ]] && TXQUEUELEN=$((TXQUEUELEN + 500))
TXQUEUELEN=$(clamp "$TXQUEUELEN" 500 "$TXQUEUELEN_CAP")

RX_QUEUES=$(max "$RX_QUEUES" 1)
NETDEV_BUDGET=$(clamp $((RX_QUEUES * 800)) 1600 20000)
NETDEV_BUDGET_USECS=$(clamp 10000 1 "$NETDEV_BUDGET_USECS_CAP")
[[ "$TARGET" == "throughput" ]] && NETDEV_BUDGET_USECS=$(clamp 12000 1 "$NETDEV_BUDGET_USECS_CAP")

RPS_ENABLE="no"
if (( RX_QUEUES < CPU_COUNT && CPU_COUNT >= 2 )); then
  RPS_ENABLE="yes"
fi
RPS_ENTRIES=$(clamp "$FLOW_LIMIT" 32768 2097152)
RPS_FLOW_CNT=$(clamp $((RPS_ENTRIES / RX_QUEUES)) 1024 65536)
RPS_CPUS=$(cpumask_all "$CPU_COUNT")

RP_FILTER=2
[[ "$MULTIPATH" == "yes" ]] && RP_FILTER=0

: > "$SYSCTL_OUT"
{
  printf '# Generated by bbr.sh %s on %s\n' "$VERSION" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '# role=%s scene=%s target=%s business=%s\n\n' "$ROLE" "$SCENE" "$TARGET" "$BUSINESS"
} >> "$SYSCTL_OUT"

emit_sysctl net.core.default_qdisc fq
if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
  emit_sysctl net.ipv4.tcp_congestion_control bbr
else
  printf '# skipped: bbr is not listed in net.ipv4.tcp_available_congestion_control\n' >> "$SYSCTL_OUT"
fi
emit_sysctl fs.file-max "$FS_FILE_MAX"
emit_sysctl net.core.rmem_max "$TCP_MAX"
emit_sysctl net.core.wmem_max "$TCP_MAX"
emit_sysctl net.ipv4.tcp_rmem "$TCP_RMEM_MIN $TCP_RMEM_DEFAULT $TCP_MAX"
emit_sysctl net.ipv4.tcp_wmem "$TCP_WMEM_MIN $TCP_WMEM_DEFAULT $TCP_MAX"
emit_sysctl net.ipv4.tcp_moderate_rcvbuf 1
emit_sysctl net.core.optmem_max "$OPTMEM"
emit_sysctl net.ipv4.tcp_notsent_lowat "$LOWAT"
emit_sysctl net.ipv4.tcp_slow_start_after_idle 0
emit_sysctl net.ipv4.tcp_min_rtt_wlen "$MIN_RTT_WLEN"
emit_sysctl net.ipv4.tcp_max_reordering "$REORDERING"
emit_sysctl net.ipv4.tcp_ecn "$ECN"
if [[ -n "$TFO_VALUE" ]]; then
  emit_sysctl net.ipv4.tcp_fastopen "$TFO_VALUE"
  [[ -n "$TFO_BLACKHOLE" ]] && emit_sysctl net.ipv4.tcp_fastopen_blackhole_timeout_sec "$TFO_BLACKHOLE"
else
  printf '# skipped: tcp_fastopen not useful for pure forwarding without local TCP termination\n' >> "$SYSCTL_OUT"
fi
emit_sysctl net.ipv4.tcp_mtu_probing 1
emit_sysctl net.ipv4.tcp_rfc1337 1
emit_sysctl net.ipv4.tcp_keepalive_time "$KEEP_TIME"
emit_sysctl net.ipv4.tcp_keepalive_intvl "$KEEP_INTVL"
emit_sysctl net.ipv4.tcp_keepalive_probes "$KEEP_PROBES"
emit_sysctl net.ipv4.tcp_limit_output_bytes "$TCP_LIMIT"
emit_sysctl net.core.somaxconn "$SOMAXCONN"
emit_sysctl net.ipv4.tcp_max_syn_backlog "$SYN_BACKLOG"
emit_sysctl net.ipv4.ip_local_port_range "1024 65535"
emit_sysctl net.core.flow_limit_table_len "$FLOW_LIMIT"
emit_sysctl net.ipv4.udp_rmem_min "$UDP_MIN"
emit_sysctl net.ipv4.udp_wmem_min "$UDP_MIN"
emit_sysctl net.ipv4.udp_mem "$UDP_LOW $UDP_PRESSURE $UDP_MAX_PAGES"
emit_sysctl net.core.netdev_max_backlog "$NETDEV_BACKLOG"
emit_sysctl net.core.netdev_budget "$NETDEV_BUDGET"
emit_sysctl net.core.netdev_budget_usecs "$NETDEV_BUDGET_USECS"
emit_sysctl net.core.rps_sock_flow_entries "$RPS_ENTRIES"

if [[ "$ROLE" == "forwarding" || "$LANDING_ROUTES" == "yes" ]]; then
  emit_sysctl net.ipv4.ip_forward 1
  emit_sysctl net.ipv4.conf.all.rp_filter "$RP_FILTER"
  emit_sysctl net.ipv4.conf.default.rp_filter "$RP_FILTER"
  emit_sysctl net.ipv4.conf.all.accept_source_route 0
  emit_sysctl net.ipv4.conf.default.accept_source_route 0
  emit_sysctl net.ipv4.conf.all.send_redirects 0
  emit_sysctl net.ipv4.conf.default.send_redirects 0
  emit_sysctl net.ipv4.conf.all.accept_redirects 0
  emit_sysctl net.ipv4.conf.default.accept_redirects 0
  emit_sysctl net.ipv6.conf.all.forwarding 1
  emit_sysctl net.ipv6.conf.default.forwarding 1
  emit_sysctl net.ipv6.conf.all.accept_redirects 0
  emit_sysctl net.ipv6.conf.default.accept_redirects 0
  emit_sysctl net.ipv6.conf.all.accept_source_route 0
  emit_sysctl net.ipv6.conf.default.accept_source_route 0
  if [[ "$IPV6_RA" == "yes" ]]; then
    printf '# IPv6 RA is needed on %s: set per-interface accept_ra=2 outside all/default if applicable.\n' "$DEFAULT_IFACE" >> "$SYSCTL_OUT"
  fi
fi

if [[ "$CT_NEEDED" == "yes" ]]; then
  emit_sysctl net.netfilter.nf_conntrack_max "$NF_CONNTRACK_MAX"
  emit_sysctl net.netfilter.nf_conntrack_tcp_timeout_established "$CT_TCP_EST"
  emit_sysctl net.netfilter.nf_conntrack_udp_timeout "$CT_UDP"
  emit_sysctl net.netfilter.nf_conntrack_udp_timeout_stream "$CT_UDP_STREAM"
fi

if [[ -n "$BUSY_POLL" ]]; then
  emit_sysctl net.core.busy_poll "$BUSY_POLL"
  emit_sysctl net.core.busy_read "$BUSY_POLL"
fi

cat > "$LIMITS_OUT" <<EOF
* soft nofile $NOFILE
* hard nofile $NOFILE
root soft nofile $NOFILE
root hard nofile $NOFILE
EOF

cat > "$SYSTEMD_OUT" <<EOF
[Manager]
DefaultLimitNOFILE=$NOFILE
EOF

if [[ "$CT_NEEDED" == "yes" ]]; then
  cat > "$MODPROBE_OUT" <<EOF
options nf_conntrack hashsize=$NF_CONNTRACK_BUCKETS
EOF
fi

cat > "$ROUTE_OUT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
apply_init() {
  local family="\$1" line clean
  if [[ "\$family" == "4" ]]; then
    ip route show default 2>/dev/null
  else
    ip -6 route show default 2>/dev/null
  fi | while IFS= read -r line; do
    [[ -z "\$line" ]] && continue
    clean=\$(printf '%s' "\$line" | sed -E 's/ initcwnd [0-9]+//g; s/ initrwnd [0-9]+//g')
    if [[ "\$family" == "4" ]]; then
      ip route replace \$clean initcwnd $INITCWND initrwnd $INITCWND || true
    else
      ip -6 route replace \$clean initcwnd $INITCWND initrwnd $INITCWND || true
    fi
  done
}
apply_init 4
apply_init 6
EOF
chmod +x "$ROUTE_OUT"

cat > "$NIC_OUT" <<EOF
#!/usr/bin/env bash
set -euo pipefail
IFACE="${DEFAULT_IFACE}"
TXQ="$TXQUEUELEN"
RPS_ENABLE="$RPS_ENABLE"
RPS_CPUS="$RPS_CPUS"
RPS_FLOW_CNT="$RPS_FLOW_CNT"
if [[ -d "/sys/class/net/\$IFACE" ]]; then
  ip link set dev "\$IFACE" txqueuelen "\$TXQ" || true
  if [[ "\$RPS_ENABLE" == "yes" ]]; then
    for f in /sys/class/net/"\$IFACE"/queues/rx-*/rps_cpus; do
      [[ -e "\$f" ]] && printf '%s' "\$RPS_CPUS" > "\$f" || true
    done
    for f in /sys/class/net/"\$IFACE"/queues/rx-*/rps_flow_cnt; do
      [[ -e "\$f" ]] && printf '%s' "\$RPS_FLOW_CNT" > "\$f" || true
    done
  fi
fi
EOF
chmod +x "$NIC_OUT"

if [[ -n "$SERVICE_NAME" ]]; then
  SERVICE_DROPIN="$OUT_DIR/${SERVICE_NAME}.override.conf"
  cat > "$SERVICE_DROPIN" <<EOF
[Service]
LimitNOFILE=$NOFILE
EOF
fi

cat > "$REPORT_OUT" <<EOF
Network BBR Optimizer report
============================
role=$ROLE
scene=$SCENE
target=$TARGET
business=$BUSINESS
iface=$DEFAULT_IFACE
up_mbps=$UP_MBPS
down_mbps=$DOWN_MBPS
up_rtt_ms=$UP_RTT
down_rtt_ms=$DOWN_RTT
loss_pct=$LOSS_PCT
jitter_ms=$JITTER_MS
queue_jitter_guard=$QUEUE_JITTER_GUARD

tcp_conns=$TCP_CONNS
udp_sessions=$UDP_SESSIONS
cps=$CPS
mem_pct=$MEM_PCT
bdp_bytes=$BDP
bdp_mult=$BDP_MULT
tcp_max=$TCP_MAX
tcp_limit_output_bytes=$TCP_LIMIT
initcwnd=$INITCWND
nofile=$NOFILE
netdev_max_backlog=$NETDEV_BACKLOG
txqueuelen=$TXQUEUELEN
rps_enable=$RPS_ENABLE
rps_cpus=$RPS_CPUS
rps_flow_cnt=$RPS_FLOW_CNT
tfo_value=${TFO_VALUE:-skipped}
tfo_blackhole=${TFO_BLACKHOLE:-skipped}
conntrack_needed=$CT_NEEDED
nf_conntrack_max=$NF_CONNTRACK_MAX
nf_conntrack_buckets=$NF_CONNTRACK_BUCKETS

Application mux/multiplex: not enabled by this script.
EOF

printf '\nGenerated files:\n'
printf '  %s\n' "$SYSCTL_OUT" "$LIMITS_OUT" "$SYSTEMD_OUT" "$ROUTE_OUT" "$NIC_OUT" "$REPORT_OUT"
[[ -f "$MODPROBE_OUT" ]] && printf '  %s\n' "$MODPROBE_OUT"
[[ -n "${SERVICE_DROPIN:-}" ]] && printf '  %s\n' "$SERVICE_DROPIN"

if [[ "$APPLY_MODE" == "no" ]]; then
  log "Dry run complete. Review files in $OUT_DIR."
  exit 0
fi

if ! is_root; then
  warn "Not running as root. Generated files only; rerun with sudo to apply."
  exit 0
fi

if [[ "$APPLY_MODE" == "ask" ]]; then
  DO_APPLY=$(ask_yes_no "Apply generated configuration now?" "no")
else
  DO_APPLY=$(ask_yes_no "Apply generated configuration now?" "yes")
fi
if [[ "$DO_APPLY" != "yes" ]]; then
  log "Not applied. Review files in $OUT_DIR."
  exit 0
fi

BACKUP_DIR="/root/network-optimize-backup-$TS"
mkdir -p "$BACKUP_DIR"
write_rollback "$BACKUP_DIR"

install_file "$SYSCTL_OUT" /etc/sysctl.d/99-network-optimize.conf 0644 "$BACKUP_DIR"
install_file "$LIMITS_OUT" /etc/security/limits.d/99-network-optimize.conf 0644 "$BACKUP_DIR"
install_file "$SYSTEMD_OUT" /etc/systemd/system.conf.d/99-network-optimize.conf 0644 "$BACKUP_DIR"
if [[ "$CT_NEEDED" == "yes" ]]; then
  install_file "$MODPROBE_OUT" /etc/modprobe.d/nf_conntrack.conf 0644 "$BACKUP_DIR"
fi
install_file "$ROUTE_OUT" /usr/local/sbin/network-optimize-route.sh 0755 "$BACKUP_DIR"
install_file "$NIC_OUT" /usr/local/sbin/network-optimize-nic.sh 0755 "$BACKUP_DIR"

cat > "$OUT_DIR/network-optimize-route.service" <<'EOF'
[Unit]
Description=Apply network optimize route initcwnd
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/network-optimize-route.sh

[Install]
WantedBy=multi-user.target
EOF
cat > "$OUT_DIR/network-optimize-nic.service" <<'EOF'
[Unit]
Description=Apply network optimize NIC txqueuelen and RPS
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/network-optimize-nic.sh

[Install]
WantedBy=multi-user.target
EOF
install_file "$OUT_DIR/network-optimize-route.service" /etc/systemd/system/network-optimize-route.service 0644 "$BACKUP_DIR"
install_file "$OUT_DIR/network-optimize-nic.service" /etc/systemd/system/network-optimize-nic.service 0644 "$BACKUP_DIR"

if [[ -n "${SERVICE_DROPIN:-}" ]]; then
  install_file "$SERVICE_DROPIN" "/etc/systemd/system/${SERVICE_NAME}.d/override.conf" 0644 "$BACKUP_DIR"
fi

sysctl --system
systemctl daemon-reexec 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
systemctl enable --now network-optimize-route.service 2>/dev/null || true
systemctl enable --now network-optimize-nic.service 2>/dev/null || true

printf '\nApplied. Rollback script: %s/rollback.sh\n' "$OUT_DIR"
printf 'Backup directory: %s\n' "$BACKUP_DIR"
printf 'A reboot is recommended if nf_conntrack hashsize was changed.\n'
