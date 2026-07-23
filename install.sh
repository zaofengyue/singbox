#!/bin/bash
# 这个脚本用到了大量 bash 专属语法（local / [[ / 字符串切片 / read -p 等），
# 如果是被 `sh install.sh` 直接跑起来的（Alpine 默认 /bin/sh 是 ash，不支持这些），
# 这里会自动尝试用 bash 重新执行自己；如果连 bash 都没有，就给出明确提示而不是
# 跑到一半在某个 bash 专属语法上报出一堆看不懂的语法错误。
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  else
    echo "本脚本需要 bash 才能运行，当前系统未检测到 bash。"
    if command -v apk >/dev/null 2>&1; then
      echo "Alpine 用户请先执行: apk add --no-cache bash   然后重新运行本脚本"
    elif command -v apt-get >/dev/null 2>&1; then
      echo "Debian/Ubuntu 用户请先执行: apt-get install -y bash   然后重新运行本脚本"
    fi
    exit 1
  fi
fi

set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${YELLOW}========== singbox 安装 ==========${NC}"

# 极简发行版（典型如 Alpine）可能连 curl/tar/openssl 都没预装，
# 尝试用 apk/apt 自动补齐，装不上就明确报错，而不是让后面莫名其妙地失败。
_bootstrap_deps() {
  _missing=""
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || _missing="$_missing curl"
  command -v tar     >/dev/null 2>&1 || _missing="$_missing tar"
  command -v openssl >/dev/null 2>&1 || _missing="$_missing openssl"
  [ -z "$_missing" ] && return 0

  echo -e "${YELLOW}检测到缺少依赖:${_missing}${NC}"
  if command -v apk >/dev/null 2>&1; then
    echo -e "${YELLOW}检测到 Alpine (apk)，尝试自动安装...${NC}"
    if [ "$(id -u)" = "0" ]; then
      apk add --no-cache $_missing >/dev/null 2>&1 || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo apk add --no-cache $_missing >/dev/null 2>&1 || true
    fi
  elif command -v apt-get >/dev/null 2>&1; then
    echo -e "${YELLOW}检测到 Debian/Ubuntu (apt)，尝试自动安装...${NC}"
    if [ "$(id -u)" = "0" ]; then
      apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq $_missing >/dev/null 2>&1 || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq $_missing >/dev/null 2>&1 || true
    fi
  fi

  _still_missing=""
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || _still_missing="$_still_missing curl/wget"
  command -v tar     >/dev/null 2>&1 || _still_missing="$_still_missing tar"
  if [ -n "$_still_missing" ]; then
    echo -e "${RED}以下依赖仍然缺失，无法继续:${_still_missing}${NC}"
    echo -e "${RED}Alpine 请手动执行: apk add --no-cache curl tar openssl${NC}"
    echo -e "${RED}Debian/Ubuntu 请手动执行: apt-get install -y curl tar openssl${NC}"
    exit 1
  fi
  # openssl 缺失不阻断安装：singbox.sh 里有内置的共享自签证书兜底
  command -v openssl >/dev/null 2>&1 || echo -e "${YELLOW}openssl 仍然缺失，HY2/TUIC/Trojan/AnyTLS 将使用内置的共享自签证书${NC}"
}
_bootstrap_deps

if command -v curl >/dev/null 2>&1; then
  DL="curl -sL"; DL_O="-o"
elif command -v wget >/dev/null 2>&1; then
  DL="wget -q"; DL_O="-O"
else
  echo -e "${RED}缺少 curl 或 wget${NC}"; exit 1
fi

APP_DIR="$HOME/singbox"
mkdir -p "$APP_DIR" && cd "$APP_DIR"

BASE_URL="https://raw.githubusercontent.com/zaofengyue/singbox/main"
echo -e "${GREEN}正在拉取源码...${NC}"
$DL "$BASE_URL/singbox.sh" $DL_O singbox.sh
chmod +x singbox.sh
echo -e "${GREEN}文件拉取完成${NC}"

# ── 环境变量收集 ──────────────────────────────────────────────────────────────
INPUT_UUID="${UUID:-}"
INPUT_PORT="${PORT:-}"
INPUT_ARGO_PORT="${ARGO_PORT:-}"
INPUT_NAME="${NAME:-}"
INPUT_ARGO_DOMAIN="${ARGO_DOMAIN:-}"
INPUT_ARGO_AUTH="${ARGO_AUTH:-}"
INPUT_DISABLE_ARGO="${DISABLE_ARGO:-}"
INPUT_HY2_PORT="${HY2_PORT:-}"
INPUT_TUIC_PORT="${TUIC_PORT:-}"
INPUT_REALITY_PORT="${REALITY_PORT:-}"
INPUT_REALITY_DOMAIN="${REALITY_DOMAIN:-}"
INPUT_SS_PORT="${SS_PORT:-}"
INPUT_SOCKS5_PORT="${SOCKS5_PORT:-}"
INPUT_TROJAN_PORT="${TROJAN_PORT:-}"
INPUT_ANYTLS_PORT="${ANYTLS_PORT:-}"

HAS_ENV=false
for v in "$INPUT_UUID" "$INPUT_PORT" "$INPUT_ARGO_PORT" "$INPUT_NAME" \
          "$INPUT_ARGO_DOMAIN" "$INPUT_ARGO_AUTH" "$INPUT_DISABLE_ARGO" \
          "$INPUT_HY2_PORT" "$INPUT_TUIC_PORT" "$INPUT_REALITY_PORT" \
          "$INPUT_REALITY_DOMAIN" "$INPUT_SS_PORT" "$INPUT_SOCKS5_PORT" \
          "$INPUT_TROJAN_PORT" "$INPUT_ANYTLS_PORT"; do
  [ -n "$v" ] && HAS_ENV=true && break
done

if ! $HAS_ENV; then
  echo ""
  echo -e "${YELLOW}========== 基础配置 ==========${NC}"

  read -p "UUID（留空自动生成）: "              INPUT_UUID
  read -p "NAME/节点名称前缀（留空自动识别）: " INPUT_NAME

  echo ""
  echo -e "${YELLOW}--- Argo 隧道 ---${NC}"
  read -p "是否启用 Argo 隧道？[Y/n]: " _ARGO_CHOICE
  _ARGO_CHOICE="$(echo "$_ARGO_CHOICE" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if [ "$_ARGO_CHOICE" = "n" ]; then
    INPUT_DISABLE_ARGO="true"
    echo -e "${YELLOW}Argo 已禁用${NC}"
  else
    INPUT_DISABLE_ARGO=""
    echo -e "${GREEN}Argo 已启用（临时隧道），如需固定隧道可通过管理面板 sb 配置${NC}"
  fi

  echo ""
  echo -e "${YELLOW}--- 可选协议（留空跳过）---${NC}"
  echo -e "  ${GREEN}a${NC}. Hysteria2    (UDP)"
  echo -e "  ${GREEN}b${NC}. TUIC v5      (UDP)"
  echo -e "  ${GREEN}c${NC}. VLESS Reality(TCP)"
  echo -e "  ${GREEN}d${NC}. Shadowsocks  (TCP)"
  echo -e "  ${GREEN}e${NC}. SOCKS5       (TCP/UDP)"
  echo -e "  ${GREEN}f${NC}. Trojan       (TCP)"
  echo -e "  ${GREEN}g${NC}. AnyTLS       (TCP)"
  read -p "选择协议（如 ac 表示启用 a 和 c，留空跳过）: " _PROTO_CHOICE

  if echo "$_PROTO_CHOICE" | grep -qi "a"; then
    read -p "HY2_PORT/Hysteria2 端口(UDP): " INPUT_HY2_PORT
    INPUT_HY2_PORT="$(echo "$INPUT_HY2_PORT" | tr -d '[:space:]')"
  fi

  if echo "$_PROTO_CHOICE" | grep -qi "b"; then
    read -p "TUIC_PORT/TUIC v5 端口(UDP): " INPUT_TUIC_PORT
    INPUT_TUIC_PORT="$(echo "$INPUT_TUIC_PORT" | tr -d '[:space:]')"
  fi

  if echo "$_PROTO_CHOICE" | grep -qi "c"; then
    read -p "REALITY_PORT/VLESS Reality 端口(TCP): " INPUT_REALITY_PORT
    INPUT_REALITY_PORT="$(echo "$INPUT_REALITY_PORT" | tr -d '[:space:]')"
    read -p "REALITY_DOMAIN/Reality 伪装域名（留空默认 www.iij.ad.jp）: " INPUT_REALITY_DOMAIN
    INPUT_REALITY_DOMAIN="$(echo "$INPUT_REALITY_DOMAIN" | tr -d '[:space:]')"
  fi

  if echo "$_PROTO_CHOICE" | grep -qi "d"; then
    read -p "SS_PORT/Shadowsocks 端口(TCP): " INPUT_SS_PORT
    INPUT_SS_PORT="$(echo "$INPUT_SS_PORT" | tr -d '[:space:]')"
  fi

  if echo "$_PROTO_CHOICE" | grep -qi "e"; then
    read -p "SOCKS5_PORT/SOCKS5 端口(TCP/UDP): " INPUT_SOCKS5_PORT
    INPUT_SOCKS5_PORT="$(echo "$INPUT_SOCKS5_PORT" | tr -d '[:space:]')"
  fi

  if echo "$_PROTO_CHOICE" | grep -qi "f"; then
    read -p "TROJAN_PORT/Trojan 端口(TCP): " INPUT_TROJAN_PORT
    INPUT_TROJAN_PORT="$(echo "$INPUT_TROJAN_PORT" | tr -d '[:space:]')"
  fi

  if echo "$_PROTO_CHOICE" | grep -qi "g"; then
    read -p "ANYTLS_PORT/AnyTLS 端口(TCP): " INPUT_ANYTLS_PORT
    INPUT_ANYTLS_PORT="$(echo "$INPUT_ANYTLS_PORT" | tr -d '[:space:]')"
  fi
fi

# ── 快捷命令目录 ──────────────────────────────────────────────────────────────
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"

# ── sb 管理面板 ───────────────────────────────────────────────────────────────
cat > "$LOCAL_BIN/sb" << 'SBMANAGER'
#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
GRAY='\033[0;90m'
WHITE='\033[0;97m'
RESET='\033[0m'

APP_DIR="$HOME/singbox"
STATE_DIR="$APP_DIR/state"
ACME_HOME="$STATE_DIR/acme.sh"
DOMAIN_CERT_DIR="$STATE_DIR/domain-certs"
WRAPPER="$APP_DIR/start.sh"
SUB_FILE="$APP_DIR/sub.txt"
LOG_FILE="$APP_DIR/run.log"
SB_BIN_PATH="/tmp/sb-bin/singbox/sing-box"
OUTBOUND_FILE="$STATE_DIR/outbound.conf"
SVCFILE="$HOME/.config/systemd/user/singbox.service"

get_val() {
  grep "^export $1=" "$WRAPPER" 2>/dev/null | sed 's/.*="\(.*\)"/\1/' | head -1
}

set_val() {
  local key="$1" val="$2"
  if grep -q "^export $key=" "$WRAPPER" 2>/dev/null; then
    sed -i "s|^export $key=.*|export $key=\"$val\"|" "$WRAPPER"
  else
    sed -i "/^cd /i export $key=\"$val\"" "$WRAPPER"
  fi
  # 同步到 systemd 单元：systemd 直接执行 singbox.sh 并从 unit 的 Environment= 读变量，
  # 不会去读 start.sh，之前这里没同步导致 systemd 托管模式下面板改配置实际不生效。
  if [ -f "$SVCFILE" ]; then
    if grep -q "^Environment=$key=" "$SVCFILE" 2>/dev/null; then
      sed -i "s|^Environment=$key=.*|Environment=$key=$val|" "$SVCFILE"
    else
      sed -i "/^\[Install\]/i Environment=$key=$val" "$SVCFILE"
    fi
    systemctl --user daemon-reload 2>/dev/null || true
  fi
}

check_status() {
  local sb_s cf_s
  pgrep -f "sing-box" >/dev/null 2>&1    && sb_s="${GREEN}sing-box ✓${RESET}"    || sb_s="${RED}sing-box ✗${RESET}"
  pgrep -f "cloudflared" >/dev/null 2>&1 && cf_s="${GREEN}cloudflared ✓${RESET}" || cf_s="${RED}cloudflared ✗${RESET}"
  echo -e "状态: $sb_s  $cf_s"
}

restart_service() {
  echo -e "${YELLOW}正在重启服务...${RESET}"
  pkill -f "singbox/singbox.sh" 2>/dev/null || true
  pkill -f "sing-box"              2>/dev/null || true
  pkill -f "cloudflared"           2>/dev/null || true
  sleep 1
  if systemctl --user is-enabled singbox >/dev/null 2>&1; then
    systemctl --user restart singbox
  else
    bash "$WRAPPER"
  fi
  echo -e "${GREEN}服务已重启${RESET}"
  sleep 2
}

press_any_key() {
  echo ""
  echo -e "${GRAY}按回车键返回...${RESET}"
  read -r
}

# ── 主菜单 ────────────────────────────────────────────────────────────────────
main_menu() {
  while true; do
    clear
    echo -e "${GREEN}======= singbox 管理面板 =======${RESET}"
    check_status
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}1. 查看节点订阅${RESET}"
    echo -e "${WHITE}2. 查看运行日志${RESET}"
    echo -e "${WHITE}3. 修改配置${RESET}"
    echo -e "${WHITE}4. 重启服务${RESET}"
    echo -e "${WHITE}5. 更新 sing-box${RESET}"
    echo -e "${WHITE}6. 彻底删除${RESET}"
    echo -e "${WHITE}7. 自定义出口${RESET}"
    echo -e "${WHITE}8. 域名证书${RESET}"
    echo -e "${WHITE}0. 退出${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -ne "${GRAY}请输入选项: ${RESET}"
    read -r opt
    case "$opt" in
      1) menu_sub ;;
      2) menu_log ;;
      3) menu_config ;;
      4) restart_service ;;
      5) menu_update ;;
      6) menu_delete ;;
      7) menu_outbound ;;
      8) menu_domain_cert ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

# ── 查看节点订阅 ──────────────────────────────────────────────────────────────
menu_sub() {
  clear
  echo -e "${GREEN}======= 节点订阅 =======${RESET}"

  if [ ! -f "$SUB_FILE" ]; then
    echo -e "${RED}sub.txt 不存在，请等待服务启动完成${RESET}"
    press_any_key; return
  fi

  local decoded
  decoded=$(base64 -d < "$SUB_FILE" 2>/dev/null)
  if [ -z "$decoded" ]; then
    echo -e "${RED}订阅内容为空${RESET}"
    press_any_key; return
  fi

  echo -e "${GRAY}已启用协议:${RESET}"
  echo "$decoded" | while IFS= read -r line; do
    case "$line" in
      vmess://*)      echo -e "${GREEN}  ✓ VMess + WS + Argo TLS${RESET}" ;;
      hysteria2://*)  echo -e "${GREEN}  ✓ Hysteria2${RESET}" ;;
      tuic://*)       echo -e "${GREEN}  ✓ TUIC v5${RESET}" ;;
      vless://*)      echo -e "${GREEN}  ✓ VLESS Reality${RESET}" ;;
      ss://*)         echo -e "${GREEN}  ✓ Shadowsocks${RESET}" ;;
      socks5://*)     echo -e "${GREEN}  ✓ SOCKS5${RESET}" ;;
      trojan://*)     echo -e "${GREEN}  ✓ Trojan${RESET}" ;;
      anytls://*)     echo -e "${GREEN}  ✓ AnyTLS${RESET}" ;;
    esac
  done

  echo -e "${GRAY}--------------------------------${RESET}"
  echo -e "${GRAY}节点链接:${RESET}"
  echo "$decoded" | while IFS= read -r line; do
    [ -n "$line" ] && echo -e "${CYAN}$line${RESET}"
  done

  press_any_key
}

# ── 查看运行日志 ──────────────────────────────────────────────────────────────
menu_log() {
  clear
  echo -e "${GREEN}======= 运行日志（Ctrl+C 退出）=======${RESET}"
  echo ""
  if systemctl --user is-active singbox >/dev/null 2>&1; then
    journalctl --user -u singbox -n 50 -f
  elif [ -f "$LOG_FILE" ]; then
    tail -n 50 -f "$LOG_FILE"
  else
    echo -e "${RED}未找到日志文件${RESET}"
    press_any_key
  fi
}

# ── 修改配置二级菜单 ──────────────────────────────────────────────────────────
menu_config() {
  while true; do
    clear
    echo -e "${GREEN}======= 修改配置 =======${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}1. UUID${RESET}"
    echo -e "${WHITE}2. Argo 隧道模式${RESET}"
    echo -e "${WHITE}3. 可选协议端口${RESET}"
    echo -e "${WHITE}4. 协议证书绑定${RESET}"
    echo -e "${WHITE}0. 返回${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -ne "${GRAY}请输入选项: ${RESET}"
    read -r opt
    case "$opt" in
      1) config_uuid ;;
      2) config_argo ;;
      3) config_proto ;;
      4) config_cert_bind ;;
      0) return ;;
      *) ;;
    esac
  done
}

# ── 修改 UUID ─────────────────────────────────────────────────────────────────
config_uuid() {
  clear
  echo -e "${GREEN}======= 修改 UUID =======${RESET}"
  local cur
  cur=$(get_val UUID)
  echo -e "${GRAY}当前: ${CYAN}${cur:-未设置}${RESET}"
  echo -e "${GRAY}--------------------------------${RESET}"
  echo -e "${WHITE}新 UUID（留空自动生成，回车确认）:${RESET}"
  echo -ne "${CYAN}"
  read -r new_uuid
  echo -ne "${RESET}"

  if [ -z "$new_uuid" ]; then
    new_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8$9}')
  fi

  echo ""
  echo -e "${YELLOW}⚠ 修改后将自动:${RESET}"
  echo -e "${YELLOW}  · 删除 reality-keys.txt 重新生成密钥${RESET}"
  echo -e "${YELLOW}  · 重启所有服务${RESET}"
  echo -e "${YELLOW}  · 更新订阅链接${RESET}"
  echo ""
  echo -e "${GRAY}新 UUID: ${CYAN}$new_uuid${RESET}"
  echo -ne "${GRAY}确认修改并重启? [y/N]: ${RESET}"
  read -r confirm
  if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    set_val UUID "$new_uuid"
    rm -f "$STATE_DIR/reality-keys.txt"
    restart_service
    echo -e "${GREEN}UUID 已更新${RESET}"
    press_any_key
  fi
}

# ── Argo 隧道模式 ─────────────────────────────────────────────────────────────
config_argo() {
  while true; do
    clear
    echo -e "${GREEN}======= Argo 隧道模式 =======${RESET}"
    local cur_domain cur_auth cur_port cur_disable
    cur_domain=$(get_val ARGO_DOMAIN)
    cur_auth=$(get_val ARGO_AUTH)
    cur_port=$(get_val ARGO_PORT)
    cur_disable=$(get_val DISABLE_ARGO)

    if [ "$cur_disable" = "true" ]; then
      echo -e "${GRAY}当前: ${RED}已禁用${RESET}"
    elif [ -n "$cur_domain" ] && [ -n "$cur_auth" ]; then
      echo -e "${GRAY}当前: ${CYAN}固定隧道 ($cur_domain)${RESET}"
    else
      echo -e "${GRAY}当前: ${CYAN}临时隧道${RESET}"
    fi

    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}1. 临时隧道（自动获取域名）${RESET}"
    echo -e "${WHITE}2. 固定隧道${RESET}"
    echo -e "${WHITE}3. 禁用 Argo${RESET}"
    echo -e "${WHITE}0. 返回${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -ne "${GRAY}请输入选项: ${RESET}"
    read -r opt

    case "$opt" in
      1)
        echo -ne "${GRAY}确认切换为临时隧道并重启? [y/N]: ${RESET}"
        read -r confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
          set_val ARGO_DOMAIN ""
          set_val ARGO_AUTH ""
          set_val DISABLE_ARGO ""
          restart_service
          press_any_key
        fi
        ;;
      2)
        echo ""
        echo -e "${GRAY}→ 固定隧道配置:${RESET}"
        echo -ne "${WHITE}ARGO_DOMAIN [当前: ${CYAN}${cur_domain:-空}${WHITE}]: ${RESET}"
        read -r new_domain
        echo -ne "${WHITE}ARGO_AUTH   [当前: ${CYAN}${cur_auth:0:12}...${WHITE}]: ${RESET}"
        read -r new_auth
        echo -ne "${WHITE}ARGO_PORT   [当前: ${CYAN}${cur_port:-8001}${WHITE}]: ${RESET}"
        read -r new_port
        new_domain="${new_domain:-$cur_domain}"
        new_auth="${new_auth:-$cur_auth}"
        new_port="${new_port:-${cur_port:-8001}}"
        echo ""
        echo -ne "${GRAY}确认修改并重启? [y/N]: ${RESET}"
        read -r confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
          set_val ARGO_DOMAIN "$new_domain"
          set_val ARGO_AUTH "$new_auth"
          set_val ARGO_PORT "$new_port"
          set_val DISABLE_ARGO ""
          restart_service
          press_any_key
        fi
        ;;
      3)
        echo -ne "${GRAY}确认禁用 Argo 并重启? [y/N]: ${RESET}"
        read -r confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
          set_val DISABLE_ARGO "true"
          set_val ARGO_DOMAIN ""
          set_val ARGO_AUTH ""
          restart_service
          press_any_key
        fi
        ;;
      0) return ;;
      *) ;;
    esac
  done
}

# ── 可选协议端口 ──────────────────────────────────────────────────────────────
config_proto() {
  while true; do
    clear
    echo -e "${GREEN}======= 可选协议端口 =======${RESET}"
    local hy2 tuic reality reality_domain ss socks5 trojan anytls
    hy2=$(get_val HY2_PORT)
    tuic=$(get_val TUIC_PORT)
    reality=$(get_val REALITY_PORT)
    reality_domain=$(get_val REALITY_DOMAIN)
    ss=$(get_val SS_PORT)
    socks5=$(get_val SOCKS5_PORT)
    trojan=$(get_val TROJAN_PORT)
    anytls=$(get_val ANYTLS_PORT)

    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}1. Hysteria2    (UDP) [${CYAN}${hy2:-未启用}${WHITE}]${RESET}"
    echo -e "${WHITE}2. TUIC         (UDP) [${CYAN}${tuic:-未启用}${WHITE}]${RESET}"
    echo -e "${WHITE}3. VLESS Reality(TCP) [${CYAN}${reality:-未启用}${WHITE}]${RESET}"
    echo -e "${WHITE}4. Reality 伪装域名   [${CYAN}${reality_domain:-www.iij.ad.jp}${WHITE}]${RESET}"
    echo -e "${WHITE}5. Shadowsocks  (TCP) [${CYAN}${ss:-未启用}${WHITE}]${RESET}"
    echo -e "${WHITE}6. SOCKS5  (TCP/UDP)  [${CYAN}${socks5:-未启用}${WHITE}]${RESET}"
    echo -e "${WHITE}7. Trojan       (TCP) [${CYAN}${trojan:-未启用}${WHITE}]${RESET}"
    echo -e "${WHITE}8. AnyTLS       (TCP) [${CYAN}${anytls:-未启用}${WHITE}]${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}0. 确认并重启${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -ne "${GRAY}请输入选项: ${RESET}"
    read -r opt

    _set_port() {
      local key="$1" cur="$2" proto="$3"
      echo -ne "${GRAY}${key}（留空禁用）[当前: ${CYAN}${cur:-未启用}${GRAY}]: ${RESET}"
      read -r val
      val="$(echo "$val" | tr -d '[:space:]')"
      if [ -z "$val" ]; then
        set_val "$key" ""
        echo -e "${YELLOW}${proto} 已禁用${RESET}"
      else
        set_val "$key" "$val"
        echo -e "${GREEN}已更新为: $val${RESET}"
      fi
      sleep 1
    }

    case "$opt" in
      1) _set_port HY2_PORT     "$hy2"     "Hysteria2" ;;
      2) _set_port TUIC_PORT    "$tuic"    "TUIC" ;;
      3) _set_port REALITY_PORT "$reality" "VLESS Reality" ;;
      4)
        echo -ne "${GRAY}REALITY_DOMAIN [当前: ${CYAN}${reality_domain:-www.iij.ad.jp}${GRAY}]: ${RESET}"
        read -r val
        val="$(echo "$val" | tr -d '[:space:]')"
        if [ -n "$val" ]; then
          set_val REALITY_DOMAIN "$val"
          rm -f "$STATE_DIR/reality-keys.txt"
          echo -e "${GREEN}已更新为: $val，Reality 密钥已清除，重启后重新生成${RESET}"
        fi
        sleep 1
        ;;
      5) _set_port SS_PORT     "$ss"     "Shadowsocks" ;;
      6) _set_port SOCKS5_PORT "$socks5" "SOCKS5" ;;
      7) _set_port TROJAN_PORT "$trojan" "Trojan" ;;
      8) _set_port ANYTLS_PORT "$anytls" "AnyTLS" ;;
      0)
        echo -ne "${GRAY}确认修改并重启? [y/N]: ${RESET}"
        read -r confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
          restart_service
        fi
        return
        ;;
      *) ;;
    esac
  done
}

# ── 协议证书绑定 ──────────────────────────────────────────────────────────────
# 把某个已经用 acme.sh 申请好的域名证书，绑定给某个支持 TLS 的协议使用，
# 替代默认的共享自签证书。只处理当前已启用（配了端口）的协议。
_list_domain_certs() {
  # 输出已签发的域名列表，每行一个
  [ -d "$DOMAIN_CERT_DIR" ] || return 0
  for d in "$DOMAIN_CERT_DIR"/*/; do
    [ -d "$d" ] || continue
    dom="$(basename "$d")"
    [ -f "$d/cert.pem" ] && [ -f "$d/key.pem" ] && echo "$dom"
  done
}

config_cert_bind() {
  while true; do
    clear
    echo -e "${GREEN}======= 协议证书绑定 =======${RESET}"
    local hy2 tuic trojan anytls hy2_dom tuic_dom trojan_dom anytls_dom
    hy2=$(get_val HY2_PORT); tuic=$(get_val TUIC_PORT)
    trojan=$(get_val TROJAN_PORT); anytls=$(get_val ANYTLS_PORT)
    hy2_dom=$(get_val HY2_CERT_DOMAIN); tuic_dom=$(get_val TUIC_CERT_DOMAIN)
    trojan_dom=$(get_val TROJAN_CERT_DOMAIN); anytls_dom=$(get_val ANYTLS_CERT_DOMAIN)

    local avail
    avail="$(_list_domain_certs)"
    if [ -z "$avail" ]; then
      echo -e "${YELLOW}还没有已签发的域名证书，请先到主菜单「8. 域名证书」申请${RESET}"
      press_any_key
      return
    fi

    echo -e "${GRAY}可用域名证书: ${CYAN}$(echo "$avail" | tr '\n' ' ')${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    local shown=0
    if [ -n "$hy2" ]; then
      echo -e "${WHITE}1. Hysteria2  [${CYAN}${hy2_dom:-自签}${WHITE}]${RESET}"; shown=1
    fi
    if [ -n "$tuic" ]; then
      echo -e "${WHITE}2. TUIC       [${CYAN}${tuic_dom:-自签}${WHITE}]${RESET}"; shown=1
    fi
    if [ -n "$trojan" ]; then
      echo -e "${WHITE}3. Trojan     [${CYAN}${trojan_dom:-自签}${WHITE}]${RESET}"; shown=1
    fi
    if [ -n "$anytls" ]; then
      echo -e "${WHITE}4. AnyTLS     [${CYAN}${anytls_dom:-自签}${WHITE}]${RESET}"; shown=1
    fi
    if [ "$shown" = "0" ]; then
      echo -e "${YELLOW}当前没有已启用的 HY2/TUIC/Trojan/AnyTLS 协议，请先在「可选协议端口」里开启${RESET}"
      press_any_key
      return
    fi
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}0. 返回${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -ne "${GRAY}选择要绑定证书的协议: ${RESET}"
    read -r popt

    local key=""
    case "$popt" in
      1) [ -n "$hy2" ]    && key="HY2_CERT_DOMAIN" ;;
      2) [ -n "$tuic" ]   && key="TUIC_CERT_DOMAIN" ;;
      3) [ -n "$trojan" ] && key="TROJAN_CERT_DOMAIN" ;;
      4) [ -n "$anytls" ] && key="ANYTLS_CERT_DOMAIN" ;;
      0) return ;;
      *) continue ;;
    esac
    [ -z "$key" ] && continue

    echo ""
    echo -e "${GRAY}可选域名:${RESET}"
    local i=1
    local -a domlist
    domlist=()
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      echo -e "  ${GREEN}${i}${RESET}. $d"
      domlist+=("$d")
      i=$((i + 1))
    done <<< "$avail"
    echo -e "  ${GREEN}0${RESET}. 恢复自签证书"
    echo -ne "${GRAY}选择域名 [回车取消]: ${RESET}"
    read -r dopt
    [ -z "$dopt" ] && continue

    if [ "$dopt" = "0" ]; then
      set_val "$key" ""
      echo -e "${GREEN}已恢复为自签证书${RESET}"
    elif [ "$dopt" -ge 1 ] 2>/dev/null && [ "$dopt" -le "${#domlist[@]}" ] 2>/dev/null; then
      local chosen="${domlist[$((dopt - 1))]}"
      set_val "$key" "$chosen"
      echo -e "${GREEN}已绑定域名证书: $chosen${RESET}"
    else
      echo -e "${RED}无效选择${RESET}"
      sleep 1
      continue
    fi

    echo -ne "${GRAY}立即重启服务使其生效? [Y/n]: ${RESET}"
    read -r confirm
    if [ "$confirm" != "n" ] && [ "$confirm" != "N" ]; then
      restart_service
    fi
    press_any_key
  done
}

# ── 更新 sing-box ─────────────────────────────────────────────────────────────
menu_update() {
  clear
  echo -e "${GREEN}======= 更新 sing-box =======${RESET}"

  local cur_ver latest_ver
  if [ -f "$SB_BIN_PATH" ]; then
    cur_ver=$("$SB_BIN_PATH" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    echo -e "${GRAY}当前版本: ${CYAN}${cur_ver:-未知}${RESET}"
  else
    echo -e "${GRAY}当前版本: ${RED}未安装${RESET}"
  fi

  echo -e "${GRAY}正在获取最新版本...${RESET}"
  latest_ver=$(curl -sL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    | grep '"tag_name"' | sed 's/.*"tag_name": *"v\([^"]*\)".*/\1/' | head -1)
  echo -e "${GRAY}最新版本: ${GREEN}${latest_ver:+v}${latest_ver:-获取失败}${RESET}"

  echo -e "${GRAY}--------------------------------${RESET}"
  echo -e "${WHITE}1. 确认更新${RESET}"
  echo -e "${WHITE}0. 取消返回${RESET}"
  echo -e "${GRAY}--------------------------------${RESET}"
  echo -ne "${GRAY}请输入选项: ${RESET}"
  read -r opt

  if [ "$opt" = "1" ] && [ -n "$latest_ver" ]; then
    echo -e "${YELLOW}正在下载 sing-box v${latest_ver}...${RESET}"
    local arch
    case "$(uname -m)" in
      x86_64|amd64)  arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
      armv7*|armv6*) arch="armv7" ;;
      *)             arch="amd64" ;;
    esac
    local sb_dir="/tmp/sb-bin/singbox"
    mkdir -p "$sb_dir"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${latest_ver}/sing-box-${latest_ver}-linux-${arch}.tar.gz"
    curl -sL "$url" -o /tmp/sb_update.tar.gz \
      && tar -xzf /tmp/sb_update.tar.gz -C "$sb_dir" --strip-components=1 \
      && chmod +x "$SB_BIN_PATH" \
      && rm -f /tmp/sb_update.tar.gz \
      && echo -e "${GREEN}更新完成，正在重启...${RESET}" \
      && restart_service \
      || echo -e "${RED}更新失败${RESET}"
  fi
  press_any_key
}

# ── 自定义出口 ───────────────────────────────────────────────────
get_outbound_val() {
  grep "^$1=" "$OUTBOUND_FILE" 2>/dev/null | sed "s/^$1=//" | head -1
}

test_outbound() {
  local type="$1" addr="$2" port="$3" user="$4" pass="$5"
  [ "$type" = "socks" ] && type="socks5"
  local proxy_url=""
  if [ -n "$user" ]; then
    proxy_url="${type}://${user}:${pass}@${addr}:${port}"
  else
    proxy_url="${type}://${addr}:${port}"
  fi
  echo -e "${GRAY}正在测试连通性...${RESET}"
  local code
  code=$(curl -s --connect-timeout 5 -x "$proxy_url" https://www.google.com -o /dev/null -w "%{http_code}" 2>/dev/null)
  if [ "$code" = "200" ] || [ "$code" = "204" ] || [ "$code" = "301" ] || [ "$code" = "302" ]; then
    echo -e "${GREEN}✓ 连接测试成功 (HTTP $code)${RESET}"
    return 0
  else
    echo -e "${RED}✗ 连接测试失败或超时 (返回: ${code:-无响应})${RESET}"
    return 1
  fi
}

set_outbound() {
  local type="$1"
  echo ""
  echo -e "${GRAY}→ 设置 ${type} 出口:${RESET}"
  echo -ne "${WHITE}地址 (ADDR): ${RESET}"
  read -r addr
  echo -ne "${WHITE}端口 (PORT): ${RESET}"
  read -r port
  echo -ne "${WHITE}用户名（留空则无认证）: ${RESET}"
  read -r user
  local pass=""
  if [ -n "$user" ]; then
    echo -ne "${WHITE}密码: ${RESET}"
    read -r pass
  fi

  if [ -z "$addr" ] || [ -z "$port" ]; then
    echo -e "${RED}地址或端口不能为空，已取消${RESET}"
    sleep 1
    return
  fi

  echo ""
  if test_outbound "$type" "$addr" "$port" "$user" "$pass"; then
    echo -ne "${GRAY}测试通过，确认保存并重启? [y/N]: ${RESET}"
  else
    echo -e "${YELLOW}⚠ 测试未通过，但检测结果不一定准确${RESET}"
    echo -ne "${GRAY}仍然保存并重启? [y/N]: ${RESET}"
  fi
  read -r confirm
  if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    cat > "$OUTBOUND_FILE" << EOF
TYPE=${type}
ADDR=${addr}
PORT=${port}
USER=${user}
PASS=${pass}
EOF
    chmod 600 "$OUTBOUND_FILE" 2>/dev/null || true
    restart_service
    echo -e "${GREEN}出口已设置${RESET}"
    press_any_key
  else
    echo -e "${YELLOW}已取消${RESET}"
    sleep 1
  fi
}

menu_outbound() {
  while true; do
    clear
    echo -e "${GREEN}======= 自定义出口 =======${RESET}"
    local cur_type cur_addr cur_port
    cur_type=$(get_outbound_val TYPE)
    cur_addr=$(get_outbound_val ADDR)
    cur_port=$(get_outbound_val PORT)

    if [ -n "$cur_type" ] && [ "$cur_type" != "none" ]; then
      echo -e "${GRAY}当前: ${CYAN}${cur_type}://${cur_addr}:${cur_port}${RESET}"
    else
      echo -e "${GRAY}当前: ${CYAN}直连 (未启用自定义出口)${RESET}"
    fi

    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}1. 设置 SOCKS5 出口${RESET}"
    echo -e "${WHITE}2. 设置 HTTP 出口${RESET}"
    echo -e "${WHITE}3. 恢复直连${RESET}"
    echo -e "${WHITE}0. 返回${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -ne "${GRAY}请输入选项: ${RESET}"
    read -r opt

    case "$opt" in
      1) set_outbound socks ;;
      2) set_outbound http ;;
      3)
        echo -ne "${GRAY}确认恢复直连并重启? [y/N]: ${RESET}"
        read -r confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
          rm -f "$OUTBOUND_FILE"
          restart_service
          echo -e "${GREEN}已恢复直连${RESET}"
          press_any_key
        fi
        ;;
      0) return ;;
      *) ;;
    esac
  done
}

# ── 域名证书 (acme.sh) ────────────────────────────────────────────────────────
_port80_busy() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ':80 ' && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -q ':80 ' && return 0
  fi
  return 1
}

ensure_acme() {
  [ -x "$ACME_HOME/acme.sh" ] && return 0
  echo -e "${YELLOW}正在安装 acme.sh...${RESET}"
  mkdir -p "$STATE_DIR"
  local tmp_acme="/tmp/acme-install-$$"
  rm -rf "$tmp_acme"
  mkdir -p "$tmp_acme"
  if command -v curl >/dev/null 2>&1; then
    curl -sL https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh -o "$tmp_acme/acme.sh"
  elif command -v wget >/dev/null 2>&1; then
    wget -q https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh -O "$tmp_acme/acme.sh"
  fi
  if [ ! -s "$tmp_acme/acme.sh" ]; then
    echo -e "${RED}acme.sh 下载失败，请检查网络${RESET}"
    rm -rf "$tmp_acme"
    return 1
  fi
  chmod +x "$tmp_acme/acme.sh"
  # 没有 crontab 的话 acme.sh 的安装程序会直接拒绝安装（除非加 --force）。
  # 容器/部分极简 Alpine 环境经常没装 cron，这里探测一下并相应处理。
  local _install_out _has_cron=1
  command -v crontab >/dev/null 2>&1 || _has_cron=0
  if [ "$_has_cron" = "1" ]; then
    _install_out="$(cd "$tmp_acme" && ./acme.sh --install --home "$ACME_HOME" 2>&1)"
  else
    echo -e "${YELLOW}未检测到 crontab，将跳过自动续期定时任务的安装${RESET}"
    _install_out="$(cd "$tmp_acme" && ./acme.sh --install --home "$ACME_HOME" --force 2>&1)"
  fi
  rm -rf "$tmp_acme"
  if [ ! -x "$ACME_HOME/acme.sh" ]; then
    echo -e "${RED}acme.sh 安装失败：${RESET}"
    echo "$_install_out" | tail -10 | sed 's/^/    /'
    return 1
  fi
  if [ "$_has_cron" = "1" ]; then
    echo -e "${GREEN}acme.sh 安装完成（已自动注册续期定时任务）${RESET}"
  else
    echo -e "${GREEN}acme.sh 安装完成${RESET}"
    echo -e "${YELLOW}⚠ 没有自动续期任务，Let's Encrypt 证书 90 天过期，请记得定期回到本菜单手动续期${RESET}"
  fi
  return 0
}

issue_domain_cert() {
  ensure_acme || { press_any_key; return; }
  echo ""
  echo -ne "${WHITE}要签发证书的域名（需已解析到本机公网 IP）: ${RESET}"
  read -r domain
  domain="$(echo "$domain" | tr -d '[:space:]')"
  if [ -z "$domain" ]; then
    echo -e "${RED}域名不能为空${RESET}"
    sleep 1
    return
  fi
  if [ -f "$DOMAIN_CERT_DIR/$domain/cert.pem" ]; then
    echo -e "${YELLOW}该域名证书已存在，如需更新请用「续期」，或先「删除」再重新申请${RESET}"
    press_any_key
    return
  fi

  echo -e "${YELLOW}即将用 HTTP-01 standalone 方式申请 Let's Encrypt 证书，${RESET}"
  echo -e "${YELLOW}需要域名已解析到本机公网 IP，且 80 端口能被外网临时访问几秒钟。${RESET}"
  echo -ne "${GRAY}确认继续? [y/N]: ${RESET}"
  read -r confirm
  [ "$confirm" != "y" ] && [ "$confirm" != "Y" ] && return

  # sing-box 本身不占 80，但以防用户自己配置过什么监听在 80，这里先探测一下
  if _port80_busy; then
    echo -e "${YELLOW}⚠ 80 端口当前被占用，standalone 验证可能会失败。${RESET}"
    echo -ne "${GRAY}仍然继续? [y/N]: ${RESET}"
    read -r confirm2
    [ "$confirm2" != "y" ] && [ "$confirm2" != "Y" ] && return
  fi

  mkdir -p "$DOMAIN_CERT_DIR/$domain"
  echo -e "${YELLOW}正在申请证书，可能需要几十秒...${RESET}"
  if "$ACME_HOME/acme.sh" --home "$ACME_HOME" --issue -d "$domain" --standalone --httpport 80 --server letsencrypt --force; then
    "$ACME_HOME/acme.sh" --home "$ACME_HOME" --install-cert -d "$domain" \
      --key-file "$DOMAIN_CERT_DIR/$domain/key.pem" \
      --fullchain-file "$DOMAIN_CERT_DIR/$domain/cert.pem" \
      --reloadcmd "pkill -f 'sing-box run' 2>/dev/null || true" >/dev/null 2>&1
    chmod 600 "$DOMAIN_CERT_DIR/$domain/key.pem" 2>/dev/null || true
    if [ -f "$DOMAIN_CERT_DIR/$domain/cert.pem" ] && [ -f "$DOMAIN_CERT_DIR/$domain/key.pem" ]; then
      echo -e "${GREEN}证书申请成功: $domain${RESET}"
      echo -e "${GRAY}去「3. 修改配置 -> 4. 协议证书绑定」把它绑定给某个协议即可生效${RESET}"
    else
      echo -e "${RED}证书安装步骤失败，请检查上面的输出${RESET}"
      rm -rf "$DOMAIN_CERT_DIR/$domain"
    fi
  else
    echo -e "${RED}证书申请失败：常见原因是域名没有解析到本机，或 80 端口无法从公网访问（防火墙/云厂商安全组没放行）${RESET}"
    rm -rf "$DOMAIN_CERT_DIR/$domain"
  fi
  press_any_key
}

import_domain_cert() {
  echo ""
  echo -e "${GRAY}适用场景：域名没解析到本机 / 80 端口打不开 / 证书是别处签发的${RESET}"
  echo -ne "${WHITE}域名(仅作为标识，不会验证是否解析到本机): ${RESET}"
  read -r domain
  domain="$(echo "$domain" | tr -d '[:space:]')"
  [ -z "$domain" ] && { echo -e "${RED}域名不能为空${RESET}"; sleep 1; return; }
  echo -ne "${WHITE}证书文件路径(fullchain/cert .pem): ${RESET}"
  read -r cert_src
  echo -ne "${WHITE}私钥文件路径(key .pem): ${RESET}"
  read -r key_src
  if [ ! -f "$cert_src" ] || [ ! -f "$key_src" ]; then
    echo -e "${RED}文件不存在，请检查路径${RESET}"
    sleep 1
    return
  fi
  mkdir -p "$DOMAIN_CERT_DIR/$domain"
  cp "$cert_src" "$DOMAIN_CERT_DIR/$domain/cert.pem"
  cp "$key_src" "$DOMAIN_CERT_DIR/$domain/key.pem"
  chmod 600 "$DOMAIN_CERT_DIR/$domain/key.pem" 2>/dev/null || true
  echo -e "${GREEN}导入完成: $domain${RESET}"
  echo -e "${GRAY}注意：手动导入的证书不会被 acme.sh 自动续期，到期需要重新导入${RESET}"
  press_any_key
}

_pick_domain_cert() {
  # 交互式选一个已有域名，选中的值放进全局变量 _PICKED_DOMAIN
  local certs
  certs="$(_list_domain_certs)"
  if [ -z "$certs" ]; then
    echo -e "${YELLOW}还没有已签发/导入的域名证书${RESET}"
    press_any_key
    _PICKED_DOMAIN=""
    return 1
  fi
  local i=1
  local -a domlist
  domlist=()
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    echo -e "  ${GREEN}${i}${RESET}. $d"
    domlist+=("$d")
    i=$((i + 1))
  done <<< "$certs"
  echo -ne "${GRAY}选择 [回车取消]: ${RESET}"
  read -r popt
  if [ -z "$popt" ] || ! [ "$popt" -ge 1 ] 2>/dev/null || ! [ "$popt" -le "${#domlist[@]}" ] 2>/dev/null; then
    _PICKED_DOMAIN=""
    return 1
  fi
  _PICKED_DOMAIN="${domlist[$((popt - 1))]}"
  return 0
}

renew_domain_cert() {
  echo -e "${GRAY}选择要续期的域名:${RESET}"
  _pick_domain_cert || return
  local dom="$_PICKED_DOMAIN"
  if [ ! -x "$ACME_HOME/acme.sh" ]; then
    echo -e "${RED}未检测到 acme.sh，该证书可能是手动导入的，无法自动续期，请重新手动导入新证书${RESET}"
    press_any_key
    return
  fi
  echo -e "${YELLOW}正在续期 $dom ...${RESET}"
  "$ACME_HOME/acme.sh" --home "$ACME_HOME" --renew -d "$dom" --force --standalone --httpport 80
  "$ACME_HOME/acme.sh" --home "$ACME_HOME" --install-cert -d "$dom" \
    --key-file "$DOMAIN_CERT_DIR/$dom/key.pem" \
    --fullchain-file "$DOMAIN_CERT_DIR/$dom/cert.pem" \
    --reloadcmd "pkill -f 'sing-box run' 2>/dev/null || true" >/dev/null 2>&1
  chmod 600 "$DOMAIN_CERT_DIR/$dom/key.pem" 2>/dev/null || true
  echo -e "${GREEN}续期完成${RESET}"
  press_any_key
}

delete_domain_cert() {
  echo -e "${GRAY}选择要删除的域名:${RESET}"
  _pick_domain_cert || return
  local dom="$_PICKED_DOMAIN"
  echo -e "${YELLOW}⚠ 如果有协议正绑定这个域名证书，删除后该协议会在下次重启时自动回退为自签证书${RESET}"
  echo -ne "${GRAY}确认删除 $dom ? [y/N]: ${RESET}"
  read -r confirm
  if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    [ -x "$ACME_HOME/acme.sh" ] && "$ACME_HOME/acme.sh" --home "$ACME_HOME" --remove -d "$dom" >/dev/null 2>&1
    rm -rf "$DOMAIN_CERT_DIR/$dom"
    echo -e "${GREEN}已删除${RESET}"
  fi
  press_any_key
}

menu_domain_cert() {
  while true; do
    clear
    echo -e "${GREEN}======= 域名证书 (acme.sh) =======${RESET}"
    local certs
    certs="$(_list_domain_certs)"
    if [ -n "$certs" ]; then
      echo -e "${GRAY}已签发/导入证书:${RESET}"
      while IFS= read -r d; do
        [ -z "$d" ] && continue
        local exp=""
        if command -v openssl >/dev/null 2>&1 && [ -f "$DOMAIN_CERT_DIR/$d/cert.pem" ]; then
          exp="$(openssl x509 -enddate -noout -in "$DOMAIN_CERT_DIR/$d/cert.pem" 2>/dev/null | sed 's/notAfter=//')"
        fi
        echo -e "  ${CYAN}$d${RESET}  ${GRAY}${exp:+到期: $exp}${RESET}"
      done <<< "$certs"
    else
      echo -e "${GRAY}还没有已签发的域名证书${RESET}"
    fi
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}1. 申请新域名证书 (acme.sh 自动)${RESET}"
    echo -e "${WHITE}2. 手动导入已有证书${RESET}"
    echo -e "${WHITE}3. 续期指定证书${RESET}"
    echo -e "${WHITE}4. 删除证书${RESET}"
    echo -e "${WHITE}0. 返回${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -ne "${GRAY}请输入选项: ${RESET}"
    read -r opt
    case "$opt" in
      1) issue_domain_cert ;;
      2) import_domain_cert ;;
      3) renew_domain_cert ;;
      4) delete_domain_cert ;;
      0) return ;;
      *) ;;
    esac
  done
}

# ── 彻底删除 ──────────────────────────────────────────────────────────────────
menu_delete() {
  clear
  echo -e "${RED}======= 彻底删除 =======${RESET}"
  echo -e "${YELLOW}⚠ 将删除所有文件、进程和自启配置${RESET}"
  echo -e "${GRAY}--------------------------------${RESET}"
  echo -e "${WHITE}1. 确认删除${RESET}"
  echo -e "${WHITE}0. 取消返回${RESET}"
  echo -e "${GRAY}--------------------------------${RESET}"
  echo -ne "${GRAY}请输入选项: ${RESET}"
  read -r opt
  if [ "$opt" = "1" ]; then
    echo -ne "${RED}再次确认，输入 yes 继续: ${RESET}"
    read -r confirm
    if [ "$confirm" = "yes" ]; then
      sb-del
      exit 0
    fi
  fi
}

main_menu
SBMANAGER
chmod +x "$LOCAL_BIN/sb"

# ── sb-sub ────────────────────────────────────────────────────────────────────
cat > "$LOCAL_BIN/sb-sub" << SUBCMD
#!/bin/bash
SUB_FILE="\$HOME/singbox/sub.txt"
[ -f "\$SUB_FILE" ] && cat "\$SUB_FILE" || echo "sub.txt 不存在，请等待服务启动完成"
SUBCMD
chmod +x "$LOCAL_BIN/sb-sub"

# ── sb-log ────────────────────────────────────────────────────────────────────
cat > "$LOCAL_BIN/sb-log" << LOGCMD
#!/bin/bash
APP_DIR="\$HOME/singbox"
if systemctl --user is-active singbox >/dev/null 2>&1; then
  journalctl --user -u singbox -f
elif [ -f "\$APP_DIR/run.log" ]; then
  tail -f "\$APP_DIR/run.log"
else
  echo "服务未运行或日志不存在"
fi
LOGCMD
chmod +x "$LOCAL_BIN/sb-log"

# ── sb-del ────────────────────────────────────────────────────────────────────
cat > "$LOCAL_BIN/sb-del" << DELCMD
#!/bin/bash
echo "正在彻底删除 singbox..."
systemctl --user stop    singbox 2>/dev/null || true
systemctl --user disable singbox 2>/dev/null || true
rm -f "\$HOME/.config/systemd/user/singbox.service"
systemctl --user daemon-reload 2>/dev/null || true
pkill -f "singbox/singbox.sh" 2>/dev/null || true
pkill -f "sing-box"              2>/dev/null || true
pkill -f "cloudflared"           2>/dev/null || true
# 清理 cron 里的开机自启条目
(crontab -l 2>/dev/null | grep -v "singbox autostart") | crontab - 2>/dev/null || true
for RC in "\$HOME/.bashrc" "\$HOME/.profile" "\$HOME/.bash_profile" "\$HOME/.zshrc"; do
  sed -i '/# singbox/d'  "\$RC" 2>/dev/null || true
  sed -i '/singbox/d'    "\$RC" 2>/dev/null || true
done
[ -x "\$HOME/singbox/state/acme.sh/acme.sh" ] && "\$HOME/singbox/state/acme.sh/acme.sh" --uninstall >/dev/null 2>&1 || true
rm -rf "\$HOME/singbox"
rm -rf /tmp/sb-bin
rm -f "\$HOME/uuid.txt" "\$HOME/sb-config.json" "\$HOME/reality-keys.txt" "\$HOME/outbound.conf"
rm -rf "\$HOME/certs"
rm -f "$LOCAL_BIN/sb" "$LOCAL_BIN/sb-sub" "$LOCAL_BIN/sb-log" "$LOCAL_BIN/sb-del" "$LOCAL_BIN/sb-edit"
echo "删除完成"
DELCMD
chmod +x "$LOCAL_BIN/sb-del"

# ── sb-edit ───────────────────────────────────────────────────────────────────
cat > "$LOCAL_BIN/sb-edit" << 'EDITCMD'
#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

APP_DIR="$HOME/singbox"
WRAPPER="$APP_DIR/start.sh"

if [ ! -f "$WRAPPER" ]; then
  echo "未找到 $WRAPPER，请先运行安装脚本"
  exit 1
fi

get_val() {
  grep "^export $1=" "$WRAPPER" | sed 's/.*="\(.*\)"/\1/' | head -1
}

CUR_UUID=$(get_val UUID)
CUR_PORT=$(get_val PORT)
CUR_ARGO_PORT=$(get_val ARGO_PORT)
CUR_NAME=$(get_val NAME)
CUR_ARGO_DOMAIN=$(get_val ARGO_DOMAIN)
CUR_ARGO_AUTH=$(get_val ARGO_AUTH)
CUR_DISABLE_ARGO=$(get_val DISABLE_ARGO)
CUR_HY2_PORT=$(get_val HY2_PORT)
CUR_TUIC_PORT=$(get_val TUIC_PORT)
CUR_REALITY_PORT=$(get_val REALITY_PORT)
CUR_REALITY_DOMAIN=$(get_val REALITY_DOMAIN)
CUR_SS_PORT=$(get_val SS_PORT)
CUR_SOCKS5_PORT=$(get_val SOCKS5_PORT)
CUR_TROJAN_PORT=$(get_val TROJAN_PORT)
CUR_ANYTLS_PORT=$(get_val ANYTLS_PORT)

echo -e "${GREEN}========== singbox 配置修改 ==========${NC}"
echo -e "${YELLOW}直接回车保留当前值，输入新值后回车修改${NC}"
echo ""
echo -e "${YELLOW}--- 基础配置 ---${NC}"
read -p "UUID         [${CUR_UUID:-自动生成}]: "          IN_UUID
read -p "NAME         [${CUR_NAME:-自动识别}]: "          IN_NAME
echo ""
echo -e "${YELLOW}--- Argo 隧道 ---${NC}"
read -p "ARGO_DOMAIN  [${CUR_ARGO_DOMAIN:-临时隧道}]: "   IN_ARGO_DOMAIN
read -p "ARGO_AUTH    [${CUR_ARGO_AUTH:+已设置}]: "       IN_ARGO_AUTH
read -p "DISABLE_ARGO [${CUR_DISABLE_ARGO:-false}]: "     IN_DISABLE_ARGO
echo ""
echo -e "${YELLOW}--- 可选协议（直接回车保留当前值，输入空格清除）---${NC}"
read -p "HY2_PORT     [${CUR_HY2_PORT:-未启用}]: "        IN_HY2_PORT
read -p "TUIC_PORT    [${CUR_TUIC_PORT:-未启用}]: "       IN_TUIC_PORT
read -p "REALITY_PORT [${CUR_REALITY_PORT:-未启用}]: "    IN_REALITY_PORT
read -p "REALITY_DOMAIN [${CUR_REALITY_DOMAIN:-www.iij.ad.jp}]: " IN_REALITY_DOMAIN
read -p "SS_PORT      [${CUR_SS_PORT:-未启用}]: "         IN_SS_PORT
read -p "SOCKS5_PORT  [${CUR_SOCKS5_PORT:-未启用}]: "     IN_SOCKS5_PORT
read -p "TROJAN_PORT  [${CUR_TROJAN_PORT:-未启用}]: "     IN_TROJAN_PORT
read -p "ANYTLS_PORT  [${CUR_ANYTLS_PORT:-未启用}]: "     IN_ANYTLS_PORT

# 空格输入视为清空，直接回车保留原值
trim() { echo "$1" | tr -d '[:space:]'; }
NEW_UUID=$([ -n "$(trim "$IN_UUID")" ] && trim "$IN_UUID" || echo "$CUR_UUID")
NEW_PORT=$([ -n "$(trim "$IN_PORT")" ] && trim "$IN_PORT" || echo "$CUR_PORT")
NEW_NAME=$([ -n "$IN_NAME" ] && echo "$IN_NAME" || echo "$CUR_NAME")
NEW_ARGO_DOMAIN=$([ -n "$(trim "$IN_ARGO_DOMAIN")" ] && trim "$IN_ARGO_DOMAIN" || echo "$CUR_ARGO_DOMAIN")
NEW_ARGO_AUTH=$([ -n "$(trim "$IN_ARGO_AUTH")" ] && trim "$IN_ARGO_AUTH" || echo "$CUR_ARGO_AUTH")
NEW_DISABLE_ARGO=$([ -n "$(trim "$IN_DISABLE_ARGO")" ] && trim "$IN_DISABLE_ARGO" || echo "$CUR_DISABLE_ARGO")
NEW_HY2_PORT=$([ -n "$IN_HY2_PORT" ] && trim "$IN_HY2_PORT" || echo "$CUR_HY2_PORT")
NEW_TUIC_PORT=$([ -n "$IN_TUIC_PORT" ] && trim "$IN_TUIC_PORT" || echo "$CUR_TUIC_PORT")
NEW_REALITY_PORT=$([ -n "$IN_REALITY_PORT" ] && trim "$IN_REALITY_PORT" || echo "$CUR_REALITY_PORT")
NEW_REALITY_DOMAIN=$([ -n "$(trim "$IN_REALITY_DOMAIN")" ] && trim "$IN_REALITY_DOMAIN" || echo "$CUR_REALITY_DOMAIN")
NEW_SS_PORT=$([ -n "$IN_SS_PORT" ] && trim "$IN_SS_PORT" || echo "$CUR_SS_PORT")
NEW_SOCKS5_PORT=$([ -n "$IN_SOCKS5_PORT" ] && trim "$IN_SOCKS5_PORT" || echo "$CUR_SOCKS5_PORT")
NEW_TROJAN_PORT=$([ -n "$IN_TROJAN_PORT" ] && trim "$IN_TROJAN_PORT" || echo "$CUR_TROJAN_PORT")
NEW_ANYTLS_PORT=$([ -n "$IN_ANYTLS_PORT" ] && trim "$IN_ANYTLS_PORT" || echo "$CUR_ANYTLS_PORT")

cat > "$WRAPPER" << WRAPEOF
#!/bin/bash
export UUID="$NEW_UUID"
export PORT="$NEW_PORT"
export NAME="$NEW_NAME"
export ARGO_DOMAIN="$NEW_ARGO_DOMAIN"
export ARGO_AUTH="$NEW_ARGO_AUTH"
export DISABLE_ARGO="$NEW_DISABLE_ARGO"
export HY2_PORT="$NEW_HY2_PORT"
export TUIC_PORT="$NEW_TUIC_PORT"
export REALITY_PORT="$NEW_REALITY_PORT"
export REALITY_DOMAIN="$NEW_REALITY_DOMAIN"
export SS_PORT="$NEW_SS_PORT"
export SOCKS5_PORT="$NEW_SOCKS5_PORT"
export TROJAN_PORT="$NEW_TROJAN_PORT"
export ANYTLS_PORT="$NEW_ANYTLS_PORT"
cd "$APP_DIR"
touch "$APP_DIR/run.log" 2>/dev/null
chmod 600 "$APP_DIR/run.log" 2>/dev/null
nohup sh "$APP_DIR/singbox.sh" >> "$APP_DIR/run.log" 2>&1 &
echo \$! > "$APP_DIR/singbox.pid"
WRAPEOF
chmod +x "$WRAPPER"

SVCFILE="$HOME/.config/systemd/user/singbox.service"
if [ -f "$SVCFILE" ]; then
  sed -i "s|^Environment=UUID=.*|Environment=UUID=$NEW_UUID|" "$SVCFILE"
  sed -i "s|^Environment=PORT=.*|Environment=PORT=$NEW_PORT|" "$SVCFILE"
  sed -i "s|^Environment=NAME=.*|Environment=NAME=$NEW_NAME|" "$SVCFILE"
  sed -i "s|^Environment=ARGO_DOMAIN=.*|Environment=ARGO_DOMAIN=$NEW_ARGO_DOMAIN|" "$SVCFILE"
  sed -i "s|^Environment=ARGO_AUTH=.*|Environment=ARGO_AUTH=$NEW_ARGO_AUTH|" "$SVCFILE"
  sed -i "s|^Environment=DISABLE_ARGO=.*|Environment=DISABLE_ARGO=$NEW_DISABLE_ARGO|" "$SVCFILE"
  sed -i "s|^Environment=HY2_PORT=.*|Environment=HY2_PORT=$NEW_HY2_PORT|" "$SVCFILE"
  sed -i "s|^Environment=TUIC_PORT=.*|Environment=TUIC_PORT=$NEW_TUIC_PORT|" "$SVCFILE"
  sed -i "s|^Environment=REALITY_PORT=.*|Environment=REALITY_PORT=$NEW_REALITY_PORT|" "$SVCFILE"
  sed -i "s|^Environment=REALITY_DOMAIN=.*|Environment=REALITY_DOMAIN=$NEW_REALITY_DOMAIN|" "$SVCFILE"
  sed -i "s|^Environment=SS_PORT=.*|Environment=SS_PORT=$NEW_SS_PORT|" "$SVCFILE"
  sed -i "s|^Environment=SOCKS5_PORT=.*|Environment=SOCKS5_PORT=$NEW_SOCKS5_PORT|" "$SVCFILE"
  sed -i "s|^Environment=TROJAN_PORT=.*|Environment=TROJAN_PORT=$NEW_TROJAN_PORT|" "$SVCFILE"
  sed -i "s|^Environment=ANYTLS_PORT=.*|Environment=ANYTLS_PORT=$NEW_ANYTLS_PORT|" "$SVCFILE"
  systemctl --user daemon-reload
  systemctl --user restart singbox
  echo -e "${GREEN}配置已更新，systemd 服务已重启${NC}"
else
  pkill -f "singbox/singbox.sh" 2>/dev/null || true
  pkill -f "sing-box"              2>/dev/null || true
  pkill -f "cloudflared"           2>/dev/null || true
  sleep 1
  bash "$WRAPPER"
  echo -e "${GREEN}配置已更新，服务已重启${NC}"
fi
echo -e "${GREEN}管理面板: sb${NC}"
echo -e "${GREEN}查看日志: sb-log${NC}"
EDITCMD
chmod +x "$LOCAL_BIN/sb-edit"

# ── PATH 注入 ─────────────────────────────────────────────────────────────────
export PATH="$LOCAL_BIN:$PATH"
for RC in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zshrc"; do
  if [ -f "$RC" ] && ! grep -q "# singbox PATH" "$RC" 2>/dev/null; then
    printf '\n# singbox PATH\nexport PATH="%s:$PATH"\n' "$LOCAL_BIN" >> "$RC"
  fi
done

# ── 生成 start.sh ─────────────────────────────────────────────────────────────
WRAPPER="$APP_DIR/start.sh"

cat > "$WRAPPER" << WRAPEOF
#!/bin/bash
export UUID="$INPUT_UUID"
export PORT="$INPUT_PORT"
export NAME="$INPUT_NAME"
export ARGO_DOMAIN="$INPUT_ARGO_DOMAIN"
export ARGO_AUTH="$INPUT_ARGO_AUTH"
export DISABLE_ARGO="$INPUT_DISABLE_ARGO"
export HY2_PORT="$INPUT_HY2_PORT"
export TUIC_PORT="$INPUT_TUIC_PORT"
export REALITY_PORT="$INPUT_REALITY_PORT"
export REALITY_DOMAIN="$INPUT_REALITY_DOMAIN"
export SS_PORT="$INPUT_SS_PORT"
export SOCKS5_PORT="$INPUT_SOCKS5_PORT"
export TROJAN_PORT="$INPUT_TROJAN_PORT"
export ANYTLS_PORT="$INPUT_ANYTLS_PORT"
cd "$APP_DIR"
touch "$APP_DIR/run.log" 2>/dev/null
chmod 600 "$APP_DIR/run.log" 2>/dev/null
nohup sh "$APP_DIR/singbox.sh" >> "$APP_DIR/run.log" 2>&1 &
echo \$! > "$APP_DIR/singbox.pid"
WRAPEOF
chmod +x "$WRAPPER"

# ── 开机自启 ──────────────────────────────────────────────────────────────────
USER_SYSTEMD_OK=false
if command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
  USER_SYSTEMD_OK=true
fi

if $USER_SYSTEMD_OK; then
  SYSTEMD_DIR="$HOME/.config/systemd/user"
  mkdir -p "$SYSTEMD_DIR"
  cat > "$SYSTEMD_DIR/singbox.service" << SVCEOF
[Unit]
Description=singbox service
After=network-online.target
Wants=network-online.target
# 连续失败 5 次(5 分钟内)后 systemd 就不再自动重启了，避免配置永久损坏时
# 每 10 秒重启一次刷屏日志；需要人工介入用 systemctl --user reset-failed 后再启动。
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=$APP_DIR
Environment=UUID=$INPUT_UUID
Environment=PORT=$INPUT_PORT
Environment=NAME=$INPUT_NAME
Environment=ARGO_DOMAIN=$INPUT_ARGO_DOMAIN
Environment=ARGO_AUTH=$INPUT_ARGO_AUTH
Environment=DISABLE_ARGO=$INPUT_DISABLE_ARGO
Environment=HY2_PORT=$INPUT_HY2_PORT
Environment=TUIC_PORT=$INPUT_TUIC_PORT
Environment=REALITY_PORT=$INPUT_REALITY_PORT
Environment=REALITY_DOMAIN=$INPUT_REALITY_DOMAIN
Environment=SS_PORT=$INPUT_SS_PORT
Environment=SOCKS5_PORT=$INPUT_SOCKS5_PORT
Environment=TROJAN_PORT=$INPUT_TROJAN_PORT
Environment=ANYTLS_PORT=$INPUT_ANYTLS_PORT
ExecStart=/bin/sh $APP_DIR/singbox.sh
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SVCEOF
  systemctl --user daemon-reload
  systemctl --user enable singbox
  systemctl --user start singbox
  loginctl enable-linger "$USER" 2>/dev/null || true
  # 有 systemd 就只用 systemd 自启，不再叠加 cron @reboot（否则重启后会启动两份进程）。
  # 顺便清掉旧版本安装脚本可能残留的 cron 条目。
  (crontab -l 2>/dev/null | grep -v "singbox autostart") | crontab - 2>/dev/null || true
  echo ""
  echo -e "${GREEN}服务已通过用户级 systemd 启动并设置开机自启${NC}"
else
  bash "$WRAPPER"
  # 用 cron @reboot 替代写 RC 文件，避免只在登录时才触发
  (crontab -l 2>/dev/null | grep -v "singbox autostart"; \
   echo "@reboot sleep 20 && bash $WRAPPER >/dev/null 2>&1") | crontab -
  echo ""
  echo -e "${GREEN}服务已通过 nohup 后台启动，开机自启已写入 cron${NC}"
fi

echo ""
echo -e "${GREEN}管理面板: sb${NC}"
echo -e "${GREEN}查看节点: sb-sub${NC}"
echo -e "${GREEN}查看日志: sb-log${NC}"
echo -e "${GREEN}修改配置: sb-edit${NC}"
echo -e "${GREEN}彻底删除: sb-del${NC}"
echo ""
echo -e "${YELLOW}等待服务启动，节点链接将写入 $APP_DIR/sub.txt${NC}"
