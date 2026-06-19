#!/bin/bash
set -e

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${YELLOW}========== singbox 安装 ==========${NC}"

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
$DL "$BASE_URL/entrypoint.sh" $DL_O entrypoint.sh
chmod +x entrypoint.sh
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

HAS_ENV=false
for v in "$INPUT_UUID" "$INPUT_PORT" "$INPUT_ARGO_PORT" "$INPUT_NAME" \
          "$INPUT_ARGO_DOMAIN" "$INPUT_ARGO_AUTH" "$INPUT_DISABLE_ARGO" \
          "$INPUT_HY2_PORT" "$INPUT_TUIC_PORT" "$INPUT_REALITY_PORT" \
          "$INPUT_REALITY_DOMAIN" "$INPUT_SS_PORT"; do
  [ -n "$v" ] && HAS_ENV=true && break
done

if ! $HAS_ENV; then
  echo ""
  echo -e "${YELLOW}========== 基础配置（留空使用默认值）==========${NC}"
  read -p "UUID（留空自动生成）: "              INPUT_UUID
  read -p "PORT（留空默认 3000）: "             INPUT_PORT
  read -p "NAME/节点名称前缀（留空自动识别）: " INPUT_NAME
  echo ""
  echo -e "${YELLOW}--- Argo 隧道（留空使用临时隧道）---${NC}"
  read -p "ARGO_DOMAIN/固定隧道域名: "  INPUT_ARGO_DOMAIN
  read -p "ARGO_AUTH/固定隧道 Token: "  INPUT_ARGO_AUTH
  read -p "DISABLE_ARGO/禁用 Argo（填 true 禁用，留空启用）: " INPUT_DISABLE_ARGO
  echo ""
  echo -e "${YELLOW}--- 可选协议（留空不启用）---${NC}"
  read -p "HY2_PORT/Hysteria2 端口(UDP): "          INPUT_HY2_PORT
  read -p "TUIC_PORT/TUIC v5 端口(UDP): "           INPUT_TUIC_PORT
  read -p "REALITY_PORT/VLESS Reality 端口(TCP): "  INPUT_REALITY_PORT
  read -p "REALITY_DOMAIN/Reality 伪装域名（留空默认 www.iij.ad.jp）: " INPUT_REALITY_DOMAIN
  read -p "SS_PORT/Shadowsocks 2022 端口(TCP): "    INPUT_SS_PORT
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
WRAPPER="$APP_DIR/start.sh"
SUB_FILE="$APP_DIR/sub.txt"
LOG_FILE="$APP_DIR/run.log"
SB_BIN_PATH="/tmp/sb-bin/singbox/sing-box"

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
}

check_status() {
  local sb_s cf_s
  pgrep -f "sing-box" >/dev/null 2>&1    && sb_s="${GREEN}sing-box ✓${RESET}"    || sb_s="${RED}sing-box ✗${RESET}"
  pgrep -f "cloudflared" >/dev/null 2>&1 && cf_s="${GREEN}cloudflared ✓${RESET}" || cf_s="${RED}cloudflared ✗${RESET}"
  echo -e "状态: $sb_s  $cf_s"
}

restart_service() {
  echo -e "${YELLOW}正在重启服务...${RESET}"
  pkill -f "singbox/entrypoint.sh" 2>/dev/null || true
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
      vmess://*)     echo -e "${GREEN}  ✓ VMess + WS + Argo TLS${RESET}" ;;
      hysteria2://*)  echo -e "${GREEN}  ✓ Hysteria2${RESET}" ;;
      tuic://*)       echo -e "${GREEN}  ✓ TUIC v5${RESET}" ;;
      vless://*)      echo -e "${GREEN}  ✓ VLESS Reality${RESET}" ;;
      ss://*)         echo -e "${GREEN}  ✓ Shadowsocks${RESET}" ;;
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
    echo -e "${WHITE}0. 返回${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -ne "${GRAY}请输入选项: ${RESET}"
    read -r opt
    case "$opt" in
      1) config_uuid ;;
      2) config_argo ;;
      3) config_proto ;;
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
    rm -f "$HOME/reality-keys.txt"
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
    local hy2 tuic reality reality_domain ss
    hy2=$(get_val HY2_PORT)
    tuic=$(get_val TUIC_PORT)
    reality=$(get_val REALITY_PORT)
    reality_domain=$(get_val REALITY_DOMAIN)
    ss=$(get_val SS_PORT)

    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}1. Hysteria2    (UDP) [${CYAN}${hy2:-未启用}${WHITE}]${RESET}"
    echo -e "${WHITE}2. TUIC         (UDP) [${CYAN}${tuic:-未启用}${WHITE}]${RESET}"
    echo -e "${WHITE}3. VLESS Reality(TCP) [${CYAN}${reality:-未启用}${WHITE}]${RESET}"
    echo -e "${WHITE}4. Reality 伪装域名   [${CYAN}${reality_domain:-www.iij.ad.jp}${WHITE}]${RESET}"
    echo -e "${WHITE}5. Shadowsocks  (TCP) [${CYAN}${ss:-未启用}${WHITE}]${RESET}"
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
          rm -f "$HOME/reality-keys.txt"
          echo -e "${GREEN}已更新为: $val，Reality 密钥已清除，重启后重新生成${RESET}"
        fi
        sleep 1
        ;;
      5) _set_port SS_PORT "$ss" "Shadowsocks" ;;
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
pkill -f "singbox/entrypoint.sh" 2>/dev/null || true
pkill -f "sing-box"              2>/dev/null || true
pkill -f "cloudflared"           2>/dev/null || true
for RC in "\$HOME/.bashrc" "\$HOME/.profile" "\$HOME/.bash_profile" "\$HOME/.zshrc"; do
  sed -i '/# singbox/d'  "\$RC" 2>/dev/null || true
  sed -i '/singbox/d'    "\$RC" 2>/dev/null || true
done
rm -rf "\$HOME/singbox"
rm -rf /tmp/sb-bin
rm -f "\$HOME/uuid.txt" "\$HOME/sb-config.json" "\$HOME/reality-keys.txt"
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

echo -e "${GREEN}========== singbox 配置修改 ==========${NC}"
echo -e "${YELLOW}直接回车保留当前值，输入新值后回车修改${NC}"
echo ""
echo -e "${YELLOW}--- 基础配置 ---${NC}"
read -p "UUID         [${CUR_UUID:-自动生成}]: "          IN_UUID
read -p "PORT         [${CUR_PORT:-3000}]: "              IN_PORT
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
cd "$APP_DIR"
nohup bash "$APP_DIR/entrypoint.sh" >> "$APP_DIR/run.log" 2>&1 &
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
  systemctl --user daemon-reload
  systemctl --user restart singbox
  echo -e "${GREEN}配置已更新，systemd 服务已重启${NC}"
else
  pkill -f "singbox/entrypoint.sh" 2>/dev/null || true
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
cd "$APP_DIR"
nohup bash "$APP_DIR/entrypoint.sh" >> "$APP_DIR/run.log" 2>&1 &
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
After=network.target

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
ExecStart=/bin/bash $APP_DIR/entrypoint.sh
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
  echo ""
  echo -e "${GREEN}服务已通过用户级 systemd 启动并设置开机自启${NC}"
else
  bash "$WRAPPER"
  for RC in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zshrc"; do
    if [ -f "$RC" ] && ! grep -q "# singbox autostart" "$RC" 2>/dev/null; then
      printf '\n# singbox autostart\nif ! pgrep -f "singbox/entrypoint.sh" >/dev/null 2>&1; then\n  bash "%s" >/dev/null 2>&1\nfi\n' "$WRAPPER" >> "$RC"
    fi
  done
  echo ""
  echo -e "${GREEN}服务已通过 nohup 后台启动${NC}"
fi

echo ""
echo -e "${GREEN}管理面板: sb${NC}"
echo -e "${GREEN}查看节点: sb-sub${NC}"
echo -e "${GREEN}查看日志: sb-log${NC}"
echo -e "${GREEN}修改配置: sb-edit${NC}"
echo -e "${GREEN}彻底删除: sb-del${NC}"
echo ""
echo -e "${YELLOW}等待服务启动，节点链接将写入 $APP_DIR/sub.txt${NC}"
