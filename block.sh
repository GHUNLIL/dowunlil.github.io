#!/bin/bash
# =============================================================================
# 3x-ui 网站屏蔽管理 TUI
# =============================================================================

set -uo pipefail

# ---------- 颜色 ----------
R=$'\e[0;31m'; G=$'\e[0;32m'; Y=$'\e[1;33m'; B=$'\e[0;34m'; C=$'\e[0;36m'
D=$'\e[2m'; BOLD=$'\e[1m'; N=$'\e[0m'
err() { printf '%s[ERR]%s %s\n' "$R" "$N" "$*" >&2; }

# ---------- 前置 ----------
[[ $EUID -eq 0 ]] || { err "请以 root 运行"; exit 1; }
DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
[[ -f "$DB" ]] || { err "未找到 3x-ui 数据库: $DB"; exit 1; }

for pkg in jq sqlite3; do
    command -v "$pkg" >/dev/null 2>&1 || {
        echo "安装 $pkg ..."
        apt-get update -qq && apt-get install -y -qq "$pkg" >/dev/null
    }
done

# ---------- 状态 ----------
BLACKHOLE_TAG="blocked"
CUSTOM_TAG="custom-block"
DIRTY=0
LAST_ACTION=""
LAST_ERROR=""

# 默认模板 — 用户库里没有这条记录时的起点
DEFAULT_TPL='{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"blocked","protocol":"blackhole"}],"routing":{"domainStrategy":"IPIfNonMatch","rules":[]}}'

# ---------- 分类定义 ----------
CATS=(speedtest ipcheck ads adult social tiktok streaming ai gambling crypto)

cat_name() {
    case "$1" in
        speedtest) echo "测速网站     Speedtest / Fast / Cloudflare" ;;
        ipcheck)   echo "IP 纯净度    ping0.cc / scamalytics / ipinfo 等" ;;
        ads)       echo "广告追踪     DoubleClick / Google Ads 等" ;;
        adult)     echo "成人内容     Pornhub / OnlyFans 等" ;;
        social)    echo "社交媒体     FB / X / IG / Reddit 等" ;;
        tiktok)    echo "TikTok       TikTok / ByteDance 全家桶" ;;
        streaming) echo "流媒体       Netflix / YouTube / Twitch" ;;
        ai)        echo "AI 工具      OpenAI / Claude / Gemini" ;;
        gambling)  echo "博彩赌博     Bet365 / PokerStars 等" ;;
        crypto)    echo "加密货币     Binance / Coinbase 等" ;;
    esac
}

cat_domains() {
    # 尽量使用 geosite: 标签(Xray 从 geosite.dat 里加载),社区维护,无需手动更新。
    # 对 geosite 没收录的类别,用 domain: 硬编码补充。
    # 所有 geosite 名称均已按 v2fly/domain-list-community 实测校对过。
    case "$1" in
        speedtest) printf '%s\n' \
            geosite:category-speedtest \
            domain:speed.cloudflare.com domain:speed.miwifi.com \
            domain:bandwidthplace.com domain:speedsmart.net domain:nperf.com \
            domain:measurementlab.net domain:librespeed.org
            ;;
        ipcheck) printf '%s\n' \
            domain:ping0.cc domain:ip.sb domain:ip.cn domain:iplark.com \
            domain:ipinfo.io domain:ipapi.co domain:ip-api.com \
            domain:scamalytics.com domain:ipqualityscore.com domain:spur.us \
            domain:ipquality.com domain:criminalip.io domain:fraudguard.io \
            domain:proxycheck.io domain:getipintel.net domain:ipfighter.com \
            domain:abuseipdb.com domain:ipleak.net domain:browserleaks.com \
            domain:whoer.net domain:whoer.com domain:2ip.ru \
            domain:check-host.net domain:ipx.ac domain:showmyip.com \
            domain:bgp.he.net domain:bgp.tools domain:bgpview.io domain:ipverse.net \
            domain:whatismyipaddress.com domain:myip.com domain:myip.ms \
            domain:iplocation.net domain:ipgeolocation.io domain:ip2location.com \
            domain:maxmind.com domain:db-ip.com
            ;;
        ads) printf '%s\n' \
            geosite:category-ads-all
            ;;
        adult) printf '%s\n' \
            geosite:category-porn
            ;;
        social) printf '%s\n' \
            geosite:facebook geosite:twitter geosite:instagram \
            geosite:reddit geosite:linkedin geosite:pinterest \
            geosite:snap geosite:tumblr
            ;;
        tiktok) printf '%s\n' \
            geosite:tiktok geosite:bytedance
            ;;
        streaming) printf '%s\n' \
            geosite:netflix geosite:youtube geosite:disney \
            geosite:hbo geosite:hulu geosite:spotify \
            geosite:twitch geosite:primevideo \
            geosite:bilibili geosite:iqiyi geosite:youku
            ;;
        ai) printf '%s\n' \
            geosite:openai geosite:anthropic geosite:google-gemini \
            geosite:perplexity geosite:category-ai-chat-!cn \
            domain:copilot.microsoft.com domain:copilot.cloud.microsoft
            ;;
        gambling) printf '%s\n' \
            domain:bet365.com domain:pokerstars.com domain:888casino.com \
            domain:williamhill.com domain:paddypower.com domain:ladbrokes.com \
            domain:bwin.com domain:betfair.com domain:unibet.com domain:betway.com \
            domain:draftkings.com domain:fanduel.com domain:sbobet.com \
            domain:stake.com domain:rollbit.com domain:bc.game
            ;;
        crypto) printf '%s\n' \
            geosite:category-cryptocurrency
            ;;
    esac
}

# ---------- 数据库读写 ----------
# 关键: 必须用 INSERT OR REPLACE。3x-ui 的默认模板是 Go 编译时嵌入的,
# 用户从未手动保存过时 settings 表里没有 xrayTemplateConfig 这一行,
# 用 UPDATE 会影响 0 行但不报错。

db_read() {
    # 返回数据库里的模板,没有则返回 DEFAULT_TPL
    local v
    v=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null)
    if [[ -z "$v" ]]; then
        echo "$DEFAULT_TPL"
    else
        echo "$v"
    fi
}

db_write() {
    # 参数:$1 = 新的完整 JSON。写入失败返回非 0。
    local new="$1"

    # 先验证 JSON 合法
    if ! echo "$new" | jq empty >/dev/null 2>&1; then
        LAST_ERROR="要写入的内容不是合法 JSON"
        return 1
    fi

    # 用临时文件 + readfile() 避免参数转义问题
    local f
    f=$(mktemp) || { LAST_ERROR="mktemp 失败"; return 1; }
    printf '%s' "$new" > "$f"

    local out
    out=$(sqlite3 "$DB" <<SQL 2>&1
BEGIN;
DELETE FROM settings WHERE key='xrayTemplateConfig';
INSERT INTO settings(key, value) VALUES('xrayTemplateConfig', readfile('$f'));
COMMIT;
SQL
)
    local rc=$?
    rm -f "$f"

    if [[ $rc -ne 0 ]]; then
        LAST_ERROR="sqlite3 写入失败: $out"
        return 1
    fi

    # 写后校验 — 读回后用 jq 规范化对比(避开换行差异)
    local back a_norm b_norm
    back=$(sqlite3 "$DB" "SELECT value FROM settings WHERE key='xrayTemplateConfig';" 2>/dev/null)
    a_norm=$(echo "$new"  | jq -cS . 2>/dev/null)
    b_norm=$(echo "$back" | jq -cS . 2>/dev/null)
    if [[ -z "$b_norm" ]]; then
        LAST_ERROR="读回内容不是合法 JSON"
        return 1
    fi
    if [[ "$a_norm" != "$b_norm" ]]; then
        LAST_ERROR="写入后读回内容与预期不一致"
        return 1
    fi
    return 0
}

# ---------- 核心操作 ----------
is_enabled() {
    # 参数:$1 = 分类名
    local tag="preset-$1"
    local tpl; tpl=$(db_read)
    echo "$tpl" | jq -e --arg t "$tag" \
        '(.routing.rules // []) | any(.tag == $t)' >/dev/null 2>&1
}

enable_preset() {
    local cat="$1" tag="preset-$1"
    local tpl; tpl=$(db_read)

    # 用 jq 加入 blackhole outbound(如果没有)+ 加入规则(先删旧的再加新的)
    local domains_json; domains_json=$(cat_domains "$cat" | jq -R . | jq -s .)
    local new
    new=$(echo "$tpl" | jq \
        --arg bh "$BLACKHOLE_TAG" \
        --arg t "$tag" \
        --argjson d "$domains_json" '
        (if ((.outbounds // []) | any(.tag == $bh)) then .
         else .outbounds = ((.outbounds // []) + [{tag:$bh, protocol:"blackhole"}]) end)
        | .routing = (.routing // {})
        | .routing.rules = (.routing.rules // [])
        | .routing.rules = ((.routing.rules | map(select(.tag != $t))))
        | .routing.rules = ([{type:"field", tag:$t, outboundTag:$bh, domain:$d}] + .routing.rules)
    ') || { LAST_ERROR="jq 处理失败"; return 1; }

    db_write "$new"
}

disable_preset() {
    local cat="$1" tag="preset-$1"
    local tpl; tpl=$(db_read)
    local new
    new=$(echo "$tpl" | jq --arg t "$tag" '
        .routing = (.routing // {})
        | .routing.rules = ((.routing.rules // []) | map(select(.tag != $t)))
    ') || { LAST_ERROR="jq 处理失败"; return 1; }
    db_write "$new"
}

get_custom_list() {
    local tpl; tpl=$(db_read)
    echo "$tpl" | jq -r --arg t "$CUSTOM_TAG" '
        (.routing.rules // []) | map(select(.tag == $t)) | .[0].domain // [] | .[]
    ' 2>/dev/null
}

set_custom_list() {
    # 参数:$1 = 换行分隔的域名字符串(可为空表示清空)
    local raw="$1"
    local tpl; tpl=$(db_read)

    local list_json
    if [[ -z "$raw" ]]; then
        list_json="[]"
    else
        list_json=$(printf '%s\n' "$raw" | sed '/^$/d' | jq -R . | jq -s .)
    fi

    local new
    new=$(echo "$tpl" | jq --arg t "$CUSTOM_TAG" --arg bh "$BLACKHOLE_TAG" --argjson d "$list_json" '
        (if ((.outbounds // []) | any(.tag == $bh)) then .
         else .outbounds = ((.outbounds // []) + [{tag:$bh, protocol:"blackhole"}]) end)
        | .routing = (.routing // {})
        | .routing.rules = (.routing.rules // [])
        | .routing.rules = ((.routing.rules | map(select(.tag != $t))))
        | (if ($d | length) > 0
           then .routing.rules = ([{type:"field", tag:$t, outboundTag:$bh, domain:$d}] + .routing.rules)
           else . end)
    ') || { LAST_ERROR="jq 处理失败"; return 1; }

    db_write "$new"
}

restart_xui() {
    systemctl restart x-ui 2>/dev/null
    sleep 1.5
    systemctl is-active --quiet x-ui
}

# =============================================================================
# 落地节点 (landing outbound) 管理
# 脚本管理的 outbound tag 统一用 "land-<name>" 前缀,避免和 3x-ui 面板里
# 手动添加的 outbound 冲突
# =============================================================================

LAND_PREFIX="land-"
ROUTE_PREFIX="route-"

# 列出所有脚本管理的落地节点
# 输出格式: tag|protocol|address|port|user
list_landings() {
    local tpl; tpl=$(db_read)
    echo "$tpl" | jq -r --arg p "$LAND_PREFIX" '
        (.outbounds // []) | map(select(.tag | startswith($p))) |
        .[] |
        [
            .tag,
            .protocol,
            (.settings.servers[0].address // .settings.address // ""),
            ((.settings.servers[0].port // .settings.port // "") | tostring),
            (.settings.servers[0].users[0].user // .settings.servers[0].users[0].username // "")
        ] | join("|")
    ' 2>/dev/null
}

# 添加一个落地节点
# 参数: $1=tag_name $2=protocol(socks/http) $3=address $4=port $5=user(可空) $6=pass(可空)
add_landing() {
    local name="$1" proto="$2" addr="$3" port="$4" user="${5:-}" pass="${6:-}"
    local full_tag="${LAND_PREFIX}${name}"

    # 构造 settings
    local settings_json
    if [[ "$proto" == "socks" ]]; then
        if [[ -n "$user" ]]; then
            settings_json=$(jq -n \
                --arg a "$addr" --argjson p "$port" --arg u "$user" --arg pw "$pass" \
                '{servers: [{address: $a, port: $p, users: [{user: $u, pass: $pw}]}]}')
        else
            settings_json=$(jq -n \
                --arg a "$addr" --argjson p "$port" \
                '{servers: [{address: $a, port: $p}]}')
        fi
    elif [[ "$proto" == "http" ]]; then
        if [[ -n "$user" ]]; then
            settings_json=$(jq -n \
                --arg a "$addr" --argjson p "$port" --arg u "$user" --arg pw "$pass" \
                '{servers: [{address: $a, port: $p, users: [{user: $u, pass: $pw}]}]}')
        else
            settings_json=$(jq -n \
                --arg a "$addr" --argjson p "$port" \
                '{servers: [{address: $a, port: $p}]}')
        fi
    else
        LAST_ERROR="不支持的协议: $proto"
        return 1
    fi

    local tpl; tpl=$(db_read)
    local new
    new=$(echo "$tpl" | jq \
        --arg tag "$full_tag" \
        --arg proto "$proto" \
        --argjson settings "$settings_json" '
        .outbounds = (.outbounds // [])
        | .outbounds = (.outbounds | map(select(.tag != $tag)))
        | .outbounds = (.outbounds + [{tag: $tag, protocol: $proto, settings: $settings}])
    ') || { LAST_ERROR="jq 失败"; return 1; }

    db_write "$new"
}

# 删除落地节点
# 同时删除所有引用它的路由规则
del_landing() {
    local full_tag="$1"
    local tpl; tpl=$(db_read)
    local new
    new=$(echo "$tpl" | jq --arg tag "$full_tag" '
        .outbounds = ((.outbounds // []) | map(select(.tag != $tag)))
        | .routing = (.routing // {})
        | .routing.rules = ((.routing.rules // []) | map(select(.outboundTag != $tag)))
    ') || { LAST_ERROR="jq 失败"; return 1; }
    db_write "$new"
}

# 列出所有路由规则 (tag 以 route- 开头的)
# 输出格式: rule_tag|outbound_tag|domain_count
list_routes() {
    local tpl; tpl=$(db_read)
    echo "$tpl" | jq -r --arg p "$ROUTE_PREFIX" '
        (.routing.rules // []) | map(select(.tag | startswith($p))) |
        .[] |
        [.tag, .outboundTag, ((.domain // []) | length | tostring)] | join("|")
    ' 2>/dev/null
}

# 获取路由规则的域名列表
get_route_domains() {
    local rule_tag="$1"
    local tpl; tpl=$(db_read)
    echo "$tpl" | jq -r --arg t "$rule_tag" '
        (.routing.rules // []) | map(select(.tag == $t)) |
        .[0].domain // [] | .[]
    ' 2>/dev/null
}

# 添加或更新一条路由规则
# 参数: $1=rule_name $2=outbound_tag(完整的 land-xxx) $3=换行分隔的域名列表
set_route() {
    local name="$1" out_tag="$2" domains="$3"
    local full_tag="${ROUTE_PREFIX}${name}"

    local list_json
    if [[ -z "$domains" ]]; then
        list_json="[]"
    else
        list_json=$(printf '%s\n' "$domains" | sed '/^$/d' | jq -R . | jq -s .)
    fi

    local tpl; tpl=$(db_read)
    local new
    new=$(echo "$tpl" | jq \
        --arg rt "$full_tag" \
        --arg ot "$out_tag" \
        --argjson d "$list_json" '
        .routing = (.routing // {})
        | .routing.rules = (.routing.rules // [])
        | .routing.rules = ((.routing.rules | map(select(.tag != $rt))))
        | (if ($d | length) > 0
           then .routing.rules = ([{type:"field", tag:$rt, outboundTag:$ot, domain:$d}] + .routing.rules)
           else . end)
    ') || { LAST_ERROR="jq 失败"; return 1; }

    db_write "$new"
}

# 删除路由规则
del_route() {
    local full_tag="$1"
    local tpl; tpl=$(db_read)
    local new
    new=$(echo "$tpl" | jq --arg t "$full_tag" '
        .routing = (.routing // {})
        | .routing.rules = ((.routing.rules // []) | map(select(.tag != $t)))
    ') || { LAST_ERROR="jq 失败"; return 1; }
    db_write "$new"
}

# ---------- TUI 底层 ----------
KEY=""
read_key() {
    local k extra
    IFS= read -rsn1 k </dev/tty 2>/dev/null || { KEY="q"; return; }
    if [[ -z "$k" ]]; then KEY=$'\n'; return; fi
    if [[ "$k" == $'\e' ]]; then
        IFS= read -rsn2 -t 0.1 extra </dev/tty 2>/dev/null || extra=""
        KEY="${k}${extra}"
    else
        KEY="$k"
    fi
}

draw_main() {
    local sel=$1
    clear
    printf '%s╔═══════════════════════════════════════════════════════╗%s\n' "$B" "$N"
    printf '%s║%s  3x-ui 网站屏蔽管理%s%s                                   ║%s\n' "$B" "$BOLD" "$N" "$B" "$N"
    printf '%s╚═══════════════════════════════════════════════════════╝%s\n' "$B" "$N"

    local status=""
    if [[ $DIRTY -gt 0 ]]; then
        status="${Y}⚠ 有 $DIRTY 项改动未应用${N}"
    fi
    if [[ -n "$LAST_ACTION" ]]; then
        [[ -n "$status" ]] && status="$status   "
        status="${status}${G}✓ $LAST_ACTION${N}"
    fi
    if [[ -n "$LAST_ERROR" ]]; then
        [[ -n "$status" ]] && status="$status   "
        status="${status}${R}✗ $LAST_ERROR${N}"
    fi
    [[ -n "$status" ]] && printf '  %s\n' "$status"
    LAST_ACTION=""
    LAST_ERROR=""

    echo
    printf '%s  ↑↓/jk 移动   Space/Enter 切换   a 应用   q 退出%s\n' "$D" "$N"
    echo

    local i=0 cat mark name
    for cat in "${CATS[@]}"; do
        if is_enabled "$cat"; then
            mark="${G}${BOLD}[开]${N}"
        else
            mark="${D}[关]${N}"
        fi
        name=$(cat_name "$cat")
        if [[ $i -eq $sel ]]; then
            printf '  %s▶%s %s  %s\n' "$C" "$N" "$mark" "$name"
        else
            printf '    %s  %s\n' "$mark" "$name"
        fi
        i=$((i+1))
    done

    printf '    %s─────────────────────────────────────────────────%s\n' "$D" "$N"

    local actions=(
        "应用改动(重启 x-ui)"
        "自定义域名屏蔽 …"
        "落地节点管理 (SOCKS5/HTTP) …"
        "路由到落地节点 …"
        "查看当前所有屏蔽"
        "清空所有屏蔽"
        "退出"
    )
    local a
    for a in "${actions[@]}"; do
        if [[ $i -eq $sel ]]; then
            printf '  %s▶%s      %s\n' "$C" "$N" "$a"
        else
            printf '         %s\n' "$a"
        fi
        i=$((i+1))
    done
    echo
}

# ---------- 动作函数 ----------
toggle_preset() {
    local cat="$1"
    local display; display=$(cat_name "$cat" | awk '{print $1}')
    local was_enabled=1
    is_enabled "$cat" || was_enabled=0

    LAST_ERROR=""
    if [[ $was_enabled -eq 1 ]]; then
        if disable_preset "$cat"; then
            LAST_ACTION="已关闭: $display"
            DIRTY=$((DIRTY + 1))
        fi
    else
        if enable_preset "$cat"; then
            LAST_ACTION="已开启: $display"
            DIRTY=$((DIRTY + 1))
        fi
    fi
}

apply_changes() {
    clear
    if [[ $DIRTY -eq 0 ]]; then
        printf '  %s没有改动需要应用%s\n' "$D" "$N"
        sleep 0.8
        return
    fi
    printf '  %s正在重启 x-ui ...%s\n' "$Y" "$N"
    if restart_xui; then
        DIRTY=0
        LAST_ACTION="已应用所有改动"
    else
        LAST_ERROR="x-ui 重启失败,查看 journalctl -u x-ui"
    fi
    sleep 0.8
}

custom_add() {
    clear
    printf '%s── 添加自定义屏蔽域名 ──%s\n\n' "$B" "$N"
    echo "每行一个,空行结束。语法:"
    printf '  %sdomain:example.com%s    匹配该域及所有子域 (推荐)\n' "$C" "$N"
    printf '  %sfull:example.com%s      仅完全匹配\n' "$C" "$N"
    printf '  %sregexp:.*\\.tk$%s        正则匹配\n' "$C" "$N"
    printf '  %skeyword:porn%s          关键字匹配\n' "$C" "$N"
    echo
    local lines=() line
    while IFS= read -r line </dev/tty; do
        [[ -z "$line" ]] && break
        lines+=("$line")
    done
    [[ ${#lines[@]} -eq 0 ]] && return

    local current new
    current=$(get_custom_list)
    new=$( { echo "$current"; printf '%s\n' "${lines[@]}"; } | sed '/^$/d' | awk '!seen[$0]++' )

    if set_custom_list "$new"; then
        LAST_ACTION="已添加 ${#lines[@]} 条自定义规则"
        DIRTY=$((DIRTY + 1))
    fi
}

custom_del() {
    clear
    printf '%s── 删除自定义屏蔽域名 ──%s\n\n' "$B" "$N"
    local cur; cur=$(get_custom_list)
    if [[ -z "$cur" ]]; then
        printf '  %s(空)%s\n' "$D" "$N"
        sleep 1
        return
    fi
    echo "$cur" | nl -w3 -s'. '
    echo
    read -rp "输入要删除的行号(空格分隔,留空取消): " nums </dev/tty
    [[ -z "$nums" ]] && return

    local new="$cur" ln victim
    for ln in $nums; do
        [[ "$ln" =~ ^[0-9]+$ ]] || continue
        victim=$(echo "$cur" | sed -n "${ln}p")
        [[ -n "$victim" ]] && new=$(echo "$new" | grep -Fxv -- "$victim" || true)
    done

    if set_custom_list "$new"; then
        LAST_ACTION="已删除"
        DIRTY=$((DIRTY + 1))
    fi
}

custom_list() {
    clear
    printf '%s── 自定义屏蔽列表 ──%s\n\n' "$B" "$N"
    local cur; cur=$(get_custom_list)
    if [[ -z "$cur" ]]; then
        printf '  %s(空)%s\n' "$D" "$N"
    else
        echo "$cur" | nl -w3 -s'. '
    fi
    echo
    read -rp "按回车返回..." _ </dev/tty
}

custom_menu() {
    while true; do
        clear
        printf '%s╔═══════════════════════════════════════════════════════╗%s\n' "$B" "$N"
        printf '%s║%s  自定义域名管理%s%s                                       ║%s\n' "$B" "$BOLD" "$N" "$B" "$N"
        printf '%s╚═══════════════════════════════════════════════════════╝%s\n' "$B" "$N"
        local count; count=$(get_custom_list | sed '/^$/d' | wc -l)
        printf '\n  当前共 %s%s%s 条自定义规则\n\n' "$G" "$count" "$N"
        echo "    1) 添加域名"
        echo "    2) 删除域名"
        echo "    3) 查看列表"
        echo "    q) 返回"
        echo
        read -rp "选择: " ch </dev/tty
        case "$ch" in
            1) custom_add ;;
            2) custom_del ;;
            3) custom_list ;;
            q|Q|"") break ;;
        esac
    done
}

# =============================================================================
# 落地节点管理 UI
# =============================================================================

landing_add() {
    clear
    printf '%s── 添加落地节点 ──%s\n\n' "$B" "$N"
    echo "选择协议类型:"
    echo "  1) SOCKS5"
    echo "  2) HTTP"
    echo "  q) 取消"
    read -rp "选择: " t </dev/tty
    local proto
    case "$t" in
        1) proto=socks ;;
        2) proto=http ;;
        *) return ;;
    esac

    echo
    read -rp "节点名称 (字母数字,作为 tag 后缀,例: jp1 / us-home): " name </dev/tty
    [[ -z "$name" ]] && { LAST_ERROR="名称不能为空"; return; }
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { LAST_ERROR="名称只能包含字母数字和 - _"; return; }

    # 检查重名
    if list_landings | awk -F'|' '{print $1}' | grep -qx "${LAND_PREFIX}${name}"; then
        read -rp "节点 ${LAND_PREFIX}${name} 已存在,覆盖? (y/N): " ok </dev/tty
        [[ "$ok" =~ ^[yY]$ ]] || return
    fi

    read -rp "服务器地址 (IP 或域名): " addr </dev/tty
    [[ -z "$addr" ]] && { LAST_ERROR="地址不能为空"; return; }

    read -rp "端口: " port </dev/tty
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) \
        || { LAST_ERROR="端口无效"; return; }

    read -rp "用户名 (无认证请留空): " user </dev/tty
    local pass=""
    if [[ -n "$user" ]]; then
        read -rp "密码: " pass </dev/tty
    fi

    if add_landing "$name" "$proto" "$addr" "$port" "$user" "$pass"; then
        LAST_ACTION="已添加落地节点: ${LAND_PREFIX}${name}"
        DIRTY=$((DIRTY + 1))
    fi
}

landing_del() {
    clear
    printf '%s── 删除落地节点 ──%s\n\n' "$B" "$N"
    local lines; lines=$(list_landings)
    if [[ -z "$lines" ]]; then
        printf '  %s(没有落地节点)%s\n' "$D" "$N"
        sleep 1
        return
    fi

    echo "当前落地节点:"
    local i=1
    local tags=()
    while IFS='|' read -r tag proto addr port user; do
        [[ -z "$tag" ]] && continue
        tags+=("$tag")
        if [[ -n "$user" ]]; then
            printf '  %d) %s  %s://%s@%s:%s\n' "$i" "$tag" "$proto" "$user" "$addr" "$port"
        else
            printf '  %d) %s  %s://%s:%s\n' "$i" "$tag" "$proto" "$addr" "$port"
        fi
        i=$((i+1))
    done <<< "$lines"
    echo
    read -rp "输入要删除的编号 (留空取消): " num </dev/tty
    [[ "$num" =~ ^[0-9]+$ ]] || return
    local idx=$((num - 1))
    [[ $idx -ge 0 && $idx -lt ${#tags[@]} ]] || return

    local target="${tags[$idx]}"
    read -rp "确认删除 $target ? 所有引用它的路由规则也会被删除 (y/N): " ok </dev/tty
    [[ "$ok" =~ ^[yY]$ ]] || return

    if del_landing "$target"; then
        LAST_ACTION="已删除落地节点: $target"
        DIRTY=$((DIRTY + 1))
    fi
}

landing_show() {
    clear
    printf '%s── 落地节点 ──%s\n\n' "$B" "$N"
    local lines; lines=$(list_landings)
    if [[ -z "$lines" ]]; then
        printf '  %s(没有落地节点)%s\n' "$D" "$N"
    else
        while IFS='|' read -r tag proto addr port user; do
            [[ -z "$tag" ]] && continue
            printf '  %s%s%s\n' "$BOLD" "$tag" "$N"
            if [[ -n "$user" ]]; then
                printf '    %s://%s@%s:%s\n' "$proto" "$user" "$addr" "$port"
            else
                printf '    %s://%s:%s\n' "$proto" "$addr" "$port"
            fi
        done <<< "$lines"
    fi
    echo
    read -rp "按回车返回..." _ </dev/tty
}

landing_menu() {
    while true; do
        clear
        printf '%s╔═══════════════════════════════════════════════════════╗%s\n' "$B" "$N"
        printf '%s║%s  落地节点管理 (SOCKS5 / HTTP)%s%s                         ║%s\n' "$B" "$BOLD" "$N" "$B" "$N"
        printf '%s╚═══════════════════════════════════════════════════════╝%s\n' "$B" "$N"
        local count; count=$(list_landings | grep -c . 2>/dev/null || echo 0)
        printf '\n  当前共 %s%s%s 个落地节点\n\n' "$G" "$count" "$N"
        echo "    1) 添加节点"
        echo "    2) 删除节点"
        echo "    3) 查看节点"
        echo "    q) 返回"
        echo
        read -rp "选择: " ch </dev/tty
        case "$ch" in
            1) landing_add ;;
            2) landing_del ;;
            3) landing_show ;;
            q|Q|"") break ;;
        esac
    done
}

# =============================================================================
# 路由到落地节点 UI
# =============================================================================

route_add() {
    clear
    printf '%s── 添加路由规则 ──%s\n\n' "$B" "$N"

    local lines; lines=$(list_landings)
    if [[ -z "$lines" ]]; then
        printf '  %s没有落地节点,请先去"落地节点管理"添加%s\n' "$R" "$N"
        sleep 2
        return
    fi

    echo "选择要路由到的落地节点:"
    local i=1
    local tags=()
    while IFS='|' read -r tag proto addr port _; do
        [[ -z "$tag" ]] && continue
        tags+=("$tag")
        printf '  %d) %s  (%s://%s:%s)\n' "$i" "$tag" "$proto" "$addr" "$port"
        i=$((i+1))
    done <<< "$lines"
    echo
    read -rp "节点编号: " num </dev/tty
    [[ "$num" =~ ^[0-9]+$ ]] || return
    local idx=$((num - 1))
    [[ $idx -ge 0 && $idx -lt ${#tags[@]} ]] || return
    local out_tag="${tags[$idx]}"

    echo
    read -rp "规则名称 (字母数字,例: netflix / games): " name </dev/tty
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || { LAST_ERROR="规则名称无效"; return; }

    echo
    echo "输入要路由的域名 (每行一个,空行结束)。语法:"
    printf '  %sdomain:netflix.com%s    匹配域及子域 (推荐)\n' "$C" "$N"
    printf '  %sfull:example.com%s      仅完全匹配\n' "$C" "$N"
    printf '  %skeyword:openai%s        关键字匹配\n' "$C" "$N"
    echo
    local domains=() line
    while IFS= read -r line </dev/tty; do
        [[ -z "$line" ]] && break
        domains+=("$line")
    done
    [[ ${#domains[@]} -eq 0 ]] && { LAST_ERROR="未输入任何域名"; return; }

    # 合并旧规则(如存在)
    local existing
    existing=$(get_route_domains "${ROUTE_PREFIX}${name}")
    local merged
    merged=$( { echo "$existing"; printf '%s\n' "${domains[@]}"; } | sed '/^$/d' | awk '!seen[$0]++' )

    if set_route "$name" "$out_tag" "$merged"; then
        LAST_ACTION="已添加路由 ${ROUTE_PREFIX}${name} → $out_tag"
        DIRTY=$((DIRTY + 1))
    fi
}

route_del() {
    clear
    printf '%s── 删除路由规则 ──%s\n\n' "$B" "$N"
    local lines; lines=$(list_routes)
    if [[ -z "$lines" ]]; then
        printf '  %s(没有路由规则)%s\n' "$D" "$N"
        sleep 1
        return
    fi

    echo "当前路由规则:"
    local i=1
    local tags=()
    while IFS='|' read -r tag out count; do
        [[ -z "$tag" ]] && continue
        tags+=("$tag")
        printf '  %d) %s  →  %s  (%s 个域名)\n' "$i" "$tag" "$out" "$count"
        i=$((i+1))
    done <<< "$lines"
    echo
    read -rp "输入要删除的编号 (留空取消): " num </dev/tty
    [[ "$num" =~ ^[0-9]+$ ]] || return
    local idx=$((num - 1))
    [[ $idx -ge 0 && $idx -lt ${#tags[@]} ]] || return

    if del_route "${tags[$idx]}"; then
        LAST_ACTION="已删除路由: ${tags[$idx]}"
        DIRTY=$((DIRTY + 1))
    fi
}

route_show() {
    clear
    printf '%s── 路由规则 ──%s\n\n' "$B" "$N"
    local lines; lines=$(list_routes)
    if [[ -z "$lines" ]]; then
        printf '  %s(没有路由规则)%s\n' "$D" "$N"
    else
        while IFS='|' read -r tag out count; do
            [[ -z "$tag" ]] && continue
            printf '  %s%s%s  →  %s%s%s\n' "$BOLD" "$tag" "$N" "$G" "$out" "$N"
            get_route_domains "$tag" | sed 's/^/      /'
            echo
        done <<< "$lines"
    fi
    read -rp "按回车返回..." _ </dev/tty
}

route_menu() {
    while true; do
        clear
        printf '%s╔═══════════════════════════════════════════════════════╗%s\n' "$B" "$N"
        printf '%s║%s  路由规则管理 (域名 → 落地节点)%s%s                       ║%s\n' "$B" "$BOLD" "$N" "$B" "$N"
        printf '%s╚═══════════════════════════════════════════════════════╝%s\n' "$B" "$N"
        local count; count=$(list_routes | grep -c . 2>/dev/null || echo 0)
        printf '\n  当前共 %s%s%s 条路由规则\n\n' "$G" "$count" "$N"
        echo "    1) 添加路由规则"
        echo "    2) 删除路由规则"
        echo "    3) 查看路由规则"
        echo "    q) 返回"
        echo
        read -rp "选择: " ch </dev/tty
        case "$ch" in
            1) route_add ;;
            2) route_del ;;
            3) route_show ;;
            q|Q|"") break ;;
        esac
    done
}

show_all() {
    clear
    printf '%s── 当前所有屏蔽规则 ──%s\n\n' "$B" "$N"
    local any=0 cat name
    for cat in "${CATS[@]}"; do
        if is_enabled "$cat"; then
            any=1
            name=$(cat_name "$cat")
            printf '  %s[开]%s  %s\n' "$G" "$N" "$name"
        fi
    done
    [[ $any -eq 0 ]] && printf '  %s(未启用任何预设分类)%s\n' "$D" "$N"

    local cur; cur=$(get_custom_list)
    if [[ -n "$cur" ]]; then
        echo
        printf '%s  自定义域名 (%s 条):%s\n' "$BOLD" "$(echo "$cur" | wc -l)" "$N"
        echo "$cur" | sed 's/^/    /'
    fi
    echo
    read -rp "按回车返回..." _ </dev/tty
}

clear_all() {
    clear
    read -rp "确认清空所有屏蔽 (预设 + 自定义)? (y/N): " c </dev/tty
    [[ "$c" =~ ^[yY]$ ]] || return

    local cat ok=1
    for cat in "${CATS[@]}"; do
        disable_preset "$cat" || ok=0
    done
    set_custom_list "" || ok=0

    if [[ $ok -eq 1 ]]; then
        LAST_ACTION="已清空所有屏蔽"
        DIRTY=$((DIRTY + 1))
    fi
}

on_quit() {
    if [[ $DIRTY -gt 0 ]]; then
        clear
        printf '%s⚠ 有 %d 项改动未应用%s\n\n' "$Y" "$DIRTY" "$N"
        read -rp "是否应用 (重启 x-ui)? (Y/n): " c </dev/tty
        if [[ ! "$c" =~ ^[nN]$ ]]; then
            printf '%s应用中...%s\n' "$Y" "$N"
            if restart_xui; then
                printf '%s✓ 已应用%s\n' "$G" "$N"
            else
                printf '%s✗ x-ui 重启失败%s\n' "$R" "$N"
            fi
            sleep 1
        fi
    fi
    clear
    exit 0
}

# ---------- 启动自检 ----------
self_check() {
    local tables
    tables=$(sqlite3 "$DB" ".tables" 2>&1)
    if ! echo "$tables" | grep -qw "settings"; then
        err "数据库中没有 settings 表"
        err "输出: $tables"
        exit 1
    fi

    # 尝试写一次骨架,让 blackhole outbound 就位
    local tpl; tpl=$(db_read)
    local new
    new=$(echo "$tpl" | jq --arg bh "$BLACKHOLE_TAG" '
        (if ((.outbounds // []) | any(.tag == $bh)) then .
         else .outbounds = ((.outbounds // []) + [{tag:$bh, protocol:"blackhole"}]) end)
        | .routing = (.routing // {})
        | .routing.rules = (.routing.rules // [])
    ')
    if ! db_write "$new"; then
        err "数据库写入自检失败: $LAST_ERROR"
        err "尝试修复: 打开 3x-ui 面板 → Xray 配置 → 点击保存"
        exit 1
    fi
}

# ---------- 主循环 ----------
main() {
    self_check

    local sel=0
    local n_cats=${#CATS[@]}
    local n_actions=7
    local total=$((n_cats + n_actions))

    while true; do
        draw_main "$sel"
        read_key
        case "$KEY" in
            $'\e[A'|k|K)
                sel=$((sel - 1))
                (( sel < 0 )) && sel=$((total - 1))
                ;;
            $'\e[B'|j|J)
                sel=$((sel + 1))
                (( sel >= total )) && sel=0
                ;;
            ' '|$'\n')
                if (( sel < n_cats )); then
                    toggle_preset "${CATS[$sel]}"
                else
                    case $((sel - n_cats)) in
                        0) apply_changes ;;
                        1) custom_menu ;;
                        2) landing_menu ;;
                        3) route_menu ;;
                        4) show_all ;;
                        5) clear_all ;;
                        6) on_quit ;;
                    esac
                fi
                ;;
            a|A) apply_changes ;;
            q|Q|$'\e') on_quit ;;
        esac
    done
}

main
