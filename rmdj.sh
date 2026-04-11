#!/bin/bash
# Remnawave Node 对接脚本

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 需要root权限，请使用 sudo 运行"
    exit 1
fi

echo ""
echo -e "  ${BOLD}${WHITE}━━━ Remnawave Node 对接 ━━━${NC}"
echo ""

# ① 检测 Docker
echo -ne "  ${WHITE}检测 Docker ... ${NC}"
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    echo -e "${GREEN}已安装${NC} ($(docker --version | grep -oP '\d+\.\d+\.\d+'))"
else
    echo -e "${YELLOW}未安装，正在安装${NC}"
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker && systemctl start docker
    if command -v docker &>/dev/null; then
        echo -e "  ${GREEN}✓ Docker 安装完成${NC}"
    else
        echo -e "  ${RED}✗ Docker 安装失败，请手动安装${NC}"
        exit 1
    fi
fi

echo ""

# ② 创建目录和文件
mkdir -p /opt/remnanode
cd /opt/remnanode
touch docker-compose.yml
echo -e "  ${GREEN}✓${NC} 目录就绪: /opt/remnanode"
echo ""

# ③ 打开编辑器
echo -e "  ${CYAN}${BOLD}请在编辑器中粘贴 docker-compose.yml 配置${NC}"
echo -e "  ${WHITE}从面板 Nodes → 添加节点 → Copy docker-compose.yml 复制${NC}"
echo ""
echo -e "  ${YELLOW}保存退出: Ctrl+O 回车 → Ctrl+X${NC}"
echo ""
echo -ne "  按回车打开编辑器..."
read -r

nano /opt/remnanode/docker-compose.yml

# ④ 展示保存的内容
echo ""
echo -e "  ${BOLD}${CYAN}━━━ 已保存的配置 ━━━${NC}"
echo ""

if [ ! -s /opt/remnanode/docker-compose.yml ]; then
    echo -e "  ${RED}文件为空，请重新运行脚本${NC}"
    exit 1
fi

sed 's/^/  /' /opt/remnanode/docker-compose.yml

echo ""
echo -e "  ${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ⑤ 询问是否运行
echo -ne "  ${YELLOW}是否启动容器? (docker compose up -d) [y/N]: ${NC}"
read -r answer

if [[ "$answer" =~ ^[Yy]$ ]]; then
    echo ""
    cd /opt/remnanode
    docker compose up -d
    echo ""
    sleep 2
    status=$(docker ps --filter "name=remnanode" --format '{{.Names}}  {{.Status}}' 2>/dev/null)
    if [ -n "$status" ]; then
        echo -e "  ${GREEN}${BOLD}✓ 启动成功${NC}"
        echo -e "  ${WHITE}$status${NC}"
    else
        echo -e "  ${RED}启动异常，查看日志:${NC}"
        docker compose logs --tail 10
    fi
else
    echo -e "  ${WHITE}已跳过，手动启动: cd /opt/remnanode && docker compose up -d${NC}"
fi

echo ""