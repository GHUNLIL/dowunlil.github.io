#!/bin/bash
# Remnawave Node 对接脚本 (分字段交互式版)
# 依次输入 image / NODE_PORT / SECRET_KEY,脚本生成干净的 docker-compose.yml
# 再次运行会读取已有配置,支持修改单个字段或直接沿用

set -uo pipefail

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

load_existing() {
    [ -f "$COMPOSE_FILE" ] || return

    CUR_IMAGE=$(grep -E '^\s*image:' "$COMPOSE_FILE" | head -1 \
                | sed -E 's/^\s*image:\s*//; s/^"//; s/"$//')
    CUR_PORT=$(grep -E '^\s*-\s*NODE_PORT=' "$COMPOSE_FILE" | head -1 \
               | sed -E 's/^\s*-\s*NODE_PORT=//; s/^"//; s/"$//')
    # SECRET_KEY 可能跨行或包含 = 号,用 awk 更稳
    CUR_SECRET=$(awk -F'SECRET_KEY=' '/SECRET_KEY=/{print $2; exit}' "$COMPOSE_FILE" \
                 | sed -E 's/^"//; s/"\s*$//')
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
# ④ 写出 docker-compose.yml
# --------------------------------------------------------------------
write_compose() {
    local img="$1" port="$2" secret="$3"

    # 已有文件先备份
    if [ -f "$COMPOSE_FILE" ]; then
        cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak.$(date +%s)"
    fi

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
EOF
}

# --------------------------------------------------------------------
# ⑤ 启动容器
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
        echo -e "  ${GREEN}${BOLD}✓ 启动成功${NC}"
        echo -e "  ${WHITE}$status${NC}"
    else
        echo -e "  ${RED}✗ 启动异常,最近日志:${NC}"
        docker compose logs --tail 20
        return 1
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

# 写配置
echo ""
write_compose "$IMG" "$PORT" "$SECRET"
echo -e "  ${GREEN}✓${NC} 配置已写入: $COMPOSE_FILE"
echo ""

# 展示关键字段
echo -e "  ${BOLD}${CYAN}━━━ 配置摘要 ━━━${NC}"
echo -e "    image:       ${WHITE}$IMG${NC}"
echo -e "    NODE_PORT:   ${WHITE}$PORT${NC}"
echo -e "    SECRET_KEY:  ${WHITE}${SECRET:0:40}...${SECRET: -10}${NC} ${DIM}(长度 ${#SECRET})${NC}"
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

echo ""
echo -e "  ${DIM}再次运行 $0 可修改配置(已有字段会自动填充为默认值)${NC}"
echo ""
