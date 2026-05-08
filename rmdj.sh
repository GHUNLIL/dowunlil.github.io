#!/bin/bash
# Remnawave Node 对接脚本 (分字段交互式版 + 日志 API)
# bash <(curl -s -L https://raw.githubusercontent.com/GHUNLIL/dowunlil.github.io/main/rmdj.sh)
# 再次运行会读取已有配置,支持修改单个字段或直接沿用
#
# v2 新增:
#   - 可选启用"日志 API"边车 (rmdj-logs)
#   - 把 Xray access.log 通过 HTTP + Bearer Token 暴露给面板
#   - 面板可以查询每个用户的访问目标 / 客户端 IP / 总览统计
#   - 需要在生成的 Xray config 里加 log.access = "/var/log/xray/access.log"
#
# v3 新增:
#   - 支持"共享 Token":所有节点用同一个 token,面板里只配一次
#   - 用法 1:  LOG_API_TOKEN=<hex> bash <(curl -s -L .../rmdj.sh)
#   - 用法 2:  bash <(curl -s -L .../rmdj.sh) --token <hex>
#   - 用法 3:  直接跑,首台机会自动生成,后续机粘进来即可
#   - 面板拿 Remnawave /api/nodes 自动发现节点 IP,不再手填每个节点

set -uo pipefail

# 解析命令行参数
ARG_TOKEN=""
ARG_PORT=""
ARG_BIND=""
while [ $# -gt 0 ]; do
    case "$1" in
        -t|--token)        ARG_TOKEN="$2"; shift 2 ;;
        -p|--port)         ARG_PORT="$2";  shift 2 ;;
        -b|--bind)         ARG_BIND="$2";  shift 2 ;;
        --token=*)         ARG_TOKEN="${1#*=}"; shift ;;
        --port=*)          ARG_PORT="${1#*=}";  shift ;;
        --bind=*)          ARG_BIND="${1#*=}";  shift ;;
        -h|--help)
            cat <<HLP
用法:
  bash rmdj.sh [选项]

选项:
  -t, --token <hex>   日志 API 共享 token (默认沿用已有/自动生成)
  -p, --port  <num>   日志 API 端口      (默认 9091)
  -b, --bind  <ip>    日志 API 绑定地址  (默认 0.0.0.0)
  -h, --help          显示这段帮助

环境变量等价:
  LOG_API_TOKEN  LOG_API_PORT  LOG_API_BIND

示例:
  # 首台机:让脚本自动生成
  bash <(curl -s -L .../rmdj.sh)

  # 后续机:用第一台输出的 token
  LOG_API_TOKEN=abc... bash <(curl -s -L .../rmdj.sh)

  # 或:
  bash <(curl -s -L .../rmdj.sh) --token abc...
HLP
            exit 0
            ;;
        *) shift ;;
    esac
done

# 命令行 > 环境变量
[ -n "$ARG_TOKEN" ] && export LOG_API_TOKEN="$ARG_TOKEN"
[ -n "$ARG_PORT"  ] && export LOG_API_PORT="$ARG_PORT"
[ -n "$ARG_BIND"  ] && export LOG_API_BIND="$ARG_BIND"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 需要 root 权限,请使用 sudo 运行"
    exit 1
fi

WORK_DIR=/opt/remnanode
COMPOSE_FILE="$WORK_DIR/docker-compose.yml"
LOG_DIR="$WORK_DIR/logs"
LOG_API_SCRIPT="$WORK_DIR/log_api.py"
LOG_API_TOKEN_FILE="$WORK_DIR/log_api_token"

print_header() {
    echo ""
    echo -e "  ${BOLD}${WHITE}━━━ Remnawave Node 对接 ━━━${NC}"
    echo ""
}

# --------------------------------------------------------------------
# ① Docker 检测
# --------------------------------------------------------------------
check_docker() {
    echo -ne "  ${WHITE}检测 Docker ... ${NC}"
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        local ver
        ver=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
        echo -e "${GREEN}已安装${NC} ($ver)"
        return
    fi
    echo -e "${YELLOW}未安装,正在安装${NC}"
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker >/dev/null 2>&1
    systemctl start docker
    if command -v docker &>/dev/null; then
        echo -e "  ${GREEN}✓ Docker 安装完成${NC}"
    else
        echo -e "  ${RED}✗ Docker 安装失败,请手动安装${NC}"
        exit 1
    fi
}

# --------------------------------------------------------------------
# ② 从已有 docker-compose.yml 读取字段(如存在),用于二次运行的默认值
# --------------------------------------------------------------------
CUR_IMAGE=""
CUR_PORT=""
CUR_SECRET=""
CUR_LOG_API_ENABLED="false"
CUR_LOG_API_PORT=""
CUR_LOG_API_BIND=""

load_existing() {
    [ -f "$COMPOSE_FILE" ] || return

    CUR_IMAGE=$(grep -E '^\s*image:' "$COMPOSE_FILE" | head -1 \
                | sed -E 's/^\s*image:\s*//; s/^"//; s/"$//')
    CUR_PORT=$(grep -E '^\s*-\s*NODE_PORT=' "$COMPOSE_FILE" | head -1 \
               | sed -E 's/^\s*-\s*NODE_PORT=//; s/^"//; s/"$//')
    # SECRET_KEY 可能跨行或包含 = 号,用 awk 更稳
    CUR_SECRET=$(awk -F'SECRET_KEY=' '/SECRET_KEY=/{print $2; exit}' "$COMPOSE_FILE" \
                 | sed -E 's/^"//; s/"\s*$//')

    # 检测日志 API 边车
    if grep -qE '^\s*rmdj-logs:' "$COMPOSE_FILE"; then
        CUR_LOG_API_ENABLED="true"
        CUR_LOG_API_PORT=$(awk '/rmdj-logs:/,/^[[:space:]]*$/' "$COMPOSE_FILE" \
                          | grep -oE '"[0-9.]+:[0-9]+:[0-9]+"' | head -1 \
                          | sed -E 's/.*:([0-9]+):.*/\1/')
        CUR_LOG_API_BIND=$(awk '/rmdj-logs:/,/^[[:space:]]*$/' "$COMPOSE_FILE" \
                          | grep -oE '"[0-9.]+:[0-9]+:[0-9]+"' | head -1 \
                          | sed -E 's/.*"([0-9.]+):.*/\1/')
    fi
}

# --------------------------------------------------------------------
# ③ 读取字段(带默认值,回车沿用)
# --------------------------------------------------------------------
read_with_default() {
    # $1=提示文字 $2=当前值 $3=变量名
    local prompt="$1" cur="$2" var="$3" input=""
    if [ -n "$cur" ]; then
        local display="$cur"
        # SECRET 显示省略
        if [ ${#cur} -gt 60 ]; then
            display="${cur:0:40}...${cur: -10}  (长度 ${#cur})"
        fi
        echo -e "  ${DIM}当前: $display${NC}"
        echo -ne "  ${WHITE}${prompt}${NC} ${DIM}[回车沿用]${NC}: "
    else
        echo -ne "  ${WHITE}${prompt}${NC}: "
    fi
    read -r input
    if [ -z "$input" ] && [ -n "$cur" ]; then
        input="$cur"
    fi
    printf -v "$var" '%s' "$input"
}

# --------------------------------------------------------------------
# ④ 日志 API 相关辅助
# --------------------------------------------------------------------
ensure_log_api_token() {
    # 优先级:命令行/环境变量 LOG_API_TOKEN > 已有 token 文件 > 自动生成
    # 这样多个节点用同一个 token 时,把首台机生成的 token 通过 env 传入即可,无需手动同步文件
    local provided="${LOG_API_TOKEN:-}"

    if [ -n "$provided" ]; then
        # 用户提供了:校验长度后采用并写入持久化
        if [ ${#provided} -lt 16 ]; then
            echo -e "  ${RED}提供的 LOG_API_TOKEN 太短 (${#provided}),建议 ≥32 字符 hex${NC}"
            exit 1
        fi
        LOG_API_TOKEN="$provided"
        LOG_API_TOKEN_SOURCE="provided"
        echo "$LOG_API_TOKEN" > "$LOG_API_TOKEN_FILE"
        chmod 600 "$LOG_API_TOKEN_FILE"
    elif [ -s "$LOG_API_TOKEN_FILE" ]; then
        LOG_API_TOKEN=$(cat "$LOG_API_TOKEN_FILE")
        LOG_API_TOKEN_SOURCE="existing"
    else
        LOG_API_TOKEN=$(head -c 32 /dev/urandom | xxd -p -c 64 2>/dev/null \
                      || openssl rand -hex 32 2>/dev/null \
                      || date +%s%N | sha256sum | cut -c1-64)
        echo "$LOG_API_TOKEN" > "$LOG_API_TOKEN_FILE"
        chmod 600 "$LOG_API_TOKEN_FILE"
        LOG_API_TOKEN_SOURCE="generated"
    fi
}

# 把 log_api.py 写到 WORK_DIR (会被边车容器以只读挂载执行)
write_log_api_script() {
    cat > "$LOG_API_SCRIPT" <<'PYEOF'
#!/usr/bin/env python3
# rmdj 日志 API —— 单文件零依赖 (stdlib 即可)
# 解析 Xray access.log,通过 HTTP + Bearer Token 暴露:
#   GET /health                     无需鉴权,健康探针
#   GET /raw?tail=N&user=X          原始行 (过滤可选)
#   GET /stats                      Top 用户 / 目标 / 客户端 IP
#   GET /user/<email_or_uuid>       单用户最近访问 + Top 目标 + Top 源 IP
import os, json, re, time
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs, unquote

LOG_DIR    = os.environ.get('LOG_DIR', '/var/log/xray')
ACCESS_LOG = os.path.join(LOG_DIR, 'access.log')
TOKEN      = (os.environ.get('LOG_API_TOKEN', '') or '').strip()
PORT       = int(os.environ.get('PORT', '9091'))
MAX_TAIL   = 5000          # 单次最大返回行数,防 OOM
SCAN_BYTES = 16 * 1024 * 1024  # /raw 读尾部最多 16MB

# Xray access.log 标准格式:
#  2024/01/15 12:34:56 from 1.2.3.4:54321 accepted tcp:example.com:443 [INBOUND -> OUTBOUND] email: alice@host
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
    if not m:
        return None
    d = m.groupdict()
    src_ip = (d.get('src') or '').rsplit(':', 1)[0]
    return {
        'time': d.get('ts'),
        'src': d.get('src') or '',
        'srcIp': src_ip,
        'verdict': d.get('verdict') or '',
        'proto': d.get('proto') or '',
        'dst': d.get('dst') or '',
        'route': d.get('route') or '',
        'email': d.get('email') or '',
    }

def read_tail_lines(path, max_lines, max_bytes=SCAN_BYTES):
    """读取文件末尾若干行 (粗略,大文件先 seek)."""
    if not os.path.exists(path):
        return []
    try:
        size = os.path.getsize(path)
        with open(path, 'rb') as f:
            if size > max_bytes:
                f.seek(size - max_bytes)
                f.readline()  # 丢弃可能不完整的首行
            data = f.read()
        text = data.decode('utf-8', errors='replace')
        lines = text.splitlines()
        return lines[-max_lines:] if max_lines and len(lines) > max_lines else lines
    except Exception:
        return []

def iter_all_lines(path):
    """逐行遍历 (供 stats / user 查询全量)."""
    if not os.path.exists(path):
        return
    try:
        with open(path, 'r', errors='replace') as f:
            for line in f:
                yield line
    except Exception:
        return

def topk(d, k=20):
    return [{'name': name, 'count': cnt}
            for name, cnt in sorted(d.items(), key=lambda x: -x[1])[:k]]

class Handler(BaseHTTPRequestHandler):
    server_version = 'rmdj-logs/1.0'
    def log_message(self, *a, **k): pass  # 静音

    def _auth_ok(self):
        if not TOKEN: return True   # 没设 token 视为开放 (强烈建议设)
        h = self.headers.get('Authorization', '') or ''
        return h.strip() == 'Bearer ' + TOKEN

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
        self.wfile.write(b)

    def do_OPTIONS(self):
        self._send(204, '')

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query or '')

        # health 不鉴权
        if u.path == '/health':
            return self._send(200, {
                'ok': True,
                'logFile': ACCESS_LOG,
                'exists': os.path.exists(ACCESS_LOG),
                'size': os.path.getsize(ACCESS_LOG) if os.path.exists(ACCESS_LOG) else 0,
                'time': int(time.time()),
            })

        if not self._auth_ok():
            return self._send(401, {'error': 'unauthorized', 'hint': 'Authorization: Bearer <token>'})

        # 原始最近 N 行
        if u.path == '/raw':
            tail = max(1, min(MAX_TAIL, int((q.get('tail') or ['200'])[0] or 200)))
            user_q = (q.get('user') or [''])[0].strip().lower()
            verdict_q = (q.get('verdict') or [''])[0].strip().lower()
            lines = read_tail_lines(ACCESS_LOG, max_lines=tail * 4)  # 取 4 倍冗余,过滤后裁
            out = []
            for line in lines:
                p = parse_line(line)
                if not p: continue
                if user_q and user_q not in (p['email'] or '').lower(): continue
                if verdict_q and verdict_q != p['verdict']: continue
                out.append(p)
            out = out[-tail:]
            return self._send(200, {'lines': out, 'count': len(out)})

        # 总览统计 (会扫全文件,大文件慢)
        if u.path == '/stats':
            users, targets, ips, verdicts = {}, {}, {}, {'accepted': 0, 'rejected': 0}
            total = 0
            t0 = time.time()
            for line in iter_all_lines(ACCESS_LOG):
                p = parse_line(line)
                if not p: continue
                total += 1
                e = p['email'] or 'anonymous'
                users[e] = users.get(e, 0) + 1
                targets[p['dst']] = targets.get(p['dst'], 0) + 1
                if p['srcIp']: ips[p['srcIp']] = ips.get(p['srcIp'], 0) + 1
                if p['verdict'] in verdicts: verdicts[p['verdict']] += 1
            return self._send(200, {
                'totalLines': total,
                'verdicts': verdicts,
                'topUsers': topk(users),
                'topTargets': topk(targets),
                'topIps': topk(ips),
                'scanMs': int((time.time() - t0) * 1000),
            })

        # 单用户视图
        if u.path.startswith('/user/'):
            user = unquote(u.path[len('/user/'):]).strip().lower()
            if not user:
                return self._send(400, {'error': 'user required'})
            tail = max(1, min(MAX_TAIL, int((q.get('tail') or ['200'])[0] or 200)))
            recent, targets, srcs, verdicts = [], {}, {}, {'accepted': 0, 'rejected': 0}
            for line in iter_all_lines(ACCESS_LOG):
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

        self._send(404, {'error': 'not found',
                         'endpoints': ['/health', '/raw', '/stats', '/user/<id>']})

class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

if __name__ == '__main__':
    print('rmdj-logs listening on :%d  log=%s  token=%s' % (
        PORT, ACCESS_LOG, ('set' if TOKEN else 'NONE (开放访问,建议设)')
    ), flush=True)
    ThreadedHTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
PYEOF
    chmod 644 "$LOG_API_SCRIPT"
}

# --------------------------------------------------------------------
# ⑤ 询问是否启用日志 API
# --------------------------------------------------------------------
ask_log_api() {
    echo ""
    echo -e "  ${BOLD}${CYAN}━━━ 日志 API (可选) ━━━${NC}"
    echo -e "  ${DIM}启用后,面板通过 HTTP 拉取这台节点的访问日志:${NC}"
    echo -e "  ${DIM}  - 每个用户访问了哪些目标 / 域名 / IP${NC}"
    echo -e "  ${DIM}  - 客户端连接 IP 与连接数${NC}"
    echo -e "  ${DIM}  - Top 用户 / Top 目标 / Top 源 IP${NC}"
    echo -e "  ${DIM}前提:Xray 配置里要有 log.access = \"/var/log/xray/access.log\"${NC}"
    echo -e "  ${BOLD}${WHITE}多节点共享 token 提示:${NC}"
    echo -e "  ${DIM}  - 首台机直接跑,脚本自动生成 token${NC}"
    echo -e "  ${DIM}  - 后续机用:LOG_API_TOKEN=<那段 hex> bash <(curl ...)${NC}"
    echo -e "  ${DIM}  - 这样面板里只配一次,自动从 Remnawave 节点列表逐个拉${NC}"
    echo ""

    # 默认回答:命令行/环境提供过 token 时直接启用
    local default_answer="y"
    if [ "$CUR_LOG_API_ENABLED" = "true" ]; then
        echo -e "  ${DIM}当前已启用,端口 $CUR_LOG_API_PORT,绑定 $CUR_LOG_API_BIND${NC}"
    fi
    if [ -n "${LOG_API_TOKEN:-}" ]; then
        echo -e "  ${GREEN}检测到通过参数/环境变量传入 token,自动启用${NC}"
        ans="y"
    else
        echo -ne "  ${YELLOW}启用日志 API ? [Y/n]: ${NC}"
        read -r ans
        if [[ -z "$ans" ]]; then ans="$default_answer"; fi
    fi
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        LOG_API_ENABLED="false"
        return
    fi
    LOG_API_ENABLED="true"

    # 端口:优先用环境/命令行,其次已有,最后默认 9091
    local def_port="${LOG_API_PORT:-${CUR_LOG_API_PORT:-9091}}"
    if [ -n "${ARG_PORT:-}${LOG_API_PORT:-}" ] && [[ "$def_port" =~ ^[0-9]+$ ]]; then
        # 已通过参数提供且合法,跳过交互
        LOG_API_PORT="$def_port"
        echo -e "  ${DIM}日志 API 端口: ${WHITE}$LOG_API_PORT${NC} (来自参数)"
    else
        while true; do
            read_with_default "日志 API 端口" "$def_port" LOG_API_PORT
            if [[ "$LOG_API_PORT" =~ ^[0-9]+$ ]] && [ "$LOG_API_PORT" -ge 1 ] && [ "$LOG_API_PORT" -le 65535 ]; then
                break
            fi
            echo -e "  ${RED}端口必须是 1-65535${NC}"
        done
    fi

    # 绑定地址
    local def_bind="${LOG_API_BIND:-${CUR_LOG_API_BIND:-0.0.0.0}}"
    if [ -n "${ARG_BIND:-}${LOG_API_BIND:-}" ]; then
        LOG_API_BIND="$def_bind"
        echo -e "  ${DIM}绑定地址: ${WHITE}$LOG_API_BIND${NC} (来自参数)"
    else
        echo -e "  ${DIM}绑定地址:0.0.0.0=面板远程可拉 / 127.0.0.1=只能本机调用${NC}"
        read_with_default "绑定地址" "$def_bind" LOG_API_BIND
        if [ -z "$LOG_API_BIND" ]; then LOG_API_BIND="0.0.0.0"; fi
    fi

    ensure_log_api_token
    write_log_api_script
}

# --------------------------------------------------------------------
# ⑥ 写出 docker-compose.yml
# --------------------------------------------------------------------
write_compose() {
    local img="$1" port="$2" secret="$3"

    # 已有文件先备份
    if [ -f "$COMPOSE_FILE" ]; then
        cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak.$(date +%s)"
    fi

    mkdir -p "$LOG_DIR"

    cat > "$COMPOSE_FILE" <<EOF
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

    if [ "$LOG_API_ENABLED" = "true" ]; then
        cat >> "$COMPOSE_FILE" <<EOF

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
    fi
}

# --------------------------------------------------------------------
# ⑦ 启动容器
# --------------------------------------------------------------------
start_container() {
    cd "$WORK_DIR" || exit 1
    echo ""
    echo -e "  ${CYAN}拉取镜像并启动...${NC}"
    echo ""
    docker compose up -d
    echo ""
    sleep 2

    local status
    status=$(docker ps --filter "name=remnanode" --format '{{.Names}}  {{.Status}}' 2>/dev/null)
    if [ -n "$status" ]; then
        echo -e "  ${GREEN}${BOLD}✓ remnanode 启动成功${NC}"
        echo -e "  ${WHITE}$status${NC}"
    else
        echo -e "  ${RED}✗ remnanode 启动异常,最近日志:${NC}"
        docker compose logs --tail 20 remnanode
        return 1
    fi

    if [ "$LOG_API_ENABLED" = "true" ]; then
        local log_status
        log_status=$(docker ps --filter "name=rmdj-logs" --format '{{.Names}}  {{.Status}}' 2>/dev/null)
        if [ -n "$log_status" ]; then
            echo -e "  ${GREEN}${BOLD}✓ rmdj-logs 启动成功${NC}"
            echo -e "  ${WHITE}$log_status${NC}"
        else
            echo -e "  ${RED}✗ rmdj-logs 启动异常,最近日志:${NC}"
            docker compose logs --tail 20 rmdj-logs
        fi
    fi
}

# --------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------
print_header
check_docker

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo ""
if [ -f "$COMPOSE_FILE" ] && [ -s "$COMPOSE_FILE" ]; then
    echo -e "  ${YELLOW}检测到现有配置:${NC} $COMPOSE_FILE"
    echo -e "  ${DIM}回车沿用现有值,输入新值则替换${NC}"
else
    echo -e "  ${WHITE}首次部署,请依次填入以下参数${NC}"
    echo -e "  ${DIM}参数可从面板 Nodes → 添加节点 页面复制${NC}"
fi
echo ""

load_existing

# 镜像 (默认 remnawave/node:latest)
[ -z "$CUR_IMAGE" ] && CUR_IMAGE="remnawave/node:latest"
read_with_default "镜像 image" "$CUR_IMAGE" IMG

# 端口
while true; do
    read_with_default "NODE_PORT (节点监听端口,例 2222)" "$CUR_PORT" PORT
    if [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ]; then
        break
    fi
    echo -e "  ${RED}端口必须是 1-65535 的整数${NC}"
done

# SECRET_KEY
while true; do
    echo ""
    if [ -n "$CUR_SECRET" ]; then
        echo -e "  ${WHITE}SECRET_KEY${NC} ${DIM}(当前长度 ${#CUR_SECRET},回车沿用)${NC}"
        echo -ne "  新 SECRET_KEY (不改留空): "
    else
        echo -e "  ${WHITE}SECRET_KEY${NC} ${DIM}(从面板复制,一长串 base64)${NC}"
        echo -ne "  SECRET_KEY: "
    fi
    read -r INPUT
    if [ -z "$INPUT" ] && [ -n "$CUR_SECRET" ]; then
        SECRET="$CUR_SECRET"
        break
    fi
    # 去掉可能粘进来的前后引号
    INPUT="${INPUT#\"}"
    INPUT="${INPUT%\"}"
    if [ -n "$INPUT" ] && [ ${#INPUT} -ge 50 ]; then
        SECRET="$INPUT"
        break
    fi
    echo -e "  ${RED}SECRET_KEY 长度不对,应该是一长串字符 (通常 >500 字符)${NC}"
done

# 询问日志 API
LOG_API_ENABLED="false"
LOG_API_PORT=""
LOG_API_BIND=""
LOG_API_TOKEN=""
ask_log_api

# 写配置
echo ""
write_compose "$IMG" "$PORT" "$SECRET"
echo -e "  ${GREEN}✓${NC} 配置已写入: $COMPOSE_FILE"
if [ "$LOG_API_ENABLED" = "true" ]; then
    echo -e "  ${GREEN}✓${NC} 日志 API 脚本: $LOG_API_SCRIPT"
    echo -e "  ${GREEN}✓${NC} 日志目录:     $LOG_DIR"
fi
echo ""

# 展示关键字段
echo -e "  ${BOLD}${CYAN}━━━ 配置摘要 ━━━${NC}"
echo -e "    image:       ${WHITE}$IMG${NC}"
echo -e "    NODE_PORT:   ${WHITE}$PORT${NC}"
echo -e "    SECRET_KEY:  ${WHITE}${SECRET:0:40}...${SECRET: -10}${NC} ${DIM}(长度 ${#SECRET})${NC}"
if [ "$LOG_API_ENABLED" = "true" ]; then
    PUBLIC_IP=$(curl -fs --max-time 4 https://api.ipify.org 2>/dev/null \
              || curl -fs --max-time 4 https://ifconfig.me 2>/dev/null \
              || hostname -I 2>/dev/null | awk '{print $1}')
    echo ""
    echo -e "    ${BOLD}${CYAN}日志 API:${NC}"
    echo -e "      端口:     ${WHITE}$LOG_API_PORT${NC}"
    echo -e "      绑定:     ${WHITE}$LOG_API_BIND${NC}"
    echo -e "      URL:      ${WHITE}http://${PUBLIC_IP:-<本机IP>}:$LOG_API_PORT${NC}"
    echo -e "      Token:    ${WHITE}$LOG_API_TOKEN${NC} ${DIM}(${LOG_API_TOKEN_SOURCE:-?})${NC}"
    echo ""
    if [ "${LOG_API_TOKEN_SOURCE:-}" = "generated" ]; then
        echo -e "    ${BOLD}${YELLOW}★ 这是首台节点,Token 已自动生成。后续节点请用同一个 token:${NC}"
        echo -e "      ${WHITE}LOG_API_TOKEN=$LOG_API_TOKEN bash <(curl -s -L .../rmdj.sh)${NC}"
        echo ""
    elif [ "${LOG_API_TOKEN_SOURCE:-}" = "provided" ]; then
        echo -e "    ${GREEN}✓ 使用了参数/环境变量传入的共享 Token${NC}"
        echo ""
    fi
    echo -e "    ${YELLOW}面板对接:${NC}"
    echo -e "      ${WHITE}1.${NC} 面板里 ${BOLD}只配一次${NC}:端口=${WHITE}$LOG_API_PORT${NC}  Token=${WHITE}$LOG_API_TOKEN${NC}"
    echo -e "      ${WHITE}2.${NC} 面板会自动从 Remnawave ${WHITE}/api/nodes${NC} 读节点 IP,逐个拉日志"
    echo -e "      ${WHITE}3.${NC} 节点 IP/域名以面板里的 Node.address 为准 (本机 ${PUBLIC_IP:-?} 是否一致?)"
    echo ""
    echo -e "    ${YELLOW}必要步骤:${NC} 在面板生成 Xray 配置时务必加上"
    echo -e "      ${DIM}\"log\": { \"access\": \"/var/log/xray/access.log\", \"loglevel\": \"warning\" }${NC}"
    echo -e "      ${DIM}否则节点不会写日志,这个 API 永远是空的${NC}"
fi
echo -e "  ${BOLD}${CYAN}━━━━━━━━━━━━━━━━${NC}"
echo ""

# 询问是否启动
echo -ne "  ${YELLOW}是否启动容器? (docker compose up -d) [Y/n]: ${NC}"
read -r answer
if [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]; then
    start_container
else
    echo -e "  ${WHITE}已跳过。手动启动: cd $WORK_DIR && docker compose up -d${NC}"
fi

# 自检日志 API
if [ "$LOG_API_ENABLED" = "true" ]; then
    sleep 1
    echo ""
    echo -ne "  ${WHITE}自检日志 API ... ${NC}"
    if curl -fs --max-time 3 "http://127.0.0.1:$LOG_API_PORT/health" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ 通${NC}"
    else
        echo -e "${YELLOW}暂时不通,稍等几秒再用${NC}"
        echo -e "  ${DIM}排查: docker logs rmdj-logs --tail 20${NC}"
    fi
fi

echo ""
echo -e "  ${DIM}再次运行 $0 可修改配置(已有字段会自动填充为默认值)${NC}"
if [ "$LOG_API_ENABLED" = "true" ]; then
    echo -e "  ${DIM}日志 Token 保存在: $LOG_API_TOKEN_FILE  (需要时直接 cat 它)${NC}"
fi
echo ""
