#!/bin/bash
# ============================================================
# 腾讯云监控与安全组件一键彻底卸载脚本（全自动执行两遍）
# ============================================================

set -e

YELLOW="\033[33m"
GREEN="\033[32m"
NC="\033[0m"

run_uninstall() {
  echo -e "${YELLOW}正在卸载腾讯云相关组件...${NC}"

  # 卸载 TAT Agent
  sudo wget -qO - https://tat-1258344699.cos.accelerate.myqcloud.com/tat_agent/uninstall.sh | sudo sh || true

  # 卸载 云镜
  if [ -w "/usr" ]; then
      /usr/local/qcloud/YunJing/uninst.sh || true
  else
      /var/lib/qcloud/YunJing/uninst.sh || true
  fi

  # 停止 Stargate 与 Barad
  if [ -d "/usr/local/qcloud/stargate/admin" ]; then
      cd /usr/local/qcloud/stargate/admin && ./stop.sh || true
  fi

  if [ -d "/usr/local/qcloud/monitor/barad/admin" ]; then
      cd /usr/local/qcloud/monitor/barad/admin && ./stop.sh || true
  fi

  # 卸载 Barad 与 Stargate
  if [ -d "/usr/local/qcloud/monitor/barad/admin" ]; then
      cd /usr/local/qcloud/monitor/barad/admin && ./uninstall.sh || true
  fi

  if [ -d "/usr/local/qcloud/stargate/admin" ]; then
      cd /usr/local/qcloud/stargate/admin && ./uninstall.sh || true
  fi

  # 删除计划任务文件
  rm -f /etc/cron.d/sgagenttask || true

  echo -e "${GREEN}本轮卸载完成。${NC}"
}

# ==================== 主程序 ====================

run_uninstall
echo -e "${YELLOW}再次执行以确保完全卸载...${NC}"
run_uninstall

# 自动清空当前用户的 crontab
echo -e "${YELLOW}正在清空当前用户的所有定时任务...${NC}"
crontab -r 2>/dev/null || true

echo -e "${GREEN}所有任务已清空，腾讯云组件卸载完毕！${NC}"
echo -e "${YELLOW}建议重启服务器以确保彻底生效。${NC}"
