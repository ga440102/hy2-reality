#!/bin/bash
# ============================================================================
# hy2-reality.sh — Hysteria2 + Reality 二合一安装脚本 (带选项)
#
# 用法:
#   整段粘贴到 root 终端回车, 按菜单安装 / 卸载
#   bash hy2-reality.sh hy2                # 直接装 HY2, 跳过菜单
#   bash hy2-reality.sh reality            # 直接装 Reality, 跳过菜单
#   bash hy2-reality.sh uninstall-hy2      # 卸载 HY2, 跳过菜单
#   bash hy2-reality.sh uninstall-reality  # 卸载 Reality, 跳过菜单
#   bash hy2-reality.sh show               # 查看已安装节点信息, 跳过菜单
#   bash hy2-reality.sh hy2 --measure-only # 只测速不安装
#   bash hy2-reality.sh hy2 --no-bandwidth # HY2 跳过测速, BBR 模式安装
#
# 可调选项 (粘贴前改这里):
#   MODE="ask"   # ask=菜单 / hy2 / reality / uninstall-hy2 / uninstall-reality
#   HY2_PORT="8443"                # HY2 UDP 端口 (被占用则随机)
#   SKIP_BANDWIDTH=0               # 1=跳过测速与带宽参数, BBR 模式装 HY2
#   MEASURE_ONLY=0                 # 1=只测速不安装
#   REALITY_PORT="8880"            # Reality TCP 端口 (被占用则随机)
#   REALITY_SNI="www.microsoft.com"# Reality 伪装域名 (dest 自动跟随)
#   REALITY_DEST=""                # 留空则自动为 $REALITY_SNI:443
#   REALITY_UUID=""                # 留空则随机生成 (重装时复用旧 UUID)
#
# 说明:
#   HY2 部分: 自动测速 (各 3 次取中位数 × 0.8) 决定带宽参数, 启用 Brutal;
#             测速失败时可重测 / 降级 BBR / 退出
#   Reality 部分: VLESS + TCP + Reality, 伪装站与 SNI 一致, 自动放行防火墙,
#             输出 vless 链接 + 二维码 + Clash 配置片段
#   菜单开机先显示已安装状态; 操作完成后按任意键返回主菜单;
#   卸载会删除服务、配置、证书/密钥与二进制, 并清理本机防火墙规则
# ============================================================================
(
export LANG=en_US.UTF-8

# ---------- 共享: 颜色与输出 ----------
re='\e[0m'; red='\e[1;91m'; green='\e[1;32m'; yellow='\e[1;33m'; skyblue='\e[1;96m'
die()  { echo -e "${red}[错误] $*${re}" >&2; exit 1; }
info() { echo -e "${green}[信息] $*${re}"; }
warn() { echo -e "${yellow}[警告] $*${re}" >&2; }

# ---------- 可调选项 ----------
MODE="${MODE:-ask}"                  # ask / hy2 / reality / uninstall-hy2 / uninstall-reality / show
HY2_PORT="${HY2_PORT:-8443}"
SKIP_BANDWIDTH="${SKIP_BANDWIDTH:-0}"
MEASURE_ONLY="${MEASURE_ONLY:-0}"
RUNS=3
SAFETY="0.8"
MIN_MBPS=5
UP_TEST_MB=20
REALITY_PORT="${REALITY_PORT:-8880}"
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
REALITY_DEST="${REALITY_DEST:-}"
REALITY_UUID="${REALITY_UUID:-}"

[[ $EUID -ne 0 ]] && die "请在 root 用户下运行脚本"

# ---------- 公共函数 (顶层定义, 各子 shell 均可继承) ----------
get_ip() {
  HOST_IP=$(curl -4 -s --max-time 5 ipv4.ip.sb)
  [ -z "$HOST_IP" ] && HOST_IP=$(curl -s --max-time 5 ipv4.ip.sb)
  [ -z "$HOST_IP" ] && { echo -e "${red}无法获取公网 IP${re}"; exit 1; }
}

print_links() {
  local port=$1 passwd=$2
  local tag="HY2-${HOST_IP}"
  echo ""
  echo -e "${green}========== 节点信息 ==========${re}"
  echo -e "端口: ${skyblue}$port${re}  密码: ${skyblue}$passwd${re}"
  if [ -n "${CFG_UP_MBPS:-}" ]; then
    echo -e "带宽: up ${CFG_UP_MBPS} Mbps / down ${CFG_DOWN_MBPS} Mbps (Brutal 已启用)"
  else
    echo -e "${yellow}未设置带宽参数, 当前为 BBR 模式${re}"
  fi
  echo ""
  echo -e "${yellow}--- V2rayN / Nekobox / Streisand ---${re}"
  echo "hysteria2://$passwd@$HOST_IP:$port/?sni=www.bing.com&alpn=h3&insecure=1#$tag"
  echo ""
  echo -e "${yellow}--- Clash / Mihomo ---${re}"
  echo "- name: $tag"
  echo "  type: hysteria2"
  echo "  server: $HOST_IP"
  echo "  port: $port"
  echo "  password: $passwd"
  if [ -n "${CFG_UP_MBPS:-}" ]; then
    echo "  up: \"${CFG_UP_MBPS} Mbps\""
    echo "  down: \"${CFG_DOWN_MBPS} Mbps\""
  fi
  echo "  sni: www.bing.com"
  echo "  alpn:"
  echo "    - h3"
  echo "  skip-cert-verify: true"
  echo ""
  echo -e "${red}注意: 云厂商安全组 (如 AWS) 需手动放行 UDP $port, 脚本够不着控制台${re}"
}

# ============================================================================
# HY2 部分 (独立子 shell, 与 Reality 部分零冲突)
# ============================================================================
run_hy2() (
# ---------------- 依赖 ----------------
install_deps() {
  for cmd in curl openssl; do
    command -v "$cmd" >/dev/null 2>&1 && continue
    echo -e "${yellow}正在安装 $cmd ...${re}"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y -qq "$cmd"
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y -q "$cmd"
    elif command -v yum >/dev/null 2>&1; then
      yum install -y -q "$cmd"
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache "$cmd"
    else
      echo -e "${red}不支持的系统${re}"; exit 1
    fi
  done
}

# ---------------- 测速 ----------------
# 中位数: 输入一组字节/秒, 输出中位数
median_bps() {
  local arr sorted n mid
  arr=("$@")
  sorted=($(printf '%s\n' "${arr[@]}" | sort -n))
  n=${#sorted[@]}
  [ "$n" -eq 0 ] && echo 0 && return
  mid=$((n / 2))
  if [ $((n % 2)) -eq 1 ]; then
    echo "${sorted[$mid]}"
  else
    echo $(( (sorted[mid-1] + sorted[mid]) / 2 ))
  fi
}

# 字节/秒 -> Mbps 显示 (1 位小数)
to_mbps() {
  awk "BEGIN{printf \"%.1f\", $1*8/1000000}"
}

# 测下载, 输出中位数 (字节/秒)
measure_down() {
  local speeds=() s i
  for i in $(seq 1 "$RUNS"); do
    s=$(curl -4 -o /dev/null -s -w '%{speed_download}' --max-time 20 \
      http://cachefly.cachefly.net/100mb.test 2>/dev/null)
    s=${s%.*}
    if [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -gt 0 ]; then
      speeds+=("$s")
      echo -e "${skyblue}  下载测试 $i/$RUNS: $(to_mbps "$s") Mbps${re}" >&2
    else
      echo -e "${skyblue}  下载测试 $i/$RUNS: 失败${re}" >&2
    fi
  done
  median_bps "${speeds[@]}"
}

# 测上传, 输出中位数 (字节/秒)
measure_up() {
  local speeds=() s i
  dd if=/dev/urandom of=/tmp/hy2up_test bs=1M count="$UP_TEST_MB" 2>/dev/null
  for i in $(seq 1 "$RUNS"); do
    s=$(curl -4 -s -o /dev/null -w '%{speed_upload}' --max-time 30 \
      -X POST --data-binary @/tmp/hy2up_test https://speed.cloudflare.com/__up 2>/dev/null)
    s=${s%.*}
    if [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -gt 0 ]; then
      speeds+=("$s")
      echo -e "${skyblue}  上传测试 $i/$RUNS: $(to_mbps "$s") Mbps${re}" >&2
    else
      echo -e "${skyblue}  上传测试 $i/$RUNS: 失败${re}" >&2
    fi
  done
  rm -f /tmp/hy2up_test
  median_bps "${speeds[@]}"
}

# 决策: 字节/秒 -> 保守 Mbps 整数 (中位数 × 安全系数, 向下取整, 保底 MIN_MBPS)
decide_mbps() {
  local mbps
  mbps=$(awk "BEGIN{printf \"%d\", $1*8/1000000*$SAFETY}")
  [ "$mbps" -lt "$MIN_MBPS" ] && mbps=$MIN_MBPS
  echo "$mbps"
}

# 测速 + 决策, 成功返回 0, 并设置 CFG_UP_MBPS / CFG_DOWN_MBPS
do_measure() {
  echo -e "${yellow}正在测速 (下载/上传各 $RUNS 次, 取中位数 × $SAFETY 保守系数)...${re}"
  DOWN_BPS=$(measure_down)
  UP_BPS=$(measure_up)
  echo -e "${green}实测中位数: 下载 $(to_mbps "$DOWN_BPS") Mbps / 上传 $(to_mbps "$UP_BPS") Mbps${re}"
  if [ "$DOWN_BPS" -eq 0 ] || [ "$UP_BPS" -eq 0 ]; then
    echo -e "${red}测速失败, 无法决定带宽参数${re}"
    return 1
  fi
  # 注意方向: 服务端 up = 服务端上传 = 本机上传 ; 服务端 down = 本机下载
  CFG_UP_MBPS=$(decide_mbps "$UP_BPS")
  CFG_DOWN_MBPS=$(decide_mbps "$DOWN_BPS")
  echo -e "${green}决定参数: bandwidth.up = ${CFG_UP_MBPS} mbps, bandwidth.down = ${CFG_DOWN_MBPS} mbps${re}"
  return 0
}

# 测速失败时询问用户: 返回 2=重测, 1=降级 BBR (选择 3 则直接退出)
# 用 /dev/tty 读取, 粘贴运行时也不会误吞脚本自身的输入
ask_on_measure_fail() {
  local choice=""
  echo -e "${yellow}测速失败, 请选择:${re}"
  echo "  1) 重新测速"
  echo "  2) 降级为 BBR 模式继续安装 (不写 bandwidth 参数)"
  echo "  3) 退出安装"
  read -r -p "请输入 1/2/3 [默认 2]: " choice < /dev/tty 2>/dev/null || choice="2"
  echo ""
  case "$choice" in
    1) return 2 ;;
    3) echo -e "${yellow}已退出安装${re}"; exit 1 ;;
    *) return 1 ;;
  esac
}

# ---------------- 安装 ----------------
pick_port() {
  local p="$HY2_PORT"
  if ss -ulpn 2>/dev/null | grep -qE "[:.]$p[[:space:]]"; then
    p=$(shuf -i 20000-60000 -n 1)
    echo -e "${yellow}端口 $HY2_PORT 被占用, 改用随机端口 $p${re}" >&2
  fi
  echo "$p"
}

install_hy2() {
  echo -e "${yellow}正在安装 Hysteria2 ...${re}"
  bash <(curl -fsSL https://get.hy2.sh/) >/tmp/hy2install.log 2>&1 \
    && echo -e "${green}Hysteria2 安装成功${re}" \
    || { echo -e "${red}安装失败, 日志:${re}"; tail -20 /tmp/hy2install.log; exit 1; }
}

gen_cert() {
  mkdir -p /etc/hysteria
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
    -subj "/CN=bing.com" -days 36500 2>/dev/null \
    && echo -e "${green}自签证书已生成${re}"
  chmod 600 /etc/hysteria/server.key
}

write_config() {
  local port=$1 passwd=$2
  {
    echo "listen: :$port"
    echo ""
    echo "tls:"
    echo "  cert: /etc/hysteria/server.crt"
    echo "  key: /etc/hysteria/server.key"
    echo ""
    echo "auth:"
    echo "  type: password"
    echo "  password: \"$passwd\""
    echo ""
    if [ -n "${CFG_UP_MBPS:-}" ]; then
      echo "bandwidth:"
      echo "  up: ${CFG_UP_MBPS} mbps"
      echo "  down: ${CFG_DOWN_MBPS} mbps"
      echo ""
    fi
    echo "masquerade:"
    echo "  type: proxy"
    echo "  proxy:"
    echo "    url: https://bing.com"
    echo "    rewriteHost: true"
  } > /etc/hysteria/config.yaml
  id hysteria >/dev/null 2>&1 && chown -R hysteria:hysteria /etc/hysteria
  echo -e "${green}配置文件已写入${re}"
}

start_service() {
  systemctl daemon-reload
  systemctl enable hysteria-server.service >/dev/null 2>&1
  systemctl restart hysteria-server.service
  sleep 3
  if [ "$(systemctl is-active hysteria-server.service)" = "active" ]; then
    echo -e "${green}服务运行中${re}"
  else
    echo -e "${red}服务启动失败, 请检查: journalctl -u hysteria-server${re}"
    exit 1
  fi
}

open_firewall() {
  local port=$1
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$port"/udp >/dev/null && echo -e "${green}ufw 已放行 $port/udp${re}"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    firewall-cmd --permanent --add-port="$port"/udp >/dev/null && firewall-cmd --reload >/dev/null \
      && echo -e "${green}firewalld 已放行 $port/udp${re}"
  else
    echo -e "${yellow}未检测到启用的本机防火墙 (云厂商安全组请手动放行 UDP $port)${re}"
  fi
}

# ---------------- 主流程 ----------------
for arg in "$@"; do
  case "$arg" in
    --measure-only) MEASURE_ONLY=1 ;;
    --no-bandwidth) SKIP_BANDWIDTH=1 ;;
  esac
done

if [ "$MEASURE_ONLY" = "1" ]; then
  install_deps
  if do_measure; then
    echo ""
    echo -e "${green}建议配置:${re}"
    echo "bandwidth:"
    echo "  up: ${CFG_UP_MBPS} mbps    # 服务端上传 = 本机上传"
    echo "  down: ${CFG_DOWN_MBPS} mbps  # 服务端下载 = 本机下载"
  fi
  exit 0
fi

install_deps

echo -e "${yellow}=== 第 1 步: 测速并决定带宽参数 ===${re}"
if [ "$SKIP_BANDWIDTH" = "1" ]; then
  echo -e "${yellow}已跳过测速与带宽参数, 使用 BBR 模式安装${re}"
  CFG_UP_MBPS=""; CFG_DOWN_MBPS=""
else
  while true; do
    if do_measure; then
      echo -e "${green}将启用 Brutal 拥塞控制${re}"
      break
    fi
    ask_on_measure_fail
    if [ $? -eq 1 ]; then
      echo -e "${yellow}降级为 BBR 模式继续安装${re}"
      CFG_UP_MBPS=""; CFG_DOWN_MBPS=""
      break
    fi
    # 返回 2: 循环回去重新测速
  done
fi

echo -e "${yellow}=== 第 2 步: 安装 Hysteria2 ===${re}"
install_hy2

echo -e "${yellow}=== 第 3 步: 生成证书与配置 ===${re}"
PORT=$(pick_port)
PASSWD=$(cat /proc/sys/kernel/random/uuid)
gen_cert
write_config "$PORT" "$PASSWD"

echo -e "${yellow}=== 第 4 步: 启动服务 ===${re}"
start_service
open_firewall "$PORT"

echo -e "${yellow}=== 第 5 步: 输出节点信息 ===${re}"
get_ip
print_links "$PORT" "$PASSWD"
)

# ============================================================================
# Reality 部分 (独立子 shell, 与 HY2 部分零冲突)
# ============================================================================
run_reality() (
set -euo pipefail

# 变量映射: 顶部 REALITY_* 选项 -> 内部变量名
PORT="$REALITY_PORT"
UUID="$REALITY_UUID"
SNI="$REALITY_SNI"
DEST="${REALITY_DEST:-$REALITY_SNI:443}"

CONFIG_FILE="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"

RE_PRIVATE_KEY=""
RE_PUBLIC_KEY=""
SHORT_ID=""

# ---------- 安装依赖（缺啥装啥） ----------
install_deps() {
    local pkgs="gawk curl openssl qrencode" pkg missing=""
    for pkg in $pkgs; do
        command -v "$pkg" &>/dev/null || missing="$missing $pkg"
    done
    if [[ -z "$missing" ]]; then
        info "系统依赖已齐全，跳过安装"
        return 0
    fi
    info "正在安装缺失依赖:$missing"
    if command -v apt-get &>/dev/null; then
        apt-get update -qq || warn "apt-get update 失败，继续尝试安装"
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q $missing || die "依赖安装失败:$missing"
    elif command -v dnf &>/dev/null; then
        # shellcheck disable=SC2086
        dnf install -y $missing || die "依赖安装失败:$missing"
    elif command -v yum &>/dev/null; then
        # shellcheck disable=SC2086
        yum install -y $missing || die "依赖安装失败:$missing"
    elif command -v apk &>/dev/null; then
        # shellcheck disable=SC2086
        apk add $missing || die "依赖安装失败:$missing"
    else
        die "暂不支持的系统"
    fi
}

# ---------- 安装 Xray（已安装则跳过） ----------
install_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        info "检测到 Xray 已安装，跳过安装步骤"
        return 0
    fi
    info "正在安装 Xray..."
    local installer
    installer="$(curl -fsSL --max-time 60 https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" \
        || die "下载 Xray 安装脚本失败"
    bash -c "$installer" @ install || die "Xray 安装失败"
    [[ -x "$XRAY_BIN" ]] || die "Xray 安装后仍找不到二进制文件: $XRAY_BIN"
}

# ---------- 端口预检（全新安装时被占则换随机端口） ----------
check_port() {
    [[ -f "$CONFIG_FILE" ]] && return 0
    if ss -tlnp 2>/dev/null | grep -qE "[:.]$PORT[[:space:]]"; then
        warn "端口 $PORT 已被占用，改用随机端口"
        PORT="$(shuf -i 20000-60000 -n 1)"
        info "新端口: $PORT"
    fi
}

# ---------- UUID：优先复用旧配置 ----------
resolve_uuid() {
    if [[ -z "$UUID" && -f "$CONFIG_FILE" ]]; then
        UUID="$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONFIG_FILE" | head -1 | cut -d'"' -f4)"
        [[ -n "$UUID" ]] && info "复用旧配置中的 UUID，老客户端不受影响"
    fi
    if [[ -z "$UUID" ]]; then
        UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/')"
    fi
    [[ "$UUID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "无法获得合法的 UUID"
}

# ---------- 生成密钥对（兼容多种输出格式，解析失败直接报错） ----------
gen_keys() {
    local out
    out="$("$XRAY_BIN" x25519 | tr -d '\r')" || die "执行 xray x25519 失败"
    RE_PRIVATE_KEY="$(awk -F': *' 'tolower($0) ~ /private/ && tolower($0) ~ /key/ {print $2; exit}' <<<"$out" | awk '{print $1}')"
    RE_PUBLIC_KEY="$(awk -F': *' 'tolower($0) ~ /public/ && tolower($0) ~ /key/ {print $2; exit}' <<<"$out" | awk '{print $1}')"
    [[ -n "$RE_PRIVATE_KEY" && -n "$RE_PUBLIC_KEY" ]] || die "密钥解析失败，xray 输出异常: $out"
    SHORT_ID="$(openssl rand -hex 8)" || die "shortId 生成失败"
}

# ---------- 写配置（先备份，权限 600，写完校验） ----------
write_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local bak="${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -a "$CONFIG_FILE" "$bak" || die "备份旧配置失败"
        info "已备份旧配置到 $bak"
    else
        mkdir -p "$(dirname "$CONFIG_FILE")"
    fi
    cat > "$CONFIG_FILE" <<EOF
{
    "inbounds": [
        {
            "port": $PORT,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$UUID",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "$DEST",
                    "xver": 0,
                    "serverNames": ["$SNI"],
                    "privateKey": "$RE_PRIVATE_KEY",
                    "shortIds": ["$SHORT_ID"]
                }
            }
        }
    ],
    "outbounds": [
        {"protocol": "freedom", "tag": "direct"},
        {"protocol": "blackhole", "tag": "blocked"}
    ]
}
EOF
    chmod 600 "$CONFIG_FILE" || die "设置配置文件权限失败"
    "$XRAY_BIN" run -test -config "$CONFIG_FILE" &>/dev/null || die "生成的配置文件未通过 Xray 校验"
    info "配置文件已写入并通过校验: $CONFIG_FILE"
}

# ---------- 启动服务（兼容无 systemd 环境） ----------
start_service() {
    if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
        systemctl enable xray.service || die "设置 xray 开机自启失败"
        systemctl restart xray.service || die "xray 服务启动失败"
        systemctl is-active --quiet xray.service || die "xray 服务未能保持运行，查看日志: journalctl -u xray -n 50"
        info "xray 服务已启动并设为开机自启"
    else
        warn "未检测到 systemd，改用后台进程方式启动"
        pkill -f "[x]ray run" 2>/dev/null || true
        nohup "$XRAY_BIN" run -config "$CONFIG_FILE" >/var/log/xray-reality.log 2>&1 &
        sleep 2
        pgrep -f "[x]ray run" >/dev/null || die "xray 后台启动失败，查看日志: /var/log/xray-reality.log"
        info "xray 已在后台运行（日志: /var/log/xray-reality.log）"
    fi
}

# ---------- 防火墙 ----------
open_firewall() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$PORT"/tcp >/dev/null 2>&1 \
            && info "ufw 已放行 $PORT/tcp" \
            || warn "ufw 放行失败，请手动放行 TCP $PORT"
    elif command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
        if firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; then
            info "firewalld 已放行 $PORT/tcp"
        else
            warn "firewalld 放行失败，请手动放行 TCP $PORT"
        fi
    else
        warn "未检测到启用的本机防火墙；云厂商安全组 (如 AWS) 请手动放行 TCP $PORT"
    fi
}

# ---------- 获取服务器 IP ----------
get_ip() {
    local ip
    ip="$(curl -fsS --max-time 3 https://ipv4.ip.sb 2>/dev/null)" || ip=""
    if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
    ip="$(curl -fsS --max-time 3 https://ipv6.ip.sb 2>/dev/null)" || ip=""
    if [[ -n "$ip" ]]; then echo "[$ip]"; return 0; fi
    if command -v ip &>/dev/null; then
        ip="$(ip route get 8.8.8.8 2>/dev/null | sed -n 's/.*[[:space:]]src[[:space:]][[:space:]]*\([0-9.]*\).*/\1/p' | head -1)"
        if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
    fi
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -n "$ip" ]]; then echo "$ip"; return 0; fi
    return 1
}

# ---------- 生成备注名 ----------
get_tag() {
    local json tag=""
    json="$(curl -fsS --max-time 3 "https://api.ip.sb/geoip" 2>/dev/null)" || json=""
    if [[ -n "$json" ]]; then
        tag="$(awk -F'"' '{for(i=1;i<NF;i++){if($i=="country_code")c=$(i+2);if($i=="isp")s=$(i+2)}} END{if(c&&s)print c"-"s}' <<<"$json")"
    fi
    if [[ -z "$tag" ]]; then
        json="$(curl -fsS --max-time 3 "https://ip.api.skk.moe/cf-geoip" 2>/dev/null)" || json=""
        if [[ -n "$json" ]]; then
            tag="$(awk -F'"' '{for(i=1;i<NF;i++){if($i=="country")c=$(i+2);if($i=="asOrg")s=$(i+2)}} END{if(c&&s)print c"-"s}' <<<"$json")"
        fi
    fi
    [[ -z "$tag" ]] && tag="reality"
    tag="$(sed 's/ /_/g' <<<"$tag" | tr -cd '[:alnum:]_.-')"
    [[ -z "$tag" ]] && tag="reality"
    echo "$tag"
}

# ---------- 输出分享链接 + 二维码 + Clash 片段 ----------
print_link() {
    local ip tag url
    ip="$(get_ip)" || die "无法获取服务器公网 IP"
    if [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
        warn "检测到内网 IP ($ip)，疑似 NAT 机器：下方链接不可直接使用，请把链接中的 IP 手动替换为公网 IP"
    fi
    tag="$(get_tag)"
    url="vless://${UUID}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${RE_PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${tag}"
    echo ""
    info "Reality 安装成功，客户端导入链接："
    echo -e "\e[1;36m${url}\e[0m"
    echo ""
    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 -m 2 -o - "$url" || warn "二维码生成失败"
        echo ""
    fi
    echo "--- Clash / Mihomo 配置片段 ---"
    echo "- name: ${tag}"
    echo "  type: vless"
    echo "  server: ${ip}"
    echo "  port: ${PORT}"
    echo "  uuid: ${UUID}"
    echo "  network: tcp"
    echo "  tls: true"
    echo "  udp: true"
    echo "  flow: xtls-rprx-vision"
    echo "  servername: ${SNI}"
    echo "  client-fingerprint: chrome"
    echo "  reality-opts:"
    echo "    public-key: ${RE_PUBLIC_KEY}"
    echo "    short-id: ${SHORT_ID}"
    echo ""
}

# ---------- 主流程 ----------
install_deps
install_xray
check_port
resolve_uuid
gen_keys
write_config
start_service
open_firewall
print_link
)

# ============================================================================
# 安装状态探测与卸载
# ============================================================================
HY2_CONF="/etc/hysteria/config.yaml"
XRAY_CONF="/usr/local/etc/xray/config.json"

detect_status() {
  HY2_STATE="未安装"; HY2_DETAIL=""
  if [[ -f "$HY2_CONF" ]]; then
    local p
    p=$(sed -n 's/^listen: :\([0-9][0-9]*\).*/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
    HY2_STATE="已安装"; HY2_DETAIL="UDP ${p:-未知端口}"
    if systemctl is-active --quiet hysteria-server.service 2>/dev/null; then
      HY2_DETAIL="$HY2_DETAIL, 运行中"
    else
      HY2_DETAIL="$HY2_DETAIL, 未运行"
    fi
  fi
  RE_STATE="未安装"; RE_DETAIL=""
  if [[ -f "$XRAY_CONF" ]]; then
    local p
    p=$(grep -o '"port": [0-9][0-9]*' "$XRAY_CONF" 2>/dev/null | head -1 | grep -o '[0-9][0-9]*' || true)
    RE_STATE="已安装"; RE_DETAIL="TCP ${p:-未知端口}"
    if systemctl is-active --quiet xray.service 2>/dev/null; then
      RE_DETAIL="$RE_DETAIL, 运行中"
    else
      RE_DETAIL="$RE_DETAIL, 未运行"
    fi
  fi
}

clean_firewall_rule() {  # $1=端口 $2=udp|tcp, 尽力清理本机防火墙规则
  local port=$1 proto=$2
  [[ -n "$port" ]] || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow "$port"/"$proto" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep -q running; then
    firewall-cmd --permanent --remove-port="$port"/"$proto" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

uninstall_hy2() {
  if [[ ! -f "$HY2_CONF" ]]; then
    echo -e "${yellow}Hysteria2 未安装, 无需卸载${re}"
    return 0
  fi
  local port
  port=$(sed -n 's/^listen: :\([0-9][0-9]*\).*/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  echo -e "${yellow}将卸载 Hysteria2 (停止服务, 删除配置、证书与程序)${re}"
  local _c
  read -r -p "确定继续? (y/n) [n]: " _c </dev/tty
  [[ "$_c" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }
  systemctl stop hysteria-server.service 2>/dev/null || true
  systemctl disable hysteria-server.service 2>/dev/null || true
  rm -f /etc/systemd/system/hysteria-server.service
  rm -f /usr/local/bin/hysteria
  rm -rf /etc/hysteria
  systemctl daemon-reload 2>/dev/null || true
  clean_firewall_rule "$port" udp
  echo -e "${green}Hysteria2 已卸载${re}"
  [[ -n "$port" ]] && echo -e "${yellow}提示: 云安全组中 UDP $port 的放行规则如不再需要, 请手动删除${re}"
}

uninstall_reality() {
  if [[ ! -f "$XRAY_CONF" ]]; then
    echo -e "${yellow}Reality 未安装, 无需卸载${re}"
    return 0
  fi
  local port
  port=$(grep -o '"port": [0-9][0-9]*' "$XRAY_CONF" 2>/dev/null | head -1 | grep -o '[0-9][0-9]*' || true)
  echo -e "${yellow}将卸载 Reality (停止服务, 删除配置、密钥与程序)${re}"
  local _c
  read -r -p "确定继续? (y/n) [n]: " _c </dev/tty
  [[ "$_c" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl stop xray.service 2>/dev/null || true
    systemctl disable xray.service 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service
    systemctl daemon-reload 2>/dev/null || true
  fi
  pkill -f "[x]ray run" 2>/dev/null || true
  rm -f /usr/local/bin/xray
  rm -rf /usr/local/etc/xray
  rm -rf /usr/local/share/xray
  rm -f /var/log/xray-reality.log
  clean_firewall_rule "$port" tcp
  echo -e "${green}Reality 已卸载${re}"
  [[ -n "$port" ]] && echo -e "${yellow}提示: 云安全组中 TCP $port 的放行规则如不再需要, 请手动删除${re}"
}

show_hy2_info() {
  [[ -f "$HY2_CONF" ]] || return 0
  local port passwd
  port=$(sed -n 's/^listen: :\([0-9][0-9]*\).*/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  passwd=$(sed -n 's/^  password: "\(.*\)"$/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  CFG_UP_MBPS=$(sed -n 's/^  up: \([0-9][0-9]*\) mbps$/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  CFG_DOWN_MBPS=$(sed -n 's/^  down: \([0-9][0-9]*\) mbps$/\1/p' "$HY2_CONF" 2>/dev/null | head -1)
  if [[ -z "$port" || -z "$passwd" ]]; then
    echo -e "${red}Hysteria2 配置解析失败${re}"
    return 0
  fi
  get_ip
  print_links "$port" "$passwd"
}

show_reality_info() {
  [[ -f "$XRAY_CONF" ]] || return 0
  local xray_bin="/usr/local/bin/xray"
  if [[ ! -x "$xray_bin" ]]; then
    echo -e "${red}xray 程序缺失, 无法显示 Reality 节点信息${re}"
    return 0
  fi
  local port uuid sni privkey shortid pubkey
  port=$(grep -o '"port": [0-9][0-9]*' "$XRAY_CONF" 2>/dev/null | head -1 | grep -o '[0-9][0-9]*' || true)
  uuid=$(grep -o '"id": "[^"]*"' "$XRAY_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)
  sni=$(grep -o '"serverNames": \["[^"]*"\]' "$XRAY_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)
  privkey=$(grep -o '"privateKey": "[^"]*"' "$XRAY_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)
  shortid=$(grep -o '"shortIds": \["[^"]*"\]' "$XRAY_CONF" 2>/dev/null | head -1 | cut -d'"' -f4 || true)
  if [[ -z "$port" || -z "$uuid" || -z "$privkey" ]]; then
    echo -e "${red}Reality 配置解析失败${re}"
    return 0
  fi
  pubkey=$("$xray_bin" x25519 -i "$privkey" 2>/dev/null | awk -F': *' 'tolower($0)~/public/{print $2; exit}' | awk '{print $1}')
  [[ -z "$pubkey" ]] && pubkey=$("$xray_bin" x25519 -i "$privkey" 2>/dev/null | tr -d '\r' | awk '{print $NF}')
  if [[ -z "$pubkey" ]]; then
    echo -e "${red}从私钥推导公钥失败${re}"
    return 0
  fi
  get_ip
  local ip="$HOST_IP" tag="Reality-${HOST_IP}"
  if [[ "$ip" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
    echo -e "${yellow}检测到内网 IP ($ip), 疑似 NAT 机器: 下方链接请把 IP 手动替换为公网 IP${re}"
  fi
  local url="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pubkey}&sid=${shortid}&type=tcp&headerType=none#${tag}"
  echo ""
  echo -e "${green}========== Reality 节点信息 ==========${re}"
  echo -e "\e[1;36m${url}\e[0m"
  echo ""
  if command -v qrencode &>/dev/null; then
    qrencode -t ANSIUTF8 -m 2 -o - "$url" || true
    echo ""
  fi
  echo "--- Clash / Mihomo 配置片段 ---"
  echo "- name: ${tag}"
  echo "  type: vless"
  echo "  server: ${ip}"
  echo "  port: ${port}"
  echo "  uuid: ${uuid}"
  echo "  network: tcp"
  echo "  tls: true"
  echo "  udp: true"
  echo "  flow: xtls-rprx-vision"
  echo "  servername: ${sni}"
  echo "  client-fingerprint: chrome"
  echo "  reality-opts:"
  echo "    public-key: ${pubkey}"
  echo "    short-id: ${shortid}"
  echo ""
}

show_node_info() {
  local found=0
  if [[ -f "$HY2_CONF" ]]; then found=1; show_hy2_info; fi
  if [[ -f "$XRAY_CONF" ]]; then found=1; show_reality_info; fi
  [[ "$found" == "1" ]] || echo -e "${yellow}尚未安装任何协议${re}"
}

# ============================================================================
# 菜单与分发
# ============================================================================
INSTALL_ARGS=()
for arg in "$@"; do
  case "$arg" in
    hy2|reality|uninstall-hy2|uninstall-reality|show) MODE="$arg" ;;
    *) INSTALL_ARGS+=("$arg") ;;
  esac
done

INTERACTIVE=0
[[ "$MODE" == "ask" ]] && INTERACTIVE=1

while true; do
if [[ "$MODE" == "ask" ]]; then
  detect_status
  echo ""
  echo -e "${green}======== HY2 / Reality 管理 (总统开发) ========${re}"
  echo -e "  Hysteria2: ${skyblue}${HY2_STATE}${HY2_DETAIL:+ ($HY2_DETAIL)}${re}"
  echo -e "  Reality:   ${skyblue}${RE_STATE}${RE_DETAIL:+ ($RE_DETAIL)}${re}"
  echo ""
  echo "  1) 安装 Hysteria2  (自动测速调优) [重装会覆盖已有安装]"
  echo "  2) 安装 Reality    (VLESS + Reality) [重装会覆盖已有安装]"
  echo "  3) 查看已安装节点信息"
  echo "  4) 卸载 Hysteria2"
  echo "  5) 卸载 Reality"
  echo "  0) 退出"
  echo -e "${green}====================================${re}"
  echo -e "  ${yellow}提示：按 README 设置快捷命令后，下次直接输入 hy2 即可进入本菜单${re}"
  read -r -p "输入序号 [1/2/3/4/5/0]: " _c </dev/tty
  case "$_c" in
    1) MODE=hy2 ;;
    2) MODE=reality ;;
    3) MODE=show ;;
    4) MODE=uninstall-hy2 ;;
    5) MODE=uninstall-reality ;;
    0) echo "已退出"; exit 0 ;;
    *) die "无效选择" ;;
  esac
fi

case "$MODE" in
  hy2)               run_hy2 "${INSTALL_ARGS[@]}" ;;
  reality)           run_reality ;;
  uninstall-hy2)     uninstall_hy2 ;;
  uninstall-reality) uninstall_reality ;;
  show)              show_node_info ;;
  *)                 die "MODE 非法: $MODE (可选 ask/hy2/reality/uninstall-hy2/uninstall-reality/show)" ;;
esac

[[ "$INTERACTIVE" == "1" ]] || break
echo ""
read -n1 -s -r -p "按任意键返回主菜单... " _dummy </dev/tty
echo ""
MODE=ask
done
)
