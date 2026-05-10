#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  rmdj.sh  ·  Remnawave 一体化安装/对接脚本   (panel + node + 日志 API)
#  © unlil  ·  bash <(curl -s -L https://raw.githubusercontent.com/GHUNLIL/dowunlil.github.io/main/rmdj.sh)
#
#  v6 重构亮点（架构师级精修，向后兼容旧 CLI）:
#    1. 严格模式 + 信号陷阱: set -Eeuo pipefail 全程, EXIT/INT 自动清理 tmp 文件
#    2. 颜色感知: 非交互/管道/CI 自动剥离 ANSI, 不污染日志
#    3. 真正幂等: 所有写入前 diff, 内容相同跳过; .env 用纯 bash 重写, 杜绝 sed 注入
#    4. 安全的字段替换: 不再 awk -F 截断含 = 的 SECRET, 不再 sed 注入特殊字符
#    5. Token 链路: CLI > 环境 > 文件 > 生成, 全部强校验长度/字符集; chmod 600 验证
#    6. 端口/容器名预检: 启动前先看 ss/lsof 占用 + 现有容器同名冲突
#    7. 新增 --dry-run: 只看不动, 适合在 CI / 评估期使用
#    8. 新增 --uninstall: 优雅 docker compose down + 备份后清理
#    9. 新增 --update: 拉新镜像并 recreate (节点平滑滚动)
#   10. cd / mkdir 失败强终止, 不会在错误目录创建脏文件
#   11. 健康检查带退避重试, 替代固定 sleep
#
#  全部 CLI / 环境变量保持向后兼容, 旧使用方式无需任何调整.
# ─────────────────────────────────────────────────────────────────────────────

set -Eeuo pipefail
IFS=$'\n\t'

# ─── trap & cleanup ────────────────────────────────────────────────────────
declare -a __RMDJ_TMPFILES=()
__RMDJ_CLEAN_EXIT="false"
__rmdj_cleanup() {
    local rc=$?
    for f in "${__RMDJ_TMPFILES[@]:-}"; do
        [ -n "$f" ] && [ -e "$f" ] && rm -f -- "$f" 2>/dev/null || true
    done
    # 只有真正未处理的 ERR (非 die / 非 --help / 非 SIGINT) 才打提示
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 130 ] && [ "$__RMDJ_CLEAN_EXIT" != "true" ]; then
        printf '\n[rmdj] 脚本异常退出 (exit=%d, line=%s)\n' "$rc" "${BASH_LINENO[0]:-?}" >&2
    fi
    exit $rc
}
trap __rmdj_cleanup EXIT
trap '__RMDJ_CLEAN_EXIT=true; echo; echo "[rmdj] 中断信号已收到, 正在清理..." >&2; exit 130' INT TERM

mktemp_tracked() {
    local f
    f=$(mktemp "${TMPDIR:-/tmp}/rmdj.XXXXXXXX") || { echo "mktemp 失败" >&2; exit 1; }
    __RMDJ_TMPFILES+=("$f")
    printf '%s' "$f"
}

# ─── 颜色 (TTY 感知) ────────────────────────────────────────────────────────
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; WHITE=$'\033[1;37m'; DIM=$'\033[2m'
    BOLD=$'\033[1m';   NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; WHITE=''; DIM=''; BOLD=''; NC=''
fi

msg()       { printf '%b\n' "$*"; }
err()       { printf '%b\n' "  ${RED}✗${NC} $*" >&2; }
warn()      { printf '%b\n' "  ${YELLOW}!${NC} $*" >&2; }
ok()        { printf '%b\n' "  ${GREEN}✓${NC} $*"; }
info()      { printf '%b\n' "  ${WHITE}$*${NC}"; }
dim()       { printf '%b\n' "  ${DIM}$*${NC}"; }

die()       { __RMDJ_CLEAN_EXIT="true"; err "$*"; exit 1; }

# ─── 路径常量 ──────────────────────────────────────────────────────────────
WORK_DIR=/opt/remnanode
COMPOSE_FILE="$WORK_DIR/docker-compose.yml"
LOG_DIR="$WORK_DIR/logs"
LOG_API_SCRIPT="$WORK_DIR/log_api.py"
LOG_API_TOKEN_FILE="$WORK_DIR/log_api_token"

PANEL_DIR=/opt/remnawave
PANEL_COMPOSE_FILE="$PANEL_DIR/docker-compose.yml"
PANEL_ENV_FILE="$PANEL_DIR/.env"
PANEL_COMPOSE_URL="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/docker-compose-prod.yml"
PANEL_ENV_URL="https://raw.githubusercontent.com/remnawave/backend/refs/heads/main/.env.sample"

# ─── 全局开关 (CLI 解析后填充) ─────────────────────────────────────────────
ARG_TOKEN=""
ARG_PORT=""
ARG_BIND=""
ARG_X25519=""
ARG_MODE=""
DRY_RUN="false"
DO_UNINSTALL="false"
DO_UPDATE="false"

print_help() {
    cat <<HLP
用法:
  bash rmdj.sh [选项]

模式:
  --panel             安装 / 配置 Remnawave 主面板
  --node              安装 / 配置 Remnawave Node (默认旧行为)
  --x25519            只获取 remnanode 容器里的 Xray X25519 密钥
  --update            拉取新镜像并 recreate 当前 (panel 或 node)
  --uninstall         停止并清理对应模式的容器与目录 (会自动备份)
  --dry-run           仅展示将要做的事, 不真正写入或启动

选项:
  -t, --token <hex>   日志 API 共享 token (默认沿用已有/自动生成)
  -p, --port  <num>   日志 API 端口      (默认 9091)
  -b, --bind  <ip>    日志 API 绑定地址  (默认 0.0.0.0)
  -h, --help          显示这段帮助

环境变量等价:
  LOG_API_TOKEN  LOG_API_PORT  LOG_API_BIND  NO_COLOR

示例:
  # 首台节点 (自动生成 token)
  bash <(curl -s -L .../rmdj.sh)

  # 后续节点共享 token
  LOG_API_TOKEN=abc... bash <(curl -s -L .../rmdj.sh)
  bash <(curl -s -L .../rmdj.sh) --token abc...

  # 安装主面板
  bash <(curl -s -L .../rmdj.sh) --panel

  # 仅看不动
  bash <(curl -s -L .../rmdj.sh) --dry-run

  # 取出 X25519
  bash <(curl -s -L .../rmdj.sh) --x25519
HLP
}

# ─── CLI 解析 (POSIX-ish, 容错) ────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --panel|--install-panel)   ARG_MODE="panel";   shift ;;
        --node|--install-node)     ARG_MODE="node";    shift ;;
        --x25519|--xray-x25519)    ARG_MODE="x25519"; ARG_X25519="true"; shift ;;
        --uninstall)               DO_UNINSTALL="true"; shift ;;
        --update|--upgrade)        DO_UPDATE="true"; shift ;;
        --dry-run|-n)              DRY_RUN="true"; shift ;;
        -t|--token)                [ $# -ge 2 ] || die "$1 缺少参数"; ARG_TOKEN="$2"; shift 2 ;;
        -p|--port)                 [ $# -ge 2 ] || die "$1 缺少参数"; ARG_PORT="$2";  shift 2 ;;
        -b|--bind)                 [ $# -ge 2 ] || die "$1 缺少参数"; ARG_BIND="$2";  shift 2 ;;
        --token=*)                 ARG_TOKEN="${1#*=}"; shift ;;
        --port=*)                  ARG_PORT="${1#*=}";  shift ;;
        --bind=*)                  ARG_BIND="${1#*=}";  shift ;;
        -h|--help)                 __RMDJ_CLEAN_EXIT="true"; print_help; exit 0 ;;
        --) shift; break ;;
        -*) warn "忽略未知选项: $1"; shift ;;
        *)  warn "忽略多余参数: $1"; shift ;;
    esac
done

# CLI 优先级 > 环境变量
[ -n "$ARG_TOKEN" ] && export LOG_API_TOKEN="$ARG_TOKEN"
[ -n "$ARG_PORT"  ] && export LOG_API_PORT="$ARG_PORT"
[ -n "$ARG_BIND"  ] && export LOG_API_BIND="$ARG_BIND"

# ─── root 权限检查 (--help 已经退出, 这里才校验) ────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    die "需要 root 权限, 请使用 sudo 运行"
fi

# ─── 公共工具 ──────────────────────────────────────────────────────────────
print_header() {
    echo
    msg "  ${BOLD}${WHITE}━━━ Remnawave 一体化安装  v6 ━━━${NC}"
    [ "$DRY_RUN" = "true" ] && warn "DRY-RUN 模式: 不会真正写入文件或启动容器"
    echo
}

choose_mode() {
    msg "  ${BOLD}${CYAN}请选择要执行的功能:${NC}"
    msg "    ${WHITE}1.${NC} 安装 / 配置 Remnawave Node"
    msg "    ${WHITE}2.${NC} 安装 / 配置 Remnawave 主面板"
    msg "    ${WHITE}3.${NC} 获取节点 X25519 Reality 密钥"
    echo
    printf '  输入序号 [1]: '
    local choice=""
    # || true 防止 read 在 EOF 时让 set -e 杀脚本
    read -r choice || true
    case "${choice:-1}" in
        2) ARG_MODE="panel" ;;
        3) ARG_MODE="x25519"; ARG_X25519="true" ;;
        *) ARG_MODE="node" ;;
    esac
}

# 16 字节随机 hex (32 字符), 全程 stdlib, 防 token 串
rand_hex() {
    local bytes="${1:-32}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$bytes"
    elif [ -r /dev/urandom ]; then
        # od 在不同平台格式有差异, 用 hexdump 更稳; 没有再 fallback
        if command -v hexdump >/dev/null 2>&1; then
            hexdump -vn "$bytes" -e '/1 "%02x"' /dev/urandom
        else
            head -c "$bytes" /dev/urandom | od -An -tx1 | tr -d ' \n'
        fi
    else
        die "无 openssl 也无 /dev/urandom, 无法生成随机 token"
    fi
}

# 去掉 http(s):// 前缀和尾部 /
normalize_domain() {
    local d="${1:-}"
    d="${d#http://}"; d="${d#https://}"
    d="${d%%/}"
    printf '%s' "$d"
}

# token / secret 校验: 长度 + 字符集 (hex/base64 通用安全字符)
validate_token() {
    local token="$1" minlen="${2:-32}"
    [ -n "$token" ] || return 1
    [ "${#token}" -ge "$minlen" ] || return 1
    [[ "$token" =~ ^[A-Za-z0-9_./+=-]+$ ]] || return 1
}

# 端口校验
validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

# 端口占用预检 (容器 host 网络下尤其重要)
port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {found=1} END{exit !found}'
        return $?
    elif command -v lsof >/dev/null 2>&1; then
        lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk -v p=":$p" '$9 ~ p"$" {found=1} END{exit !found}'
        return $?
    fi
    # 探测工具不可用就当成空闲, 让 docker 自己报
    return 1
}

# 备份文件 (带时间戳, 不会覆盖已有备份)
backup_file_if_exists() {
    local file="$1"
    [ -f "$file" ] || return 0
    [ "$DRY_RUN" = "true" ] && { dim "DRY-RUN: 跳过备份 $file"; return 0; }
    local bak
    bak="${file}.bak.$(date +%Y%m%d%H%M%S).$$"
    cp -p -- "$file" "$bak"
    dim "已备份: $bak"
}

# 原子写入: 先写 tmp, diff 不同才 move; 内容相同直接跳过
atomic_write() {
    local target="$1" content="$2"
    if [ -f "$target" ] && [ "$(cat -- "$target" 2>/dev/null || true)" = "$content" ]; then
        dim "未变更: $target"
        return 0
    fi
    [ "$DRY_RUN" = "true" ] && { dim "DRY-RUN: 将写入 $target ($(printf '%s' "$content" | wc -l) 行)"; return 0; }
    backup_file_if_exists "$target"
    local tmp; tmp=$(mktemp_tracked)
    printf '%s' "$content" > "$tmp"
    mv -f -- "$tmp" "$target"
    ok "写入: $target"
}

# 安全的 .env / KEY=VAL 文件字段更新
# 完全用 bash 字面比较, 永不把 $value 喂给 sed/awk 当模式; 杜绝注入
set_env_var() {
    local file="$1" key="$2" value="$3"
    if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        die "set_env_var: 非法 key '$key'"
    fi
    [ "$DRY_RUN" = "true" ] && { dim "DRY-RUN: $file 中 $key 将设为 (${#value} 字符)"; return 0; }
    [ -f "$file" ] || : > "$file"
    local tmp found=0 line
    tmp=$(mktemp_tracked)
    # 注意: 用 IFS= read -r 保留前导空格; 用 || [ -n "$line" ] 处理无尾行的最后一行
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$found" -eq 0 ] && [[ "$line" =~ ^${key}= ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp"
            found=1
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$file"
    if [ "$found" -eq 0 ]; then
        printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
    mv -f -- "$tmp" "$file"
}

# 从 .env 读取字段 (返回原值, 不解释)
get_env_var() {
    local file="$1" key="$2" line val
    [ -f "$file" ] || { printf ''; return 0; }
    line=$(grep -E "^${key}=" "$file" 2>/dev/null | head -1) || true
    val="${line#${key}=}"
    # 去掉两端的双引号 (如果存在)
    val="${val#\"}"; val="${val%\"}"
    printf '%s' "$val"
}

# ─── 用户交互 ──────────────────────────────────────────────────────────────
read_with_default() {
    # $1=提示  $2=当前值  $3=输出变量名
    local prompt="$1" cur="$2" var="$3" input=""
    if [ -n "$cur" ]; then
        local display="$cur"
        if [ "${#cur}" -gt 60 ]; then
            display="${cur:0:40}...${cur: -10}  (长度 ${#cur})"
        fi
        dim "当前: $display"
        printf '  %s%s%s %s[回车沿用]%s: ' "${WHITE}" "$prompt" "${NC}" "${DIM}" "${NC}"
    else
        printf '  %s%s%s: ' "${WHITE}" "$prompt" "${NC}"
    fi
    read -r input || true
    if [ -z "$input" ] && [ -n "$cur" ]; then
        input="$cur"
    fi
    printf -v "$var" '%s' "$input"
}

confirm() {
    # $1=提示  $2=默认值 (Y/n 或 y/N)
    local prompt="$1" def="${2:-Y}"
    local hint="[Y/n]"
    [ "$def" = "n" ] || [ "$def" = "N" ] && hint="[y/N]"
    printf '  %s%s%s %s: ' "${YELLOW}" "$prompt" "${NC}" "$hint"
    local ans=""
    read -r ans || true
    [ -z "$ans" ] && ans="$def"
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ─── Docker 检测 ──────────────────────────────────────────────────────────
check_docker() {
    printf '  %s检测 Docker ... %s' "${WHITE}" "${NC}"
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        local ver
        ver=$(docker --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        printf '%s已安装%s (%s)\n' "${GREEN}" "${NC}" "${ver:-unknown}"
        # docker daemon 真活着? (host 网络节点尤其重要)
        if ! docker info >/dev/null 2>&1; then
            warn "docker 命令存在但 daemon 不响应, 尝试启动"
            systemctl start docker 2>/dev/null || true
            sleep 2
            docker info >/dev/null 2>&1 || die "docker daemon 无法启动"
        fi
        return 0
    fi
    printf '%s未安装, 正在安装%s\n' "${YELLOW}" "${NC}"
    [ "$DRY_RUN" = "true" ] && { dim "DRY-RUN: 跳过 docker 安装"; return 0; }
    if ! curl -fsSL https://get.docker.com | sh; then
        die "Docker 安装失败, 请手动安装"
    fi
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker  >/dev/null 2>&1 || true
    command -v docker >/dev/null 2>&1 || die "Docker 安装后仍找不到命令"
    ok "Docker 安装完成"
}

# ─── X25519 ────────────────────────────────────────────────────────────────
run_x25519() {
    echo
    msg "  ${BOLD}${CYAN}━━━ X25519 Reality 密钥 ━━━${NC}"
    dim "执行: cd $WORK_DIR && docker exec -it remnanode /usr/local/bin/xray x25519"
    echo
    if ! command -v docker >/dev/null 2>&1; then
        err "Docker 未安装, 无法进入 remnanode 容器"
        return 1
    fi
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'remnanode'; then
        err "remnanode 容器未运行. 请先启动节点:"
        info "cd $WORK_DIR && docker compose up -d"
        return 1
    fi
    [ -d "$WORK_DIR" ] || die "工作目录不存在: $WORK_DIR"
    cd "$WORK_DIR" || die "无法进入 $WORK_DIR"
    docker exec -it remnanode /usr/local/bin/xray x25519
}

# ─── 现有 compose 字段读取 (节点) ──────────────────────────────────────────
CUR_IMAGE=""
CUR_PORT=""
CUR_SECRET=""
CUR_LOG_API_ENABLED="false"
CUR_LOG_API_PORT=""
CUR_LOG_API_BIND=""

load_existing_node() {
    [ -f "$COMPOSE_FILE" ] || return 0

    # image: 取第一个 image 字段
    CUR_IMAGE=$(awk '
        /^[[:space:]]*image:/ {
            sub(/^[[:space:]]*image:[[:space:]]*/, "")
            sub(/^"/, ""); sub(/"[[:space:]]*$/, "")
            sub(/^'\''/, ""); sub(/'\''[[:space:]]*$/, "")
            print
            exit
        }' "$COMPOSE_FILE")

    # NODE_PORT
    CUR_PORT=$(awk '
        /^[[:space:]]*-[[:space:]]*NODE_PORT=/ {
            sub(/^[[:space:]]*-[[:space:]]*NODE_PORT=/, "")
            sub(/^"/, ""); sub(/"[[:space:]]*$/, "")
            print
            exit
        }' "$COMPOSE_FILE")

    # SECRET_KEY: 用锚定 awk 不被值里的 = 截断
    CUR_SECRET=$(awk '
        /^[[:space:]]*-[[:space:]]*SECRET_KEY=/ {
            sub(/^[[:space:]]*-[[:space:]]*SECRET_KEY=/, "")
            sub(/^"/, ""); sub(/"[[:space:]]*$/, "")
            print
            exit
        }' "$COMPOSE_FILE")

    # 日志 API 边车
    if grep -qE '^[[:space:]]*rmdj-logs:' "$COMPOSE_FILE"; then
        CUR_LOG_API_ENABLED="true"
        # 解析 ports: "BIND:PORT:PORT" 形式
        local port_line
        port_line=$(awk '
            /^[[:space:]]*rmdj-logs:/ { in_block=1 }
            in_block && /^[[:space:]]*-[[:space:]]*"[0-9.]+:[0-9]+:[0-9]+"/ {
                print; exit
            }
            in_block && /^[a-zA-Z]/ { exit }
        ' "$COMPOSE_FILE" | grep -oE '"[0-9.]+:[0-9]+:[0-9]+"' | head -1)
        if [ -n "$port_line" ]; then
            local stripped="${port_line//\"/}"
            CUR_LOG_API_BIND="${stripped%%:*}"
            local rest="${stripped#*:}"
            CUR_LOG_API_PORT="${rest%%:*}"
        fi
    fi
}

# ─── 日志 API 相关 ─────────────────────────────────────────────────────────
LOG_API_TOKEN_SOURCE=""

ensure_log_api_token() {
    local provided="${LOG_API_TOKEN:-}"

    if [ -n "$provided" ]; then
        if ! validate_token "$provided" 16; then
            die "提供的 LOG_API_TOKEN 不合法: 长度 ${#provided}, 需 ≥16 且只含 [A-Za-z0-9_./+=-]"
        fi
        LOG_API_TOKEN="$provided"
        LOG_API_TOKEN_SOURCE="provided"
    elif [ -s "$LOG_API_TOKEN_FILE" ]; then
        LOG_API_TOKEN=$(< "$LOG_API_TOKEN_FILE")
        # 兼容历史: 旧文件可能含尾部换行
        LOG_API_TOKEN="${LOG_API_TOKEN%$'\n'}"
        if ! validate_token "$LOG_API_TOKEN" 16; then
            warn "已有 token 文件不合法, 重新生成"
            LOG_API_TOKEN=$(rand_hex 32)
            LOG_API_TOKEN_SOURCE="regenerated"
        else
            LOG_API_TOKEN_SOURCE="existing"
        fi
    else
        LOG_API_TOKEN=$(rand_hex 32)
        LOG_API_TOKEN_SOURCE="generated"
    fi

    if [ "$DRY_RUN" != "true" ]; then
        # 持久化, 严格 600
        local tmp; tmp=$(mktemp_tracked)
        printf '%s\n' "$LOG_API_TOKEN" > "$tmp"
        chmod 600 "$tmp"
        mkdir -p "$WORK_DIR"
        mv -f -- "$tmp" "$LOG_API_TOKEN_FILE"
        chmod 600 "$LOG_API_TOKEN_FILE"
        # 校验权限真生效 (NFS / 奇异 fs 可能不兑现)
        local perm
        perm=$(stat -c '%a' "$LOG_API_TOKEN_FILE" 2>/dev/null \
             || stat -f '%A' "$LOG_API_TOKEN_FILE" 2>/dev/null \
             || echo "?")
        [ "$perm" = "600" ] || warn "Token 文件权限不是 600 (实际 $perm), 注意敏感泄漏"
    fi
}

# 写出 log_api.py — 内嵌完整 Python (与 v5 等价, 但加固超时与异常)
write_log_api_script() {
    [ "$DRY_RUN" = "true" ] && { dim "DRY-RUN: 跳过写 $LOG_API_SCRIPT"; return 0; }
    mkdir -p "$WORK_DIR"
    local content
    content=$(cat <<'PYEOF'
#!/usr/bin/env python3
# rmdj 日志 API · 单文件 stdlib 零依赖
# Endpoints:
#   GET /health                    免鉴权, 健康探针
#   GET /raw?tail=N&user=X         原始行 (可过滤)
#   GET /stats                     Top 用户 / 目标 / 客户端 IP
#   GET /user/<email_or_uuid>     单用户视图
import os, re, json, time
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs, unquote

LOG_DIR    = os.environ.get('LOG_DIR', '/var/log/xray')
ACCESS_LOG = os.path.join(LOG_DIR, 'access.log')
TOKEN      = (os.environ.get('LOG_API_TOKEN', '') or '').strip()
PORT       = int(os.environ.get('PORT', '9091'))
MAX_TAIL   = 5000
SCAN_BYTES = 16 * 1024 * 1024
STATS_TIMEOUT_SEC = 8.0   # /stats 单次扫描硬上限, 防大文件 OOM/卡死

LINE_RE = re.compile(
    r'^(?P<ts>\d{4}/\d{2}/\d{2}\s\d{2}:\d{2}:\d{2})\s+'
    r'from\s+(?P<src>\S+)\s+'
    r'(?P<verdict>accepted|rejected)\s+'
    r'(?P<proto>\w+):(?P<dst>[^\s\[]+)'
    r'(?:\s+\[(?P<route>[^\]]+)\])?'
    r'(?:\s+email:\s+(?P<email>\S+))?'
)

def parse_line(line):
    m = LINE_RE.match(line)
    if not m: return None
    d = m.groupdict()
    src_full = d.get('src') or ''
    src_ip = src_full.rsplit(':', 1)[0] if ':' in src_full else src_full
    return {
        'time': d.get('ts'),
        'src': src_full,
        'srcIp': src_ip,
        'verdict': d.get('verdict') or '',
        'proto': d.get('proto') or '',
        'dst': d.get('dst') or '',
        'route': d.get('route') or '',
        'email': d.get('email') or '',
    }

def read_tail_lines(path, max_lines, max_bytes=SCAN_BYTES):
    if not os.path.exists(path): return []
    try:
        size = os.path.getsize(path)
        with open(path, 'rb') as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
                f.readline()
            data = f.read()
        text = data.decode('utf-8', errors='replace')
        lines = text.splitlines()
        return lines[-max_lines:] if max_lines and len(lines) > max_lines else lines
    except Exception:
        return []

def iter_all_lines(path, deadline=None):
    if not os.path.exists(path): return
    try:
        with open(path, 'r', errors='replace') as f:
            for line in f:
                if deadline and time.time() > deadline:
                    return
                yield line
    except Exception:
        return

def topk(d, k=20):
    return [{'name': n, 'count': c}
            for n, c in sorted(d.items(), key=lambda x: -x[1])[:k]]

class Handler(BaseHTTPRequestHandler):
    server_version = 'rmdj-logs/2.0'
    def log_message(self, *a, **k): pass

    def _auth_ok(self):
        if not TOKEN: return True
        h = self.headers.get('Authorization', '') or ''
        # constant-time-ish 比较, 避免侧信道
        expected = 'Bearer ' + TOKEN
        if len(h) != len(expected): return False
        diff = 0
        for a, b in zip(h, expected):
            diff |= ord(a) ^ ord(b)
        return diff == 0

    def _send(self, code, body, ct='application/json'):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False)
        b = body.encode('utf-8') if isinstance(body, str) else body
        self.send_response(code)
        self.send_header('Content-Type', ct + '; charset=utf-8')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', 'Authorization, Content-Type')
        self.send_header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        try:
            self.wfile.write(b)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_OPTIONS(self):
        self._send(204, '')

    def do_GET(self):
        try:
            u = urlparse(self.path)
            q = parse_qs(u.query or '')

            if u.path == '/health':
                exists = os.path.exists(ACCESS_LOG)
                return self._send(200, {
                    'ok': True,
                    'logFile': ACCESS_LOG,
                    'exists': exists,
                    'size': os.path.getsize(ACCESS_LOG) if exists else 0,
                    'time': int(time.time()),
                    'tokenSet': bool(TOKEN),
                })

            if not self._auth_ok():
                return self._send(401, {'error': 'unauthorized', 'hint': 'Authorization: Bearer <token>'})

            if u.path == '/raw':
                tail = max(1, min(MAX_TAIL, int((q.get('tail') or ['200'])[0] or 200)))
                user_q = (q.get('user') or [''])[0].strip().lower()
                verdict_q = (q.get('verdict') or [''])[0].strip().lower()
                lines = read_tail_lines(ACCESS_LOG, max_lines=tail * 4)
                out = []
                for line in lines:
                    p = parse_line(line)
                    if not p: continue
                    if user_q and user_q not in (p['email'] or '').lower(): continue
                    if verdict_q and verdict_q != p['verdict']: continue
                    out.append(p)
                out = out[-tail:]
                return self._send(200, {'lines': out, 'count': len(out)})

            if u.path == '/stats':
                users, targets, ips = {}, {}, {}
                verdicts = {'accepted': 0, 'rejected': 0}
                total = 0
                t0 = time.time()
                deadline = t0 + STATS_TIMEOUT_SEC
                truncated = False
                for line in iter_all_lines(ACCESS_LOG, deadline=deadline):
                    p = parse_line(line)
                    if not p: continue
                    total += 1
                    e = p['email'] or 'anonymous'
                    users[e] = users.get(e, 0) + 1
                    targets[p['dst']] = targets.get(p['dst'], 0) + 1
                    if p['srcIp']: ips[p['srcIp']] = ips.get(p['srcIp'], 0) + 1
                    if p['verdict'] in verdicts: verdicts[p['verdict']] += 1
                else:
                    pass
                if time.time() > deadline:
                    truncated = True
                return self._send(200, {
                    'totalLines': total,
                    'verdicts': verdicts,
                    'topUsers': topk(users),
                    'topTargets': topk(targets),
                    'topIps': topk(ips),
                    'scanMs': int((time.time() - t0) * 1000),
                    'truncated': truncated,
                })

            if u.path.startswith('/user/'):
                user = unquote(u.path[len('/user/'):]).strip().lower()
                if not user:
                    return self._send(400, {'error': 'user required'})
                tail = max(1, min(MAX_TAIL, int((q.get('tail') or ['200'])[0] or 200)))
                recent, targets, srcs = [], {}, {}
                verdicts = {'accepted': 0, 'rejected': 0}
                deadline = time.time() + STATS_TIMEOUT_SEC
                for line in iter_all_lines(ACCESS_LOG, deadline=deadline):
                    p = parse_line(line)
                    if not p: continue
                    if user not in (p['email'] or '').lower(): continue
                    recent.append(p)
                    targets[p['dst']] = targets.get(p['dst'], 0) + 1
                    if p['srcIp']: srcs[p['srcIp']] = srcs.get(p['srcIp'], 0) + 1
                    if p['verdict'] in verdicts: verdicts[p['verdict']] += 1
                return self._send(200, {
                    'user': user,
                    'totalLines': len(recent),
                    'verdicts': verdicts,
                    'recent': recent[-tail:],
                    'topTargets': topk(targets),
                    'topSrcIps': topk(srcs),
                })

            return self._send(404, {
                'error': 'not found',
                'endpoints': ['/health', '/raw', '/stats', '/user/<id>'],
            })
        except Exception as exc:
            try:
                return self._send(500, {'error': 'internal', 'detail': str(exc)})
            except Exception:
                pass

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

if __name__ == '__main__':
    print('rmdj-logs listening on :%d  log=%s  token=%s' % (
        PORT, ACCESS_LOG, ('set' if TOKEN else 'NONE (开放访问, 强烈建议设)')
    ), flush=True)
    ThreadedHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
PYEOF
)
    atomic_write "$LOG_API_SCRIPT" "$content"
    chmod 644 "$LOG_API_SCRIPT" 2>/dev/null || true
}

# ─── 主面板下载 / 安装 ─────────────────────────────────────────────────────
download_file() {
    local url="$1" file="$2" label="$3"
    if [ -f "$file" ] && [ -s "$file" ]; then
        if ! confirm "$label 已存在, 重新下载覆盖?" "n"; then
            dim "沿用: $file"
            return 0
        fi
        backup_file_if_exists "$file"
    fi
    [ "$DRY_RUN" = "true" ] && { dim "DRY-RUN: 将下载 $url → $file"; return 0; }
    info "下载 $label ..."
    if ! curl -fsSL --connect-timeout 10 --max-time 60 -o "$file" -- "$url"; then
        err "下载失败: $url"
        return 1
    fi
    [ -s "$file" ] || { err "下载得到空文件: $file"; rm -f "$file"; return 1; }
    ok "已保存: $file"
}

panel_generate_secrets() {
    local pg_pw
    set_env_var "$PANEL_ENV_FILE" "JWT_AUTH_SECRET"        "$(rand_hex 64)"
    set_env_var "$PANEL_ENV_FILE" "JWT_API_TOKENS_SECRET"  "$(rand_hex 64)"
    set_env_var "$PANEL_ENV_FILE" "METRICS_PASS"           "$(rand_hex 64)"
    set_env_var "$PANEL_ENV_FILE" "WEBHOOK_SECRET_HEADER"  "$(rand_hex 64)"
    pg_pw=$(rand_hex 24)
    set_env_var "$PANEL_ENV_FILE" "POSTGRES_PASSWORD" "$pg_pw"
    # DATABASE_URL 重写 — 用纯 bash 回避 sed 注入风险
    if [ "$DRY_RUN" != "true" ] && [ -f "$PANEL_ENV_FILE" ]; then
        local cur_url
        cur_url=$(get_env_var "$PANEL_ENV_FILE" "DATABASE_URL")
        if [ -n "$cur_url" ]; then
            # postgresql://USER:PASS@HOST:PORT/DB...  → 替换 PASS
            local new_url
            if [[ "$cur_url" =~ ^(postgresql://[^:/]+:)[^@]*(@.*)$ ]]; then
                new_url="${BASH_REMATCH[1]}${pg_pw}${BASH_REMATCH[2]}"
                set_env_var "$PANEL_ENV_FILE" "DATABASE_URL" "$new_url"
            else
                warn "DATABASE_URL 格式不符合 postgresql://user:pass@host/db, 已跳过密码同步"
            fi
        fi
    fi
    ok "已生成 JWT / API Token / Metrics / Webhook / Postgres 密钥"
}

install_panel() {
    echo
    msg "  ${BOLD}${CYAN}━━━ Remnawave 主面板安装 ━━━${NC}"
    warn "面板内部服务请勿直接暴露公网, 用反向代理"
    dim "目录: $PANEL_DIR"
    echo

    [ "$DRY_RUN" = "true" ] || mkdir -p "$PANEL_DIR" || die "无法创建 $PANEL_DIR"
    [ -d "$PANEL_DIR" ] || [ "$DRY_RUN" = "true" ] || die "$PANEL_DIR 不存在"

    if [ "$DRY_RUN" != "true" ]; then
        cd "$PANEL_DIR" || die "cd 失败: $PANEL_DIR"
    fi

    download_file "$PANEL_COMPOSE_URL" "$PANEL_COMPOSE_FILE" "docker-compose.yml" || return 1
    local env_was_missing="false"
    [ -f "$PANEL_ENV_FILE" ] || env_was_missing="true"
    download_file "$PANEL_ENV_URL" "$PANEL_ENV_FILE" ".env" || return 1

    if [ "$env_was_missing" = "true" ]; then
        panel_generate_secrets
    else
        if confirm "是否重新生成 .env 内的安全密钥?" "n"; then
            backup_file_if_exists "$PANEL_ENV_FILE"
            panel_generate_secrets
        fi
    fi

    local cur_front cur_sub front_domain sub_domain
    cur_front=$(get_env_var "$PANEL_ENV_FILE" "FRONT_END_DOMAIN")
    cur_sub=$(get_env_var "$PANEL_ENV_FILE" "SUB_PUBLIC_DOMAIN")
    read_with_default "FRONT_END_DOMAIN (面板域名, 不带 http/https)" "$cur_front" front_domain
    front_domain=$(normalize_domain "$front_domain")
    [ -n "$front_domain" ] || die "FRONT_END_DOMAIN 不能为空"
    [ -n "$cur_sub" ] || cur_sub="${front_domain}/api/sub"
    read_with_default "SUB_PUBLIC_DOMAIN (订阅地址域名/路径)" "$cur_sub" sub_domain
    sub_domain=$(normalize_domain "$sub_domain")
    [ -n "$sub_domain" ] || die "SUB_PUBLIC_DOMAIN 不能为空"
    set_env_var "$PANEL_ENV_FILE" "FRONT_END_DOMAIN" "$front_domain"
    set_env_var "$PANEL_ENV_FILE" "SUB_PUBLIC_DOMAIN" "$sub_domain"

    echo
    msg "  ${BOLD}${CYAN}━━━ 面板配置摘要 ━━━${NC}"
    msg "    目录:              ${WHITE}$PANEL_DIR${NC}"
    msg "    FRONT_END_DOMAIN:  ${WHITE}$front_domain${NC}"
    msg "    SUB_PUBLIC_DOMAIN: ${WHITE}$sub_domain${NC}"
    msg "    Compose:           ${WHITE}$PANEL_COMPOSE_FILE${NC}"
    msg "    Env:               ${WHITE}$PANEL_ENV_FILE${NC}"
    msg "  ${BOLD}${CYAN}━━━━━━━━━━━━━━━━${NC}"
    echo

    if [ "$DRY_RUN" = "true" ]; then
        info "DRY-RUN: 跳过启动, 配置仅在内存"
    elif confirm "是否启动主面板容器? (docker compose up -d)" "Y"; then
        cd "$PANEL_DIR" || die "cd 失败: $PANEL_DIR"
        if ! docker compose up -d; then
            err "docker compose up -d 失败"
            return 1
        fi
        ok "已执行 docker compose up -d"
        if confirm "是否跟随查看日志?" "n"; then
            docker compose logs -f -t || true
        else
            dim "查看日志: cd $PANEL_DIR && docker compose logs -f -t"
        fi
    else
        info "已跳过. 手动启动: cd $PANEL_DIR && docker compose up -d"
    fi
    echo
    warn "下一步: 配置反向代理到面板, 不要把内部服务直接暴露公网"
}

# ─── 日志 API 询问 ────────────────────────────────────────────────────────
LOG_API_ENABLED="false"
LOG_API_PORT=""
LOG_API_BIND=""

ask_log_api() {
    echo
    msg "  ${BOLD}${CYAN}━━━ 日志 API (可选) ━━━${NC}"
    dim "启用后, 面板通过 HTTP 拉取这台节点的访问日志:"
    dim "  - 每个用户访问了哪些目标 / 域名 / IP"
    dim "  - 客户端连接 IP 与连接数"
    dim "  - Top 用户 / Top 目标 / Top 源 IP"
    dim "前提: Xray 配置里要有 log.access = \"/var/log/xray/access.log\""
    msg "  ${BOLD}${WHITE}多节点共享 token 提示:${NC}"
    dim "  - 首台机直接跑, 自动生成 token"
    dim "  - 后续机用: LOG_API_TOKEN=<那段 hex> bash <(curl ...)"
    dim "  - 面板里只配一次, 自动从 Remnawave 节点列表逐个拉"
    echo

    if [ "$CUR_LOG_API_ENABLED" = "true" ]; then
        dim "当前已启用, 端口 $CUR_LOG_API_PORT, 绑定 $CUR_LOG_API_BIND"
    fi

    local ans=""
    if [ -n "${LOG_API_TOKEN:-}" ]; then
        ok "检测到通过参数/环境变量传入 token, 自动启用"
        ans="y"
    elif [ "$CUR_LOG_API_ENABLED" = "true" ]; then
        if confirm "继续启用日志 API?" "Y"; then ans="y"; else ans="n"; fi
    else
        if confirm "启用日志 API?" "Y"; then ans="y"; else ans="n"; fi
    fi
    [[ "$ans" =~ ^[Yy]$ ]] || { LOG_API_ENABLED="false"; return 0; }
    LOG_API_ENABLED="true"

    # 端口
    local def_port="${LOG_API_PORT:-${CUR_LOG_API_PORT:-9091}}"
    if [ -n "${ARG_PORT:-}${LOG_API_PORT:-}" ] && validate_port "$def_port"; then
        LOG_API_PORT="$def_port"
        dim "日志 API 端口: ${WHITE}$LOG_API_PORT${NC} (来自参数)"
    else
        local p=""
        while true; do
            read_with_default "日志 API 端口" "$def_port" p
            if validate_port "$p"; then LOG_API_PORT="$p"; break; fi
            err "端口必须是 1-65535 整数"
        done
    fi

    # 绑定
    local def_bind="${LOG_API_BIND:-${CUR_LOG_API_BIND:-0.0.0.0}}"
    if [ -n "${ARG_BIND:-}${LOG_API_BIND:-}" ]; then
        LOG_API_BIND="$def_bind"
        dim "绑定地址: ${WHITE}$LOG_API_BIND${NC} (来自参数)"
    else
        dim "绑定地址: 0.0.0.0=面板远程可拉  /  127.0.0.1=只能本机调用"
        local b=""
        read_with_default "绑定地址" "$def_bind" b
        LOG_API_BIND="${b:-0.0.0.0}"
    fi

    # 端口冲突预检
    if port_in_use "$LOG_API_PORT"; then
        warn "端口 $LOG_API_PORT 已被占用, 启动后可能失败. 继续 (但请知悉)"
    fi

    ensure_log_api_token
    write_log_api_script
}

# ─── compose 生成 (节点) ───────────────────────────────────────────────────
write_compose_node() {
    local img="$1" port="$2" secret="$3"

    # secret 安全性: docker compose value 不允许某些字符在无引号上下文中, 我们用双引号包裹.
    # secret 里如果含有 " 或 $ 会污染 yaml. 校验一下:
    if [[ "$secret" == *'"'* ]]; then
        die "SECRET_KEY 含双引号, 无法安全写入 yaml. 请重新生成"
    fi

    [ "$DRY_RUN" = "true" ] || mkdir -p "$LOG_DIR" || die "无法创建 $LOG_DIR"

    local body
    body="$(cat <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: $img
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=$port
      - SECRET_KEY="$secret"
    volumes:
      - $LOG_DIR:/var/log/xray
EOF
)"

    if [ "$LOG_API_ENABLED" = "true" ]; then
        body="$body
"
        body+="$(cat <<EOF

  rmdj-logs:
    container_name: rmdj-logs
    hostname: rmdj-logs
    image: python:3.12-alpine
    restart: always
    command: python /app/log_api.py
    environment:
      - PORT=$LOG_API_PORT
      - LOG_DIR=/var/log/xray
      - LOG_API_TOKEN=$LOG_API_TOKEN
    volumes:
      - $LOG_API_SCRIPT:/app/log_api.py:ro
      - $LOG_DIR:/var/log/xray:ro
    ports:
      - "$LOG_API_BIND:$LOG_API_PORT:$LOG_API_PORT"
EOF
)"
    fi

    atomic_write "$COMPOSE_FILE" "$body"
}

# ─── 启动容器 ──────────────────────────────────────────────────────────────
wait_health() {
    # 健康检查带退避: $1=URL  $2=最大秒数(默认 15)
    local url="$1" max="${2:-15}" elapsed=0 step=1
    while [ "$elapsed" -lt "$max" ]; do
        if curl -fs --max-time 2 "$url" >/dev/null 2>&1; then return 0; fi
        sleep "$step"
        elapsed=$((elapsed + step))
        [ "$step" -lt 4 ] && step=$((step + 1))
    done
    return 1
}

start_container_node() {
    [ "$DRY_RUN" = "true" ] && { dim "DRY-RUN: 跳过 docker compose up"; return 0; }
    cd "$WORK_DIR" || die "cd 失败: $WORK_DIR"
    echo
    msg "  ${CYAN}拉取镜像并启动...${NC}"
    echo
    if ! docker compose up -d; then
        err "docker compose up -d 失败, 查看上面的错误"
        return 1
    fi
    echo
    sleep 1

    local status
    status=$(docker ps --filter 'name=^remnanode$' --format '{{.Names}}  {{.Status}}' 2>/dev/null || true)
    if [ -n "$status" ]; then
        msg "  ${GREEN}${BOLD}✓ remnanode 启动成功${NC}"
        info "$status"
    else
        err "remnanode 启动异常, 最近日志:"
        docker compose logs --tail 20 remnanode || true
        return 1
    fi

    if [ "$LOG_API_ENABLED" = "true" ]; then
        local log_status
        log_status=$(docker ps --filter 'name=^rmdj-logs$' --format '{{.Names}}  {{.Status}}' 2>/dev/null || true)
        if [ -n "$log_status" ]; then
            msg "  ${GREEN}${BOLD}✓ rmdj-logs 启动成功${NC}"
            info "$log_status"
        else
            err "rmdj-logs 启动异常, 最近日志:"
            docker compose logs --tail 20 rmdj-logs || true
        fi
    fi
}

# ─── update / uninstall 模式 ───────────────────────────────────────────────
do_update_target() {
    local dir="$1" label="$2"
    [ -d "$dir" ] || die "$label 目录不存在: $dir"
    [ -f "$dir/docker-compose.yml" ] || die "$label 没有 docker-compose.yml"
    [ "$DRY_RUN" = "true" ] && { dim "DRY-RUN: 将 cd $dir && docker compose pull && up -d"; return 0; }
    cd "$dir" || die "cd 失败: $dir"
    info "拉取新镜像 ($label)"
    docker compose pull
    info "重建容器 ($label)"
    docker compose up -d
    ok "$label 已更新"
}

do_uninstall_target() {
    local dir="$1" label="$2"
    [ -d "$dir" ] || { dim "$label 目录不存在, 无需清理"; return 0; }
    warn "即将清理 $label: 容器停止 + 目录备份后清空"
    confirm "确定执行 $label 卸载?" "n" || { info "已取消"; return 0; }
    [ "$DRY_RUN" = "true" ] && { dim "DRY-RUN: 跳过实际卸载"; return 0; }
    if [ -f "$dir/docker-compose.yml" ]; then
        ( cd "$dir" && docker compose down -v ) || warn "docker compose down 失败, 继续"
    fi
    local archive
    archive="${dir}.archived.$(date +%Y%m%d%H%M%S)"
    mv -- "$dir" "$archive" && ok "已归档目录到: $archive"
}

# ─── main 调度 ─────────────────────────────────────────────────────────────
print_header
check_docker

# 模式自动推断: --uninstall / --update 没显式 mode 时, 沿用面板/节点目录是否存在
if [ "$DO_UNINSTALL" = "true" ] || [ "$DO_UPDATE" = "true" ]; then
    if [ -z "$ARG_MODE" ]; then
        if [ -d "$PANEL_DIR" ] && [ ! -d "$WORK_DIR" ]; then
            ARG_MODE="panel"
        elif [ -d "$WORK_DIR" ] && [ ! -d "$PANEL_DIR" ]; then
            ARG_MODE="node"
        else
            choose_mode
        fi
    fi
fi

if [ "$DO_UNINSTALL" = "true" ]; then
    case "$ARG_MODE" in
        panel) do_uninstall_target "$PANEL_DIR" "Remnawave 面板" ;;
        node)  do_uninstall_target "$WORK_DIR"  "Remnawave 节点" ;;
        *)     die "卸载需指定 --panel 或 --node" ;;
    esac
    exit 0
fi

if [ "$DO_UPDATE" = "true" ]; then
    case "$ARG_MODE" in
        panel) do_update_target "$PANEL_DIR" "Remnawave 面板" ;;
        node)  do_update_target "$WORK_DIR"  "Remnawave 节点" ;;
        *)     die "更新需指定 --panel 或 --node" ;;
    esac
    exit 0
fi

# 没指定 mode: 有 token/port/bind 就默认 node, 否则进交互菜单
if [ -z "$ARG_MODE" ]; then
    if [ -n "$ARG_TOKEN$ARG_PORT$ARG_BIND" ] || [ -n "${LOG_API_TOKEN:-}" ]; then
        ARG_MODE="node"
    else
        choose_mode
    fi
fi

if [ "$ARG_MODE" = "panel" ]; then
    install_panel
    exit $?
fi

if [ "$ARG_MODE" = "x25519" ] || [ "$ARG_X25519" = "true" ]; then
    run_x25519
    exit $?
fi

# ─── node 安装主流程 ───────────────────────────────────────────────────────
[ "$DRY_RUN" = "true" ] || mkdir -p "$WORK_DIR" || die "无法创建 $WORK_DIR"
if [ "$DRY_RUN" != "true" ]; then
    cd "$WORK_DIR" || die "cd 失败: $WORK_DIR"
fi

echo
if [ -f "$COMPOSE_FILE" ] && [ -s "$COMPOSE_FILE" ]; then
    msg "  ${YELLOW}检测到现有配置:${NC} $COMPOSE_FILE"
    dim "回车沿用现有值, 输入新值则替换"
else
    info "首次部署, 请依次填入以下参数"
    dim "参数可从面板 Nodes → 添加节点 页面复制"
fi
echo

load_existing_node

# image
[ -z "$CUR_IMAGE" ] && CUR_IMAGE="remnawave/node:latest"
read_with_default "镜像 image" "$CUR_IMAGE" IMG
[ -n "$IMG" ] || die "镜像不能为空"

# 端口
PORT=""
while true; do
    read_with_default "NODE_PORT (节点监听端口, 例 2222)" "$CUR_PORT" PORT
    if validate_port "$PORT"; then break; fi
    err "端口必须是 1-65535 整数"
done

# SECRET_KEY
SECRET=""
while true; do
    echo
    if [ -n "$CUR_SECRET" ]; then
        info "SECRET_KEY ${DIM}(当前长度 ${#CUR_SECRET}, 回车沿用)${NC}"
        printf '  新 SECRET_KEY (不改留空): '
    else
        info "SECRET_KEY ${DIM}(从面板复制, 一长串 base64)${NC}"
        printf '  SECRET_KEY: '
    fi
    INPUT=""
    read -r INPUT || true
    if [ -z "$INPUT" ] && [ -n "$CUR_SECRET" ]; then
        SECRET="$CUR_SECRET"
        break
    fi
    INPUT="${INPUT#\"}"; INPUT="${INPUT%\"}"
    INPUT="${INPUT#\'}"; INPUT="${INPUT%\'}"
    if [ -n "$INPUT" ] && [ "${#INPUT}" -ge 50 ]; then
        if [[ "$INPUT" == *'"'* ]]; then
            err "SECRET_KEY 含双引号, 无法安全写入 yaml; 请重新生成"
            continue
        fi
        SECRET="$INPUT"
        break
    fi
    err "SECRET_KEY 长度不对 (实际 ${#INPUT}), 应该一长串字符 (通常 >500)"
done

# 端口冲突预检
if port_in_use "$PORT"; then
    warn "NODE_PORT $PORT 已被占用, 启动后可能失败"
fi

# 日志 API
LOG_API_ENABLED="false"; LOG_API_PORT=""; LOG_API_BIND=""; LOG_API_TOKEN="${LOG_API_TOKEN:-}"
ask_log_api

# 生成 compose
echo
write_compose_node "$IMG" "$PORT" "$SECRET"
if [ "$LOG_API_ENABLED" = "true" ]; then
    ok "日志 API 脚本: $LOG_API_SCRIPT"
    ok "日志目录:     $LOG_DIR"
fi
echo

# 摘要
msg "  ${BOLD}${CYAN}━━━ 配置摘要 ━━━${NC}"
msg "    image:       ${WHITE}$IMG${NC}"
msg "    NODE_PORT:   ${WHITE}$PORT${NC}"
msg "    SECRET_KEY:  ${WHITE}${SECRET:0:40}...${SECRET: -10}${NC} ${DIM}(长度 ${#SECRET})${NC}"
if [ "$LOG_API_ENABLED" = "true" ]; then
    PUBLIC_IP=""
    PUBLIC_IP=$(curl -fs --max-time 4 https://api.ipify.org 2>/dev/null \
              || curl -fs --max-time 4 https://ifconfig.me 2>/dev/null \
              || (hostname -I 2>/dev/null | awk '{print $1}') \
              || echo "")
    echo
    msg "    ${BOLD}${CYAN}日志 API:${NC}"
    msg "      端口:   ${WHITE}$LOG_API_PORT${NC}"
    msg "      绑定:   ${WHITE}$LOG_API_BIND${NC}"
    msg "      URL:    ${WHITE}http://${PUBLIC_IP:-<本机IP>}:$LOG_API_PORT${NC}"
    msg "      Token:  ${WHITE}$LOG_API_TOKEN${NC} ${DIM}(${LOG_API_TOKEN_SOURCE:-?})${NC}"
    echo
    case "${LOG_API_TOKEN_SOURCE:-}" in
        generated)
            msg "    ${BOLD}${YELLOW}★ 这是首台节点, Token 已自动生成. 后续节点请用同一个 token:${NC}"
            msg "      ${WHITE}LOG_API_TOKEN=$LOG_API_TOKEN bash <(curl -s -L .../rmdj.sh)${NC}"
            echo ;;
        provided)
            ok "使用了参数/环境变量传入的共享 Token"; echo ;;
        regenerated)
            warn "原 token 文件不合法已重新生成, 请同步给其他节点"
            msg "      ${WHITE}LOG_API_TOKEN=$LOG_API_TOKEN bash <(curl -s -L .../rmdj.sh)${NC}"
            echo ;;
    esac
    msg "    ${YELLOW}面板对接:${NC}"
    msg "      ${WHITE}1.${NC} 面板里 ${BOLD}只配一次${NC}: 端口=${WHITE}$LOG_API_PORT${NC}  Token=${WHITE}$LOG_API_TOKEN${NC}"
    msg "      ${WHITE}2.${NC} 面板会自动从 Remnawave ${WHITE}/api/nodes${NC} 读节点 IP, 逐个拉日志"
    msg "      ${WHITE}3.${NC} 节点 IP/域名以面板里的 Node.address 为准 (本机 ${PUBLIC_IP:-?} 是否一致?)"
    echo
    msg "    ${YELLOW}必要步骤:${NC} 在面板生成 Xray 配置时务必加上"
    dim "\"log\": { \"access\": \"/var/log/xray/access.log\", \"loglevel\": \"warning\" }"
    dim "否则节点不会写日志, 这个 API 永远是空的"
fi
msg "  ${BOLD}${CYAN}━━━━━━━━━━━━━━━━${NC}"
echo

# 启动
if [ "$DRY_RUN" = "true" ]; then
    info "DRY-RUN 完成. 移除 --dry-run 即可真正启动"
elif confirm "是否启动容器? (docker compose up -d)" "Y"; then
    start_container_node || true
else
    info "已跳过. 手动启动: cd $WORK_DIR && docker compose up -d"
fi

echo
if confirm "是否现在获取 X25519 Reality 密钥?" "n"; then
    run_x25519 || true
else
    dim "需要时执行: cd $WORK_DIR && docker exec -it remnanode /usr/local/bin/xray x25519"
fi

# 自检日志 API (退避重试, 替代固定 sleep)
if [ "$LOG_API_ENABLED" = "true" ] && [ "$DRY_RUN" != "true" ]; then
    echo
    printf '  %s自检日志 API (最多 15 秒) ... %s' "${WHITE}" "${NC}"
    if wait_health "http://127.0.0.1:$LOG_API_PORT/health" 15; then
        printf '%s✓ 通%s\n' "${GREEN}" "${NC}"
    else
        printf '%s✗ 不通%s\n' "${YELLOW}" "${NC}"
        dim "排查: docker logs rmdj-logs --tail 30"
    fi
fi

echo
dim "再次运行本脚本可修改配置 (已有字段会自动填充为默认值)"
if [ "$LOG_API_ENABLED" = "true" ]; then
    dim "日志 Token 保存在: $LOG_API_TOKEN_FILE  (需要时直接 cat)"
fi
echo
