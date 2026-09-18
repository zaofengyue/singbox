#!/bin/bash
# ==============================================================================
# singbox.sh - 一体化 Sing-box 跨平台服务端管理脚本
# 功能支持: 安装部署 / 守护进程 / 交互面板 / 订阅查看 / 证书申请 / 出口分流 / 探针监控
# ==============================================================================

# Alpine ash 兼容性处理：若当前不是 bash 则尝试唤起或自动安装 bash
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  elif [ "$(id -u)" = "0" ] && command -v apk >/dev/null 2>&1; then
    echo "检测到 Alpine 系统，自动安装 bash 与基础工具..."
    apk add --no-cache bash >/dev/null 2>&1 || true
    exec bash "$0" "$@"
  else
    echo "本脚本需要 bash 才能运行，当前系统未检测到 bash。"
    [ -x "$(command -v apk 2>/dev/null)" ] && echo "Alpine 用户请先执行: apk add --no-cache bash"
    [ -x "$(command -v apt-get 2>/dev/null)" ] && echo "Debian/Ubuntu 用户请先执行: apt-get install -y bash"
    exit 1
  fi
fi

export TERM="${TERM:-xterm}"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LANG:-C.UTF-8}"

# ── 颜色与输出定义 ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
WHITE='\033[0;97m'
NC='\033[0m'
RESET='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── 路径与常量定义 ────────────────────────────────────────────────────────────
BRANCH="${BRANCH:-main}"

HOME_DIR="${HOME:-/root}"
APP_DIR="$HOME_DIR/singbox"
STATE_DIR="$APP_DIR/state"
ENV_FILE="$APP_DIR/config.env"
LEGACY_WRAPPER="$APP_DIR/start.sh"
SUB_FILE="$APP_DIR/sub.txt"
LOG_FILE="$APP_DIR/run.log"
CF_LOG="$APP_DIR/cf.log"
KM_LOG="$APP_DIR/komari.log"
PID_FILE="$APP_DIR/singbox.pid"
SVCFILE="$HOME_DIR/.config/systemd/user/singbox.service"
LOCAL_BIN="$HOME_DIR/.local/bin"

# 密钥与证书集中存放
UUID_FILE="$STATE_DIR/uuid.txt"
CONFIG_FILE="$STATE_DIR/sb-config.json"
REALITY_KEY_FILE="$STATE_DIR/reality-keys.txt"
OUTBOUND_FILE="$STATE_DIR/outbound.conf"
CERT_DIR="$STATE_DIR/certs"
DOMAIN_CERT_DIR="$STATE_DIR/domain-certs"
ACME_HOME="$STATE_DIR/acme.sh"

# 二进制存放目录（优先 /tmp/sb-bin 避开 noexec，备用 $HOME_DIR/sb-bin）
BIN_DIR="/tmp/sb-bin"
SB_DIR="$BIN_DIR/singbox"
SB_BIN="$SB_DIR/sing-box"
CF_BIN="$BIN_DIR/cloudflared"
KM_BIN="$BIN_DIR/komari-agent"

USED_PORTS_FILE="/tmp/sb-used-ports.txt"

# ── 配置文件读写工具 ──────────────────────────────────────────────────────────
get_val() {
  local key="$1"
  if [ -f "$ENV_FILE" ]; then
    grep "^${key}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//'
  elif [ -f "$LEGACY_WRAPPER" ]; then
    grep "^export ${key}=" "$LEGACY_WRAPPER" 2>/dev/null | head -1 | sed 's/.*="\(.*\)"/\1/'
  fi
}

set_val() {
  local key="$1" val="$2"
  mkdir -p "$APP_DIR"
  if [ ! -f "$ENV_FILE" ]; then
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
  fi

  if grep -q "^${key}=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=\"${val}\"|" "$ENV_FILE"
  else
    echo "${key}=\"${val}\"" >> "$ENV_FILE"
  fi

  if [ -f "$LEGACY_WRAPPER" ]; then
    if grep -q "^export ${key}=" "$LEGACY_WRAPPER" 2>/dev/null; then
      sed -i "s|^export ${key}=.*|export ${key}=\"${val}\"|" "$LEGACY_WRAPPER"
    else
      sed -i "/^cd /i export ${key}=\"${val}\"" "$LEGACY_WRAPPER" 2>/dev/null || true
    fi
  fi

  if [ -f "$SVCFILE" ]; then
    if grep -q "^Environment=${key}=" "$SVCFILE" 2>/dev/null; then
      sed -i "s|^Environment=${key}=.*|Environment=${key}=${val}|" "$SVCFILE"
    else
      sed -i "/^\[Install\]/i Environment=${key}=${val}" "$SVCFILE" 2>/dev/null || true
    fi
    systemctl --user daemon-reload 2>/dev/null || true
  fi
}

load_env_file() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  elif [ -f "$LEGACY_WRAPPER" ]; then
    log "从历史配置 start.sh 迁移配置项..."
    touch "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null || true
    grep "^export " "$LEGACY_WRAPPER" | sed 's/^export //' >> "$ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi
}

# ── 基础依赖自动安装 ──────────────────────────────────────────────────────────
try_install_pkg() {
  local _pkg="$1"
  if command -v apk >/dev/null 2>&1; then
    [ "$(id -u)" = "0" ] && apk add --no-cache $_pkg >/dev/null 2>&1 || true
  elif command -v apt-get >/dev/null 2>&1; then
    [ "$(id -u)" = "0" ] && { apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq $_pkg >/dev/null 2>&1 || true; }
  fi
}

ensure_basic_deps() {
  local _missing=""
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || _missing="$_missing curl"
  command -v tar     >/dev/null 2>&1 || _missing="$_missing tar"
  command -v openssl >/dev/null 2>&1 || _missing="$_missing openssl"
  command -v socat   >/dev/null 2>&1 || _missing="$_missing socat"
  if command -v apk >/dev/null 2>&1; then
    _missing="$_missing libc6-compat gcompat ca-certificates"
  fi
  [ -z "$_missing" ] && return 0

  warn "检测到缺少基础工具:${_missing}，尝试自动安装..."
  try_install_pkg "$_missing ca-certificates"
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "缺少 curl/wget 且自动安装失败。Alpine: apk add --no-cache curl；Debian/Ubuntu: apt-get install -y curl"
  fi
  if ! command -v tar >/dev/null 2>&1; then
    die "缺少 tar 且自动安装失败。Alpine: apk add --no-cache tar"
  fi
}

# ── 通用工具函数 ──────────────────────────────────────────────────────────────
http_get() {
  local _ipopt="${1:--4}"
  local _url="$2"
  if [ -z "$_url" ]; then _url="$1"; _ipopt=""; fi

  if command -v curl >/dev/null 2>&1; then
    curl $_ipopt -sL --max-time 6 "$_url" 2>/dev/null || true
  else
    wget $_ipopt -qO- --timeout=6 "$_url" 2>/dev/null || true
  fi
}

dl() {
  local _url="$1" _out="$2"
  # 支持直链与多组主流 GitHub 加速镜像回退，保证 99.99% 下载成功率
  local _mirrors=("" "https://ghproxy.net/" "https://github.moeyy.xyz/" "https://mirror.ghproxy.com/")
  for _prefix in "${_mirrors[@]}"; do
    local _target="${_prefix}${_url}"
    rm -f "$_out"
    if command -v curl >/dev/null 2>&1; then
      curl -sL --fail --max-time 90 "$_target" -o "$_out" 2>/dev/null || true
    else
      wget -q --timeout=90 "$_target" -O "$_out" 2>/dev/null || true
    fi
    if [ -s "$_out" ]; then
      # 简单检查是否被拦截下载为 HTML 错误页面
      if head -c 200 "$_out" 2>/dev/null | grep -qiE "<!DOCTYPE html|<html"; then
        rm -f "$_out"
        continue
      fi
      return 0
    fi
  done
  return 1
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  SB_ARCH="amd64";  CF_ARCH="linux-amd64"; KM_ARCH="linux-amd64" ;;
    aarch64|arm64) SB_ARCH="arm64";  CF_ARCH="linux-arm64"; KM_ARCH="linux-arm64" ;;
    armv7*|armv6*) SB_ARCH="armv7";  CF_ARCH="linux-arm";   KM_ARCH="linux-arm"   ;;
    i386|i686)     SB_ARCH="386";    CF_ARCH="linux-386";   KM_ARCH="linux-386"   ;;
    *)             SB_ARCH="amd64";  CF_ARCH="linux-amd64"; KM_ARCH="linux-amd64" ;;
  esac
}
detect_arch

format_komari_endpoint() {
  local ep="$1"
  # 剔除首尾空白与末尾斜杠
  ep="$(printf '%s' "$ep" | tr -d ' \r\n' | sed 's|/*$||')"
  case "$ep" in
    http://*|https://*)
      ;;
    *:25774|[0-9]*.[0-9]*.[0-9]*.[0-9]*:*|[0-9]*.[0-9]*.[0-9]*.[0-9]*)
      # 默认 25774 端口或纯 IP 通常为 HTTP 无证书服务
      ep="http://$ep"
      ;;
    *)
      # 域名默认走 HTTPS
      ep="https://$ep"
      ;;
  esac
  printf '%s' "$ep"
}

download_komari() {
  detect_arch
  mkdir -p "$BIN_DIR"
  if [ "$KM_ARCH" != "linux-amd64" ] && [ "$KM_ARCH" != "linux-arm64" ]; then
    warn "Komari 官方探针暂不支持当前 CPU 架构 (${KM_ARCH:-未知})，仅支持 x86_64 与 aarch64"
    return 1
  fi
  log "正在检查/下载 Komari 探针..."
  if dl "https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-${KM_ARCH}" "$KM_BIN"; then
    chmod +x "$KM_BIN"
    log "Komari 探针下载完成"
    return 0
  fi
  warn "Komari 探针下载失败"
  return 1
}

b64() {
  printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'
}

url_encode() {
  printf '%s' "$1" | sed \
    -e 's/ /%20/g' -e 's/#/%23/g' -e 's/&/%26/g' -e 's/+/%2B/g' \
    -e 's/,/%2C/g' -e 's/:/%3A/g' -e 's/;/%3B/g' -e 's/=/%3D/g' \
    -e 's/?/%3F/g' -e 's/@/%40/g'
}

json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

format_addr() {
  case "$1" in
    *:*) printf '[%s]' "$1" ;;
    *)   printf '%s' "$1" ;;
  esac
}

press_any_key() {
  echo ""
  echo -e "${GRAY}按回车键返回...${RESET}"
  read -r
}

port_in_use_os() {
  local _p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":${_p} " && return 0
    ss -lun 2>/dev/null | grep -q ":${_p} " && return 0
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -q ":${_p} " && return 0
    netstat -lun 2>/dev/null | grep -q ":${_p} " && return 0
  fi
  return 1
}

port_ok() {
  local _p="$1"
  [ -z "$_p" ] && return 1
  case "$_p" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_p" -lt 1 ] || [ "$_p" -gt 65535 ] && return 1
  grep -qx "$_p" "$USED_PORTS_FILE" 2>/dev/null && return 1
  if port_in_use_os "$_p"; then return 1; fi
  echo "$_p" >> "$USED_PORTS_FILE"
  return 0
}

valid_port_range() {
  local _r="$1"
  case "$_r" in *[!0-9-]*) return 1 ;; esac
  local _start="${_r%%-*}"
  local _end="${_r##*-}"
  [ "$_r" = "${_start}-${_end}" ] || return 1
  case "$_start" in ''|*[!0-9]*) return 1 ;; esac
  case "$_end" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_start" -ge 1 ] && [ "$_end" -le 65535 ] && [ "$_start" -lt "$_end" ]
}

parse_extra_ports() {
  local _list="$1" _out="" _old_ifs="$IFS"
  IFS=','
  for _p in $_list; do
    IFS="$_old_ifs"
    _p="$(echo "$_p" | tr -d '[:space:]')"
    [ -z "$_p" ] && continue
    if port_ok "$_p"; then
      _out="${_out}${_out:+ }${_p}"
    else
      echo "[WARN] 额外端口 ${_p} 无效或冲突，已跳过" >&2
    fi
    IFS=','
  done
  IFS="$_old_ifs"
  echo "$_out"
}

get_free_port() {
  local _port=10086
  if command -v ss >/dev/null 2>&1; then
    for _try in 10086 10087 10088 10089 10090; do
      ss -ltn 2>/dev/null | grep -q ":${_try} " || { _port=$_try; break; }
    done
  elif command -v python3 >/dev/null 2>&1; then
    _port=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)" 2>/dev/null) || _port=10086
  fi
  echo "$_port"
}

wait_port() {
  local _host="$1" _port="$2" _max="${3:-10}" _i=0
  while [ "$_i" -lt "$_max" ]; do
    if command -v nc >/dev/null 2>&1; then
      nc -z "$_host" "$_port" 2>/dev/null && return 0
    elif command -v ss >/dev/null 2>&1; then
      ss -ltn 2>/dev/null | grep -q ":${_port} " && return 0
    fi
    sleep 1
    _i=$((_i + 1))
  done
  return 1
}

valid_uuid() {
  case "$1" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      return 0 ;;
    *) return 1 ;;
  esac
}

valid_ip() {
  local _v="$1"
  [ -z "$_v" ] && return 1
  [ "${#_v}" -gt 45 ] && return 1
  case "$_v" in
    *[!0-9a-fA-F:.]*) return 1 ;;
    *[0-9]*) : ;;
    *) return 1 ;;
  esac
  return 0
}

# ── 服务控制与状态 ────────────────────────────────────────────────────────────
check_status() {
  local sb_s cf_s km_s cur_km_dom
  pgrep -f "sing-box" >/dev/null 2>&1    && sb_s="${GREEN}sing-box ✓${RESET}"    || sb_s="${RED}sing-box ✗${RESET}"
  pgrep -f "cloudflared" >/dev/null 2>&1 && cf_s="${GREEN}cloudflared ✓${RESET}" || cf_s="${RED}cloudflared ✗${RESET}"
  cur_km_dom=$(get_val KOMARI_DOMAIN)
  [ -z "$cur_km_dom" ] && cur_km_dom=$(get_val KOMARI_ENDPOINT)
  if [ -n "$cur_km_dom" ]; then
    pgrep -f "komari-agent" >/dev/null 2>&1 && km_s="${GREEN}komari ✓${RESET}" || km_s="${RED}komari ✗${RESET}"
    echo -e "状态: $sb_s  $cf_s  $km_s"
  else
    echo -e "状态: $sb_s  $cf_s"
  fi
}

do_stop() {
  echo -e "${YELLOW}正在停止服务...${RESET}"
  systemctl --user stop singbox 2>/dev/null || true
  pkill -f "singbox.sh run"       2>/dev/null || true
  pkill -f "singbox/singbox.sh"   2>/dev/null || true
  pkill -f "sing-box"             2>/dev/null || true
  pkill -f "cloudflared"          2>/dev/null || true
  pkill -f "komari-agent"         2>/dev/null || true
  echo -e "${GREEN}服务已停止${RESET}"
}

do_restart() {
  echo -e "${YELLOW}正在重启服务...${RESET}"
  do_stop
  sleep 1
  if systemctl --user is-enabled singbox >/dev/null 2>&1; then
    systemctl --user restart singbox
  elif [ -f "$LEGACY_WRAPPER" ]; then
    bash "$LEGACY_WRAPPER"
  else
    nohup bash "$APP_DIR/singbox.sh" run >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
  fi
  echo -e "${GREEN}服务已重启${RESET}"
}

# ── 快捷命令软链接创建 ────────────────────────────────────────────────────────
create_symlinks() {
  mkdir -p "$LOCAL_BIN"
  for cmd in sb sb-sub sb-log sb-del sb-edit; do
    local subcmd=""
    case "$cmd" in
      sb)      subcmd="menu" ;;
      sb-sub)  subcmd="sub" ;;
      sb-log)  subcmd="log" ;;
      sb-del)  subcmd="uninstall" ;;
      sb-edit) subcmd="edit" ;;
    esac
    cat > "$LOCAL_BIN/$cmd" << WRAP
#!/usr/bin/env bash
if [ ! -s "$APP_DIR/singbox.sh" ]; then
  echo "检测到脚本文件为空或缺失，正在自动修复同步..."
  curl -fsSL "https://raw.githubusercontent.com/zaofengyue/singbox/${BRANCH:-main}/singbox.sh" -o "$APP_DIR/singbox.sh" 2>/dev/null || \
  wget -qO "$APP_DIR/singbox.sh" "https://raw.githubusercontent.com/zaofengyue/singbox/${BRANCH:-main}/singbox.sh" 2>/dev/null || true
  chmod +x "$APP_DIR/singbox.sh" 2>/dev/null || true
fi
exec bash "$APP_DIR/singbox.sh" $subcmd "\$@"
WRAP
    chmod +x "$LOCAL_BIN/$cmd"
  done

  if [ "$(id -u)" = "0" ] || [ -w /usr/local/bin ] 2>/dev/null; then
    mkdir -p /usr/local/bin 2>/dev/null || true
    for cmd in sb sb-sub sb-log sb-del sb-edit; do
      ln -sf "$LOCAL_BIN/$cmd" "/usr/local/bin/$cmd" 2>/dev/null || true
    done
    if [ -x /usr/local/bin/sb ]; then
      log "命令已链接到 /usr/local/bin，全局终端可直接输入 sb 使用"
    fi
  fi

  for RC in "$HOME_DIR/.profile" "$HOME_DIR/.bashrc" "$HOME_DIR/.bash_profile" "$HOME_DIR/.zshrc"; do
    [ -e "$RC" ] || : > "$RC" 2>/dev/null || true
    if [ -f "$RC" ] && ! grep -q "# singbox PATH" "$RC" 2>/dev/null; then
      printf '\n# singbox PATH\nexport PATH="%s:$PATH"\n' "$LOCAL_BIN" >> "$RC" 2>/dev/null || true
    fi
  done
}

# ==============================================================================
# 模块 1: 安装流程 (do_install)
# ==============================================================================
do_install() {
  echo -e "${YELLOW}==================== singbox 安装向导 ====================${NC}"
  ensure_basic_deps

  mkdir -p "$APP_DIR" "$STATE_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true

  local _src_is_file=false
  case "$0" in
    /dev/*|/proc/*|bash|sh|-*) _src_is_file=false ;;
    *) [ -f "$0" ] && [ -s "$0" ] && _src_is_file=true ;;
  esac

  if $_src_is_file; then
    [ "$0" != "$APP_DIR/singbox.sh" ] && cp -f "$0" "$APP_DIR/singbox.sh"
  else
    log "检测到网络一键安装，正在保存脚本至本地..."
    local SCRIPT_RAW="https://raw.githubusercontent.com/zaofengyue/singbox/${BRANCH:-main}/singbox.sh"
    dl "$SCRIPT_RAW" "$APP_DIR/singbox.sh" || {
      curl -fsSL "$SCRIPT_RAW" -o "$APP_DIR/singbox.sh" 2>/dev/null || \
      wget -qO "$APP_DIR/singbox.sh" "$SCRIPT_RAW" 2>/dev/null || true
    }
  fi
  chmod +x "$APP_DIR/singbox.sh"

  local IN_UUID="${UUID:-}"
  local IN_PORT="${PORT:-}"
  local IN_ARGO_PORT="${ARGO_PORT:-}"
  local IN_NAME="${NAME:-}"
  local IN_ARGO_DOMAIN="${ARGO_DOMAIN:-}"
  local IN_ARGO_AUTH="${ARGO_AUTH:-}"
  local IN_DISABLE_ARGO="${DISABLE_ARGO:-}"
  local IN_HY2_PORT="${HY2_PORT:-}"
  local IN_TUIC_PORT="${TUIC_PORT:-}"
  local IN_REALITY_PORT="${REALITY_PORT:-}"
  local IN_REALITY_DOMAIN="${REALITY_DOMAIN:-}"
  local IN_SS_PORT="${SS_PORT:-}"
  local IN_SOCKS5_PORT="${SOCKS5_PORT:-}"
  local IN_TROJAN_PORT="${TROJAN_PORT:-}"
  local IN_ANYTLS_PORT="${ANYTLS_PORT:-}"
  local IN_KOMARI_DOMAIN="${KOMARI_DOMAIN:-${KOMARI_ENDPOINT:-}}"
  local IN_KOMARI_TOKEN="${KOMARI_TOKEN:-}"

  local HAS_ENV=false
  for v in "$IN_UUID" "$IN_PORT" "$IN_ARGO_PORT" "$IN_NAME" \
            "$IN_ARGO_DOMAIN" "$IN_ARGO_AUTH" "$IN_DISABLE_ARGO" \
            "$IN_HY2_PORT" "$IN_TUIC_PORT" "$IN_REALITY_PORT" \
            "$IN_REALITY_DOMAIN" "$IN_SS_PORT" "$IN_SOCKS5_PORT" \
            "$IN_TROJAN_PORT" "$IN_ANYTLS_PORT" \
            "$IN_KOMARI_DOMAIN" "$IN_KOMARI_TOKEN"; do
    [ -n "$v" ] && HAS_ENV=true && break
  done

  if ! $HAS_ENV; then
    echo ""
    echo -e "${YELLOW}---------- 基础配置 ----------${NC}"
    read -p "UUID（留空自动生成）: "              IN_UUID
    read -p "NAME/节点名称前缀（留空自动识别）: " IN_NAME

    echo ""
    echo -e "${YELLOW}--- Argo 隧道 ---${NC}"
    read -p "是否启用 Argo 隧道？[Y/n]: " _ARGO_CHOICE
    _ARGO_CHOICE="$(echo "$_ARGO_CHOICE" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    if [ "$_ARGO_CHOICE" = "n" ]; then
      IN_DISABLE_ARGO="true"
      echo -e "${YELLOW}Argo 已禁用${NC}"
    else
      IN_DISABLE_ARGO=""
      echo -e "${GREEN}Argo 已启用（临时隧道），如需固定隧道可通过管理面板 sb 配置${NC}"
    fi

    echo ""
    echo -e "${YELLOW}--- 可选直连协议（留空跳过）---${NC}"
    echo -e "  ${GREEN}a${NC}. Hysteria2    (UDP)"
    echo -e "  ${GREEN}b${NC}. TUIC v5      (UDP)"
    echo -e "  ${GREEN}c${NC}. VLESS Reality(TCP)"
    echo -e "  ${GREEN}d${NC}. Shadowsocks  (TCP)"
    echo -e "  ${GREEN}e${NC}. SOCKS5       (TCP/UDP)"
    echo -e "  ${GREEN}f${NC}. Trojan       (TCP)"
    echo -e "  ${GREEN}g${NC}. AnyTLS       (TCP)"
    read -p "选择协议（如 ac 表示启用 a 和 c，输入 all 表示全部启用，留空跳过）: " _PROTO_CHOICE
    echo "$_PROTO_CHOICE" | grep -qi "^all$" && _PROTO_CHOICE="abcdefg"

    local _used_rand_ports=""
    _gen_rand_port() {
      local _p _tries=0
      while [ $_tries -lt 50 ]; do
        _p=$(( (RANDOM % 29152) + 20000 ))
        case " $_used_rand_ports " in
          *" $_p "*) _tries=$((_tries + 1)); continue ;;
        esac
        if command -v ss >/dev/null 2>&1 && ss -ltnu 2>/dev/null | grep -q ":${_p} "; then
          _tries=$((_tries + 1)); continue
        fi
        _GEN_PORT="$_p"
        _used_rand_ports="$_used_rand_ports $_p"
        return
      done
      _GEN_PORT="$_p"
      _used_rand_ports="$_used_rand_ports $_p"
    }

    if echo "$_PROTO_CHOICE" | grep -qi "a"; then
      _gen_rand_port; IN_HY2_PORT="$_GEN_PORT"
      echo -e "${GREEN}Hysteria2 端口: $IN_HY2_PORT${NC}"
    fi
    if echo "$_PROTO_CHOICE" | grep -qi "b"; then
      _gen_rand_port; IN_TUIC_PORT="$_GEN_PORT"
      echo -e "${GREEN}TUIC v5 端口: $IN_TUIC_PORT${NC}"
    fi
    if echo "$_PROTO_CHOICE" | grep -qi "c"; then
      _gen_rand_port; IN_REALITY_PORT="$_GEN_PORT"
      echo -e "${GREEN}VLESS Reality 端口: $IN_REALITY_PORT（伪装域名默认 www.iij.ad.jp）${NC}"
    fi
    if echo "$_PROTO_CHOICE" | grep -qi "d"; then
      _gen_rand_port; IN_SS_PORT="$_GEN_PORT"
      echo -e "${GREEN}Shadowsocks 端口: $IN_SS_PORT${NC}"
    fi
    if echo "$_PROTO_CHOICE" | grep -qi "e"; then
      _gen_rand_port; IN_SOCKS5_PORT="$_GEN_PORT"
      echo -e "${GREEN}SOCKS5 端口: $IN_SOCKS5_PORT${NC}"
    fi
    if echo "$_PROTO_CHOICE" | grep -qi "f"; then
      _gen_rand_port; IN_TROJAN_PORT="$_GEN_PORT"
      echo -e "${GREEN}Trojan 端口: $IN_TROJAN_PORT${NC}"
    fi
    if echo "$_PROTO_CHOICE" | grep -qi "g"; then
      _gen_rand_port; IN_ANYTLS_PORT="$_GEN_PORT"
      echo -e "${GREEN}AnyTLS 端口: $IN_ANYTLS_PORT${NC}"
    fi

    echo ""
    echo -e "${YELLOW}--- Komari 监控探针（可选）---${NC}"
    read -p "Komari 服务端地址（如 https://komari.example.com 或 http://IP:25774，留空跳过）: " IN_KOMARI_DOMAIN
    if [ -n "$IN_KOMARI_DOMAIN" ]; then
      read -p "Komari 探针密钥 Token: " IN_KOMARI_TOKEN
    fi
  fi

  cat > "$ENV_FILE" << EOF
UUID="${IN_UUID}"
PORT="${IN_PORT}"
NAME="${IN_NAME}"
ARGO_PORT="${IN_ARGO_PORT}"
ARGO_DOMAIN="${IN_ARGO_DOMAIN}"
ARGO_AUTH="${IN_ARGO_AUTH}"
DISABLE_ARGO="${IN_DISABLE_ARGO}"
HY2_PORT="${IN_HY2_PORT}"
TUIC_PORT="${IN_TUIC_PORT}"
REALITY_PORT="${IN_REALITY_PORT}"
REALITY_DOMAIN="${IN_REALITY_DOMAIN:-www.iij.ad.jp}"
SS_PORT="${IN_SS_PORT}"
SOCKS5_PORT="${IN_SOCKS5_PORT}"
TROJAN_PORT="${IN_TROJAN_PORT}"
ANYTLS_PORT="${IN_ANYTLS_PORT}"
KOMARI_DOMAIN="${IN_KOMARI_DOMAIN}"
KOMARI_TOKEN="${IN_KOMARI_TOKEN}"
ARGO_PROTOCOL="${ARGO_PROTOCOL:-http2}"
EOF
  chmod 600 "$ENV_FILE"

  create_symlinks

  local USER_SYSTEMD_OK=false
  if command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
    USER_SYSTEMD_OK=true
  fi

  if $USER_SYSTEMD_OK; then
    local SYSTEMD_DIR="$HOME_DIR/.config/systemd/user"
    mkdir -p "$SYSTEMD_DIR"
    cat > "$SYSTEMD_DIR/singbox.service" << SVCEOF
[Unit]
Description=singbox service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=$APP_DIR
EnvironmentFile=-$ENV_FILE
ExecStart=/bin/bash $APP_DIR/singbox.sh run
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SVCEOF
    systemctl --user daemon-reload
    systemctl --user enable singbox
    systemctl --user restart singbox
    loginctl enable-linger "$USER" 2>/dev/null || true
    (crontab -l 2>/dev/null | grep -v "singbox" ; echo "0 3 * * * bash $APP_DIR/singbox.sh renew-cron >> $LOG_FILE 2>&1") | crontab - 2>/dev/null || true
    echo ""
    log "服务已通过用户级 systemd 启动并设置开机自启（证书自动续期已配置）"
  else
    do_restart
    (crontab -l 2>/dev/null | grep -v "singbox" ; \
     echo "@reboot sleep 20 && bash $APP_DIR/singbox.sh run >> $LOG_FILE 2>&1" ; \
     echo "0 3 * * * bash $APP_DIR/singbox.sh renew-cron >> $LOG_FILE 2>&1") | crontab - 2>/dev/null || true
    echo ""
    log "服务已通过 nohup 后台启动，开机自启与证书自动续期已写入 cron"
  fi

  echo ""
  echo -e "${GREEN}==================== 安装完成 ====================${NC}"
  echo -e "${GREEN}管理面板: sb${NC}"
  echo -e "${GREEN}查看节点: sb-sub${NC}"
  echo -e "${GREEN}查看日志: sb-log${NC}"
  echo -e "${GREEN}修改配置: sb-edit${NC}"
  echo -e "${GREEN}彻底卸载: sb-del${NC}"
  echo ""
  echo -e "${YELLOW}等待服务初始化完成，节点链接将写入 $SUB_FILE${NC}"
}

# ==============================================================================
# 模块 2: 交互管理控制面板 (do_menu - 原 sb)
# ==============================================================================
do_menu() {
  while true; do
    clear
    echo -e "${GREEN}======= singbox 管理面板 =======${RESET}"
    check_status
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}1. 查看节点订阅${RESET}"
    echo -e "${WHITE}2. 查看运行日志${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}3. 重启sing-box${RESET}"
    echo -e "${WHITE}4. 更新sing-box${RESET}"
    echo -e "${WHITE}5. 卸载sing-box${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}6. 修改配置${RESET}"
    echo -e "${WHITE}7. 出口设置${RESET}"
    echo -e "${WHITE}8. 域名证书${RESET}"
    echo -e "${WHITE}0. 退出${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -ne "${GRAY}请输入选项: ${RESET}"
    read -r opt
    case "$opt" in
      1) do_sub; press_any_key ;;
      2) do_log ;;
      3) do_restart; sleep 2 ;;
      4) menu_update ;;
      5) do_uninstall ;;
      6) menu_config ;;
      7) menu_outbound ;;
      8) menu_domain_cert ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

do_sub() {
  clear
  echo -e "${GREEN}======= 节点订阅 =======${RESET}"
  if [ ! -f "$SUB_FILE" ]; then
    echo -e "${RED}sub.txt 不存在，请等待服务启动完成${RESET}"
    return
  fi

  local decoded
  decoded=$(base64 -d < "$SUB_FILE" 2>/dev/null)
  if [ -z "$decoded" ]; then
    echo -e "${RED}订阅内容为空${RESET}"
    return
  fi

  echo -e "${GRAY}已启用协议:${RESET}"
  echo "$decoded" | while IFS= read -r line; do
    case "$line" in
      vmess://*)      echo -e "${GREEN}  ✓ VMess + WS + Argo TLS${RESET}" ;;
      hysteria2://*)  echo -e "${GREEN}  ✓ Hysteria2${RESET}" ;;
      tuic://*)       echo -e "${GREEN}  ✓ TUIC v5${RESET}" ;;
      vless://*)      echo -e "${GREEN}  ✓ VLESS Reality${RESET}" ;;
      ss://*)         echo -e "${GREEN}  ✓ Shadowsocks${RESET}" ;;
      socks5://*|socks://*) echo -e "${GREEN}  ✓ SOCKS5${RESET}" ;;
      trojan://*)     echo -e "${GREEN}  ✓ Trojan${RESET}" ;;
      anytls://*)     echo -e "${GREEN}  ✓ AnyTLS${RESET}" ;;
    esac
  done

  echo -e "${GRAY}--------------------------------${RESET}"
  echo -e "${GRAY}节点链接:${RESET}"
  echo "$decoded" | while IFS= read -r line; do
    [ -n "$line" ] && echo -e "${CYAN}$line${RESET}"
  done
}

do_log() {
  clear
  echo -e "${GREEN}======= 查看日志（Ctrl+C 退出）=======${RESET}"
  echo -e "${WHITE}1. sing-box 核心运行日志${RESET}"
  echo -e "${WHITE}2. cloudflared Argo 隧道日志${RESET}"
  echo -e "${WHITE}3. Komari 探针日志${RESET}"
  echo -e "${WHITE}0. 返回${RESET}"
  echo -e "${GRAY}--------------------------------${RESET}"
  read -p "请选择: " log_opt
  case "$log_opt" in
    1)
      clear
      echo -e "${GREEN}=== sing-box 核心日志 ===${RESET}"
      if systemctl --user is-active singbox >/dev/null 2>&1; then
        journalctl --user -u singbox -n 50 -f
      elif [ -f "$LOG_FILE" ]; then
        tail -n 50 -f "$LOG_FILE"
      else
        echo -e "${RED}未找到核心日志文件 ($LOG_FILE)${RESET}"
        press_any_key
      fi
      ;;
    2)
      clear
      echo -e "${GREEN}=== cloudflared Argo 隧道日志 ===${RESET}"
      if [ -f "$CF_LOG" ]; then
        tail -n 50 -f "$CF_LOG"
      else
        echo -e "${RED}未找到 Argo 日志文件 ($CF_LOG)${RESET}"
        press_any_key
      fi
      ;;
    3)
      clear
      echo -e "${GREEN}=== Komari 探针监控日志 ===${RESET}"
      if [ -f "$KM_LOG" ]; then
        tail -n 50 -f "$KM_LOG"
      else
        echo -e "${RED}未找到探针日志文件 ($KM_LOG)${RESET}"
        press_any_key
      fi
      ;;
    *) return ;;
  esac
}

menu_config() {
  while true; do
    clear
    echo -e "${GREEN}======= 修改配置 =======${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}1. 修改UUID${RESET}"
    echo -e "${WHITE}2. Argo隧道管理${RESET}"
    echo -e "${WHITE}3. 修改协议端口${RESET}"
    echo -e "${WHITE}4. 域名证书绑定${RESET}"
    echo -e "${WHITE}5. 添加多端口${RESET}"
    echo -e "${WHITE}6. 端口跳跃${RESET}"
    echo -e "${WHITE}7. Komari探针监控${RESET}"
    echo -e "${WHITE}8. IP栈偏好与连接域名${RESET}"
    echo -e "${WHITE}0. 返回${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -ne "${GRAY}请输入选项: ${RESET}"
    read -r opt
    case "$opt" in
      1) config_uuid ;;
      2) config_argo ;;
      3) config_proto ;;
      4) config_cert_bind ;;
      5) config_extraports ;;
      6) config_hop ;;
      7) config_komari ;;
      8) config_ip_domain ;;
      0) return ;;
      *) ;;
    esac
  done
}

config_ip_domain() {
  clear
  echo -e "${GREEN}======= IP栈偏好与连接域名 =======${RESET}"
  local cur_v cur_dom cur_pip
  cur_v=$(get_val IP_VERSION)
  cur_dom=$(get_val SERVER_DOMAIN)
  cur_pip=$(get_val PUBLIC_IP)
  echo -e "${GRAY}当前 IP 栈偏好: ${CYAN}${cur_v:-4 (IPv4优先)}${RESET}"
  echo -e "${GRAY}当前连接域名:   ${CYAN}${cur_dom:-未设置 (使用IP)}${RESET}"
  echo -e "${GRAY}自定义公网 IP:  ${CYAN}${cur_pip:-自动探测}${RESET}"
  echo -e "${GRAY}--------------------------------${RESET}"
  echo -e "${WHITE}1. 设置 IP 栈偏好 (4: IPv4优先 | 6: IPv6优先 | auto: 自动)${RESET}"
  echo -e "${WHITE}2. 修改全局连接域名 (输入 0 或留空恢复使用 IP)${RESET}"
  echo -e "${WHITE}3. 手动指定公网 IP (输入 0 或留空恢复自动探测)${RESET}"
  echo -e "${WHITE}0. 返回${RESET}"
  read -p "选项: " opt
  case "$opt" in
    1)
      read -p "请输入 IP 栈偏好 [4/6/auto]: " v
      case "$v" in
        6) set_val IP_VERSION "6" ;;
        auto) set_val IP_VERSION "auto" ;;
        *) set_val IP_VERSION "4" ;;
      esac
      do_restart; press_any_key ;;
    2)
      read -p "全局连接域名（如 node.example.com，输入 0 清除）: " d
      d="$(echo "$d" | tr -d '[:space:]')"
      [ "$d" = "0" ] && d=""
      set_val SERVER_DOMAIN "$d"
      do_restart; press_any_key ;;
    3)
      read -p "手动指定公网 IP（如 1.2.3.4，输入 0 清除）: " ip
      ip="$(echo "$ip" | tr -d '[:space:]')"
      [ "$ip" = "0" ] && ip=""
      set_val PUBLIC_IP "$ip"
      do_restart; press_any_key ;;
    *) return ;;
  esac
}

config_uuid() {
  clear
  echo -e "${GREEN}======= 修改 UUID =======${RESET}"
  local cur
  cur=$(get_val UUID)
  echo -e "${GRAY}当前: ${CYAN}${cur:-未设置}${RESET}"
  echo -e "${GRAY}--------------------------------${RESET}"
  echo -e "${WHITE}新 UUID（留空自动生成，回车确认）:${RESET}"
  read -r new_uuid
  if [ -z "$new_uuid" ]; then
    new_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8$9}')
  fi
  echo -e "${YELLOW}⚠ 修改后将删除 reality-keys.txt 并重启服务${RESET}"
  echo -ne "${GRAY}确认修改为 $new_uuid 并重启? [y/N]: ${RESET}"
  read -r confirm
  if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    set_val UUID "$new_uuid"
    rm -f "$REALITY_KEY_FILE"
    do_restart
    echo -e "${GREEN}UUID 已更新${RESET}"
    press_any_key
  fi
}

config_argo() {
  while true; do
    clear
    echo -e "${GREEN}======= Argo 隧道模式 =======${RESET}"
    local cur_domain cur_auth cur_port cur_disable cur_protocol
    cur_domain=$(get_val ARGO_DOMAIN)
    cur_auth=$(get_val ARGO_AUTH)
    cur_port=$(get_val ARGO_PORT)
    cur_disable=$(get_val DISABLE_ARGO)
    cur_protocol=$(get_val ARGO_PROTOCOL)

    if [ "$cur_disable" = "true" ]; then
      echo -e "${GRAY}当前: ${RED}已禁用${RESET}"
    elif [ -n "$cur_domain" ] && [ -n "$cur_auth" ]; then
      echo -e "${GRAY}当前: ${CYAN}固定隧道 ($cur_domain)${RESET}"
    else
      echo -e "${GRAY}当前: ${CYAN}临时隧道${RESET}"
    fi
    echo -e "${GRAY}连接协议: ${CYAN}${cur_protocol:-http2(默认)}${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}1. 切换为临时隧道${RESET}"
    echo -e "${WHITE}2. 配置固定隧道${RESET}"
    echo -e "${WHITE}3. 禁用 Argo${RESET}"
    echo -e "${WHITE}4. 切换连接协议 (http2/quic/auto)${RESET}"
    echo -e "${WHITE}0. 返回${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -ne "${GRAY}请输入选项: ${RESET}"
    read -r opt
    case "$opt" in
      1)
        set_val ARGO_DOMAIN ""
        set_val ARGO_AUTH ""
        set_val DISABLE_ARGO ""
        do_restart
        press_any_key
        ;;
      2)
        echo -ne "${WHITE}ARGO_DOMAIN [当前: ${CYAN}${cur_domain:-空}${WHITE}]: ${RESET}"
        read -r new_domain
        echo -ne "${WHITE}ARGO_AUTH   [当前: ${CYAN}${cur_auth:0:12}...${WHITE}]: ${RESET}"
        read -r new_auth
        echo -ne "${WHITE}ARGO_PORT   [当前: ${CYAN}${cur_port:-8001}${WHITE}]: ${RESET}"
        read -r new_port
        set_val ARGO_DOMAIN "${new_domain:-$cur_domain}"
        set_val ARGO_AUTH "${new_auth:-$cur_auth}"
        set_val ARGO_PORT "${new_port:-${cur_port:-8001}}"
        set_val DISABLE_ARGO ""
        do_restart
        press_any_key
        ;;
      3)
        set_val DISABLE_ARGO "true"
        set_val ARGO_DOMAIN ""
        set_val ARGO_AUTH ""
        do_restart
        press_any_key
        ;;
      4)
        echo -e "${WHITE}1. http2 (默认推荐)  2. quic  3. auto${RESET}"
        read -p "选择: " popt
        case "$popt" in
          1) set_val ARGO_PROTOCOL "http2" ;;
          2) set_val ARGO_PROTOCOL "quic" ;;
          3) set_val ARGO_PROTOCOL "auto" ;;
        esac
        do_restart
        press_any_key
        ;;
      0) return ;;
    esac
  done
}

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
      set_val "$key" "$val"
      echo -e "${GREEN}已更新${RESET}"
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
        [ -n "$val" ] && { set_val REALITY_DOMAIN "$val"; rm -f "$REALITY_KEY_FILE"; }
        ;;
      5) _set_port SS_PORT     "$ss"     "Shadowsocks" ;;
      6) _set_port SOCKS5_PORT "$socks5" "SOCKS5" ;;
      7) _set_port TROJAN_PORT "$trojan" "Trojan" ;;
      8) _set_port ANYTLS_PORT "$anytls" "AnyTLS" ;;
      0) do_restart; return ;;
    esac
  done
}

_list_domain_certs() {
  [ -d "$DOMAIN_CERT_DIR" ] || return 0
  for d in "$DOMAIN_CERT_DIR"/*/; do
    [ -d "$d" ] || continue
    local dom
    dom="$(basename "$d")"
    [ -f "$d/cert.pem" ] && [ -f "$d/key.pem" ] && echo "$dom"
  done
}

config_cert_bind() {
  while true; do
    clear
    echo -e "${GREEN}======= 协议证书绑定 =======${RESET}"
    local avail
    avail="$(_list_domain_certs)"
    if [ -z "$avail" ]; then
      echo -e "${YELLOW}还没有已签发的域名证书，请先到主菜单「8. 域名证书」申请${RESET}"
      press_any_key; return
    fi
    echo -e "${GRAY}可用域名证书: ${CYAN}$(echo "$avail" | tr '\n' ' ')${RESET}"
    echo -e "${GRAY}当前连接域名: ${CYAN}$(get_val SERVER_DOMAIN || echo '使用公网IP')${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}1. Hysteria2  [${CYAN}$(get_val HY2_CERT_DOMAIN || echo '自签')${WHITE}]${RESET}"
    echo -e "${WHITE}2. TUIC       [${CYAN}$(get_val TUIC_CERT_DOMAIN || echo '自签')${WHITE}]${RESET}"
    echo -e "${WHITE}3. Trojan     [${CYAN}$(get_val TROJAN_CERT_DOMAIN || echo '自签')${WHITE}]${RESET}"
    echo -e "${WHITE}4. AnyTLS     [${CYAN}$(get_val ANYTLS_CERT_DOMAIN || echo '自签')${WHITE}]${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}5. 一键应用域名到全部协议并设为连接域名${RESET}"
    echo -e "${WHITE}6. 一键恢复全部自签证书与公网 IP${RESET}"
    echo -e "${WHITE}0. 返回${RESET}"
    read -p "选择: " popt
    case "$popt" in
      1)
        echo -ne "${WHITE}输入 Hysteria2 绑定的域名 (输入 0 恢复自签): ${RESET}"
        read -r dopt
        [ "$dopt" = "0" ] && set_val HY2_CERT_DOMAIN "" || { [ -n "$dopt" ] && set_val HY2_CERT_DOMAIN "$dopt"; }
        do_restart; press_any_key ;;
      2)
        echo -ne "${WHITE}输入 TUIC 绑定的域名 (输入 0 恢复自签): ${RESET}"
        read -r dopt
        [ "$dopt" = "0" ] && set_val TUIC_CERT_DOMAIN "" || { [ -n "$dopt" ] && set_val TUIC_CERT_DOMAIN "$dopt"; }
        do_restart; press_any_key ;;
      3)
        echo -ne "${WHITE}输入 Trojan 绑定的域名 (输入 0 恢复自签): ${RESET}"
        read -r dopt
        [ "$dopt" = "0" ] && set_val TROJAN_CERT_DOMAIN "" || { [ -n "$dopt" ] && set_val TROJAN_CERT_DOMAIN "$dopt"; }
        do_restart; press_any_key ;;
      4)
        echo -ne "${WHITE}输入 AnyTLS 绑定的域名 (输入 0 恢复自签): ${RESET}"
        read -r dopt
        [ "$dopt" = "0" ] && set_val ANYTLS_CERT_DOMAIN "" || { [ -n "$dopt" ] && set_val ANYTLS_CERT_DOMAIN "$dopt"; }
        do_restart; press_any_key ;;
      5)
        echo -ne "${WHITE}输入要一键应用的域名: ${RESET}"
        read -r dopt
        dopt="$(echo "$dopt" | tr -d '[:space:]')"
        if [ -n "$dopt" ]; then
          apply_domain_to_all_protos "$dopt"
        fi
        press_any_key ;;
      6)
        set_val SERVER_DOMAIN ""
        set_val HY2_CERT_DOMAIN ""
        set_val TUIC_CERT_DOMAIN ""
        set_val TROJAN_CERT_DOMAIN ""
        set_val ANYTLS_CERT_DOMAIN ""
        echo -e "${GREEN}已恢复全部自签证书与公网 IP 连接模式！${RESET}"
        do_restart; press_any_key ;;
      0) return ;;
      *) continue ;;
    esac
  done
}

config_extraports() {
  clear
  echo -e "${GREEN}======= 添加多端口 =======${RESET}"
  echo -ne "Hysteria2 额外端口(逗号分隔，留空清除)[当前: $(get_val HY2_EXTRA_PORTS)]: "
  read -r val
  set_val HY2_EXTRA_PORTS "$val"
  echo -ne "TUIC 额外端口(逗号分隔，留空清除)[当前: $(get_val TUIC_EXTRA_PORTS)]: "
  read -r val2
  set_val TUIC_EXTRA_PORTS "$val2"
  do_restart
  press_any_key
}

config_hop() {
  clear
  echo -e "${GREEN}======= 端口跳跃 =======${RESET}"
  echo -e "${YELLOW}提示：需 root + nftables/iptables${RESET}"
  echo -ne "Hysteria2 范围(如 20000-30000)[当前: $(get_val HY2_HOP_RANGE)]: "
  read -r val
  set_val HY2_HOP_RANGE "$val"
  echo -ne "TUIC 范围(如 20000-30000)[当前: $(get_val TUIC_HOP_RANGE)]: "
  read -r val2
  set_val TUIC_HOP_RANGE "$val2"
  do_restart
  press_any_key
}

config_komari() {
  clear
  echo -e "${GREEN}======= Komari 探针监控 =======${RESET}"
  local cur_dom cur_tk
  cur_dom=$(get_val KOMARI_DOMAIN)
  [ -z "$cur_dom" ] && cur_dom=$(get_val KOMARI_ENDPOINT)
  cur_tk=$(get_val KOMARI_TOKEN)
  echo -e "当前: 服务端=[${CYAN}${cur_dom:-未启用}${RESET}] Token=[${CYAN}${cur_tk:+已配置}${RESET}]"
  echo -e "${WHITE}1. 修改配置  2. 禁用监控  3. 查看探针日志  0. 返回${RESET}"
  read -p "请选择: " opt
  case "$opt" in
    1)
      read -p "Komari 服务端地址 (如 https://komari.example.com 或 http://IP:25774): " new_dom
      read -p "Komari 探针密钥 Token: " new_tk
      if [ -n "$new_dom" ] && [ -n "$new_tk" ]; then
        set_val KOMARI_DOMAIN "$new_dom"
        set_val KOMARI_ENDPOINT ""
        set_val KOMARI_TOKEN "$new_tk"
        [ -x "$KM_BIN" ] || download_komari || true
        do_restart
      fi
      ;;
    2)
      set_val KOMARI_DOMAIN ""
      set_val KOMARI_ENDPOINT ""
      set_val KOMARI_TOKEN ""
      pkill -f "komari-agent" 2>/dev/null || true
      do_restart
      ;;
    3)
      if [ -f "$KM_LOG" ]; then
        echo -e "${CYAN}=== 探针最新日志 ($KM_LOG) ===${RESET}"
        tail -n 30 "$KM_LOG"
      else
        echo -e "${RED}暂无探针日志文件 ($KM_LOG)${RESET}"
      fi
      ;;
  esac
  press_any_key
}

menu_update() {
  clear
  echo -e "${GREEN}======= 更新 sing-box =======${RESET}"
  local latest_ver
  latest_ver=$(curl -sL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
    | grep '"tag_name"' | sed 's/.*"tag_name": *"v\([^"]*\)".*/\1/' | head -1)
  echo -e "最新版本: ${GREEN}${latest_ver:+v}${latest_ver:-获取失败}${RESET}"
  read -p "确认下载并覆盖更新? [y/N]: " confirm
  if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
    rm -rf "$SB_DIR"
    do_restart
  fi
  press_any_key
}

menu_outbound() {
  clear
  echo -e "${GREEN}======= 出口设置 =======${RESET}"
  local cur_type cur_addr cur_port
  cur_type=$(grep '^TYPE=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)
  cur_addr=$(grep '^ADDR=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)
  cur_port=$(grep '^PORT=' "$OUTBOUND_FILE" 2>/dev/null | cut -d'=' -f2-)
  echo -e "当前出口: ${CYAN}${cur_type:-直连}${cur_addr:+://$cur_addr:$cur_port}${RESET}"
  echo -e "${WHITE}1. 设置 SOCKS5 出口  2. 设置 HTTP 出口  3. 恢复直连  0. 返回${RESET}"
  read -p "选项: " opt
  case "$opt" in
    1|2)
      local t="socks"
      [ "$opt" = "2" ] && t="http"
      read -p "服务器地址: " a
      read -p "服务器端口: " p
      read -p "用户名（留空无认证）: " u
      local pass=""
      [ -n "$u" ] && read -p "密码: " pass
      if [ -n "$a" ] && [ -n "$p" ]; then
        cat > "$OUTBOUND_FILE" << EOF
TYPE=${t}
ADDR=${a}
PORT=${p}
USER=${u}
PASS=${pass}
EOF
        chmod 600 "$OUTBOUND_FILE"
        do_restart
      fi
      ;;
    3)
      rm -f "$OUTBOUND_FILE"
      do_restart
      ;;
  esac
  press_any_key
}

apply_domain_to_all_protos() {
  local dom="$1"
  [ -z "$dom" ] && return
  set_val SERVER_DOMAIN "$dom"
  set_val HY2_CERT_DOMAIN "$dom"
  set_val TUIC_CERT_DOMAIN "$dom"
  set_val TROJAN_CERT_DOMAIN "$dom"
  set_val ANYTLS_CERT_DOMAIN "$dom"
  echo -e "${GREEN}已将 ${CYAN}${dom}${GREEN} 设为全局连接域名，并绑定至全部直连协议！${RESET}"
  do_restart
}

ensure_acme() {
  [ -x "$ACME_HOME/acme.sh" ] && return 0
  echo -e "${YELLOW}正在安装 acme.sh...${RESET}"
  mkdir -p "$STATE_DIR"
  local tmp_acme="/tmp/acme-install-$$"
  rm -rf "$tmp_acme" && mkdir -p "$tmp_acme"
  if command -v curl >/dev/null 2>&1; then
    curl -sL https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh -o "$tmp_acme/acme.sh"
  else
    wget -q https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh -O "$tmp_acme/acme.sh"
  fi
  chmod +x "$tmp_acme/acme.sh"
  (cd "$tmp_acme" && ./acme.sh --install --home "$ACME_HOME" --force >/dev/null 2>&1) || true
  rm -rf "$tmp_acme"
  [ -x "$ACME_HOME/acme.sh" ]
}

menu_domain_cert() {
  while true; do
    clear
    echo -e "${GREEN}======= 域名证书 (acme.sh) =======${RESET}"
    local certs
    certs="$(_list_domain_certs)"
    echo -e "${GRAY}已签发/导入证书:${RESET} ${CYAN}${certs:-无}${RESET}"
    echo -e "${GRAY}当前连接域名:${RESET}   ${CYAN}$(get_val SERVER_DOMAIN || echo '使用公网IP')${RESET}"
    echo -e "${GRAY}--------------------------------${RESET}"
    echo -e "${WHITE}1. 申请新域名证书 (HTTP-01)${RESET}"
    echo -e "${WHITE}2. 手动导入已有证书${RESET}"
    echo -e "${WHITE}3. 续期指定证书${RESET}"
    echo -e "${WHITE}4. 删除证书${RESET}"
    echo -e "${WHITE}0. 返回${RESET}"
    read -p "选项: " opt
    case "$opt" in
      1)
        ensure_acme || { warn "acme.sh 初始化失败"; press_any_key; continue; }
        read -p "域名（需已解析到本机 IP，80 端口可用）: " domain
        domain="$(echo "$domain" | tr -d '[:space:]')"
        if [ -n "$domain" ]; then
          mkdir -p "$DOMAIN_CERT_DIR/$domain"
          "$ACME_HOME/acme.sh" --home "$ACME_HOME" --register-account -m "admin@${domain}" --server letsencrypt >/dev/null 2>&1 || true
          if "$ACME_HOME/acme.sh" --home "$ACME_HOME" --issue -d "$domain" --standalone --httpport 80 --server letsencrypt --force; then
            "$ACME_HOME/acme.sh" --home "$ACME_HOME" --install-cert -d "$domain" \
              --key-file "$DOMAIN_CERT_DIR/$domain/key.pem" \
              --fullchain-file "$DOMAIN_CERT_DIR/$domain/cert.pem" >/dev/null 2>&1
            echo -e "${GREEN}证书申请成功！${RESET}"
            echo -ne "${YELLOW}是否将此域名一键应用到全部直连协议（连接地址替换为域名并绑定证书）？[Y/n]: ${RESET}"
            read -r _apply_all
            case "$_apply_all" in
              n|N) ;;
              *) apply_domain_to_all_protos "$domain" ;;
            esac
          else
            echo -e "${RED}申请失败，请确认域名解析及 80 端口未被占用${RESET}"
            rm -rf "$DOMAIN_CERT_DIR/$domain"
          fi
          press_any_key
        fi
        ;;
      2)
        read -p "域名标识: " domain
        domain="$(echo "$domain" | tr -d '[:space:]')"
        read -p "cert.pem 绝对路径: " cpath
        read -p "key.pem 绝对路径: " kpath
        if [ -f "$cpath" ] && [ -f "$kpath" ] && [ -n "$domain" ]; then
          mkdir -p "$DOMAIN_CERT_DIR/$domain"
          cp "$cpath" "$DOMAIN_CERT_DIR/$domain/cert.pem"
          cp "$kpath" "$DOMAIN_CERT_DIR/$domain/key.pem"
          chmod 600 "$DOMAIN_CERT_DIR/$domain/key.pem"
          echo -e "${GREEN}证书导入成功！${RESET}"
          echo -ne "${YELLOW}是否将此域名一键应用到全部直连协议（连接地址替换为域名并绑定证书）？[Y/n]: ${RESET}"
          read -r _apply_all
          case "$_apply_all" in
            n|N) ;;
            *) apply_domain_to_all_protos "$domain" ;;
          esac
        fi
        press_any_key
        ;;
      3)
        read -p "要续期的域名: " domain
        domain="$(echo "$domain" | tr -d '[:space:]')"
        if [ -d "$DOMAIN_CERT_DIR/$domain" ] && [ -x "$ACME_HOME/acme.sh" ]; then
          echo -e "${YELLOW}正在续期证书...${RESET}"
          if "$ACME_HOME/acme.sh" --home "$ACME_HOME" --renew -d "$domain" --force --standalone --httpport 80; then
            "$ACME_HOME/acme.sh" --home "$ACME_HOME" --install-cert -d "$domain" \
              --key-file "$DOMAIN_CERT_DIR/$domain/key.pem" \
              --fullchain-file "$DOMAIN_CERT_DIR/$domain/cert.pem" >/dev/null 2>&1
            echo -e "${GREEN}证书续期并同步更新成功！${RESET}"
            do_restart
          else
            echo -e "${RED}续期失败，请确认 80 端口未被其他服务占用${RESET}"
          fi
        fi
        press_any_key
        ;;
      4)
        read -p "要删除的域名: " domain
        domain="$(echo "$domain" | tr -d '[:space:]')"
        rm -rf "$DOMAIN_CERT_DIR/$domain"
        [ -x "$ACME_HOME/acme.sh" ] && "$ACME_HOME/acme.sh" --home "$ACME_HOME" --remove -d "$domain" >/dev/null 2>&1 || true
        [ "$(get_val SERVER_DOMAIN)" = "$domain" ] && set_val SERVER_DOMAIN ""
        for k in HY2_CERT_DOMAIN TUIC_CERT_DOMAIN TROJAN_CERT_DOMAIN ANYTLS_CERT_DOMAIN; do
          [ "$(get_val "$k")" = "$domain" ] && set_val "$k" ""
        done
        do_restart
        echo -e "${GREEN}已删除${RESET}"
        press_any_key
        ;;
      0) return ;;
    esac
  done
}

# ==============================================================================
# 模块 3: 快捷子命令 (edit / uninstall)
# ==============================================================================
do_edit() {
  load_env_file
  echo -e "${GREEN}========== 修改配置 (直接回车保留原值) ==========${NC}"
  read -p "UUID         [${UUID:-自动生成}]: "          IN_UUID
  read -p "NAME         [${NAME:-自动识别}]: "          IN_NAME
  read -p "ARGO_DOMAIN  [${ARGO_DOMAIN:-临时隧道}]: "   IN_ARGO_DOMAIN
  read -p "ARGO_AUTH    [${ARGO_AUTH:+已设置}]: "       IN_ARGO_AUTH
  read -p "DISABLE_ARGO [${DISABLE_ARGO:-false}]: "     IN_DISABLE_ARGO
  read -p "HY2_PORT     [${HY2_PORT:-未启用}]: "        IN_HY2_PORT
  read -p "TUIC_PORT    [${TUIC_PORT:-未启用}]: "       IN_TUIC_PORT
  read -p "REALITY_PORT [${REALITY_PORT:-未启用}]: "    IN_REALITY_PORT
  read -p "REALITY_DOMAIN [${REALITY_DOMAIN:-www.iij.ad.jp}]: " IN_REALITY_DOMAIN
  read -p "SS_PORT      [${SS_PORT:-未启用}]: "         IN_SS_PORT
  read -p "SOCKS5_PORT  [${SOCKS5_PORT:-未启用}]: "     IN_SOCKS5_PORT
  read -p "TROJAN_PORT  [${TROJAN_PORT:-未启用}]: "     IN_TROJAN_PORT
  read -p "ANYTLS_PORT  [${ANYTLS_PORT:-未启用}]: "     IN_ANYTLS_PORT
  read -p "KOMARI_DOMAIN[${KOMARI_DOMAIN:-未启用}]: "   IN_KOMARI_DOMAIN
  read -p "KOMARI_TOKEN [${KOMARI_TOKEN:+已设置}]: "     IN_KOMARI_TOKEN

  [ -n "$IN_UUID" ] && set_val UUID "$IN_UUID"
  [ -n "$IN_NAME" ] && set_val NAME "$IN_NAME"
  [ -n "$IN_ARGO_DOMAIN" ] && set_val ARGO_DOMAIN "$IN_ARGO_DOMAIN"
  [ -n "$IN_ARGO_AUTH" ] && set_val ARGO_AUTH "$IN_ARGO_AUTH"
  [ -n "$IN_DISABLE_ARGO" ] && set_val DISABLE_ARGO "$IN_DISABLE_ARGO"
  [ -n "$IN_HY2_PORT" ] && set_val HY2_PORT "$IN_HY2_PORT"
  [ -n "$IN_TUIC_PORT" ] && set_val TUIC_PORT "$IN_TUIC_PORT"
  [ -n "$IN_REALITY_PORT" ] && set_val REALITY_PORT "$IN_REALITY_PORT"
  [ -n "$IN_REALITY_DOMAIN" ] && set_val REALITY_DOMAIN "$IN_REALITY_DOMAIN"
  [ -n "$IN_SS_PORT" ] && set_val SS_PORT "$IN_SS_PORT"
  [ -n "$IN_SOCKS5_PORT" ] && set_val SOCKS5_PORT "$IN_SOCKS5_PORT"
  [ -n "$IN_TROJAN_PORT" ] && set_val TROJAN_PORT "$IN_TROJAN_PORT"
  [ -n "$IN_ANYTLS_PORT" ] && set_val ANYTLS_PORT "$IN_ANYTLS_PORT"
  [ -n "$IN_KOMARI_DOMAIN" ] && set_val KOMARI_DOMAIN "$IN_KOMARI_DOMAIN"
  [ -n "$IN_KOMARI_TOKEN" ] && set_val KOMARI_TOKEN "$IN_KOMARI_TOKEN"

  do_restart
  echo -e "${GREEN}配置已保存并重启${NC}"
}

do_uninstall() {
  clear
  echo -e "${RED}======= 彻底卸载 singbox =======${RESET}"
  read -p "确认彻底删除所有文件、配置与服务? [yes/N]: " confirm
  if [ "$confirm" != "yes" ]; then
    echo "已取消"
    return
  fi

  echo "正在清理并停止服务..."
  systemctl --user stop singbox 2>/dev/null || true
  systemctl --user disable singbox 2>/dev/null || true
  rm -f "$SVCFILE"
  systemctl --user daemon-reload 2>/dev/null || true

  do_stop
  (crontab -l 2>/dev/null | grep -v "singbox autostart") | crontab - 2>/dev/null || true

  for RC in "$HOME_DIR/.bashrc" "$HOME_DIR/.profile" "$HOME_DIR/.bash_profile" "$HOME_DIR/.zshrc"; do
    sed -i '/singbox/d' "$RC" 2>/dev/null || true
  done

  [ -x "$ACME_HOME/acme.sh" ] && "$ACME_HOME/acme.sh" --uninstall >/dev/null 2>&1 || true

  command -v nft >/dev/null 2>&1 && nft delete table inet singbox_hop >/dev/null 2>&1 || true
  if command -v iptables >/dev/null 2>&1; then
    iptables -t nat -F SINGBOX_HOP 2>/dev/null || true
    iptables -t nat -D PREROUTING -j SINGBOX_HOP 2>/dev/null || true
    iptables -t nat -X SINGBOX_HOP 2>/dev/null || true
  fi

  rm -rf "$APP_DIR"
  rm -rf /tmp/sb-bin
  rm -f "$LOCAL_BIN/sb" "$LOCAL_BIN/sb-sub" "$LOCAL_BIN/sb-log" "$LOCAL_BIN/sb-del" "$LOCAL_BIN/sb-edit"
  rm -f /usr/local/bin/sb /usr/local/bin/sb-sub /usr/local/bin/sb-log /usr/local/bin/sb-del /usr/local/bin/sb-edit 2>/dev/null || true

  echo -e "${GREEN}卸载完成！${RESET}"
  exit 0
}

do_cron_renew() {
  load_env_file
  [ -d "$DOMAIN_CERT_DIR" ] || exit 0
  [ -x "$ACME_HOME/acme.sh" ] || exit 0
  local renewed=0
  for d in "$DOMAIN_CERT_DIR"/*/; do
    [ -d "$d" ] || continue
    local dom
    dom="$(basename "$d")"
    if "$ACME_HOME/acme.sh" --home "$ACME_HOME" --renew -d "$dom" --standalone --httpport 80 >/dev/null 2>&1; then
      "$ACME_HOME/acme.sh" --home "$ACME_HOME" --install-cert -d "$dom" \
        --key-file "$DOMAIN_CERT_DIR/$dom/key.pem" \
        --fullchain-file "$DOMAIN_CERT_DIR/$dom/cert.pem" >/dev/null 2>&1
      renewed=1
    fi
  done
  [ "$renewed" = "1" ] && do_restart
}

# ==============================================================================
# 模块 4: 守护进程运行器 (do_run / 原 singbox.sh 核心主体)
# ==============================================================================
do_run() {
  load_env_file

  UUID="${UUID:-}"
  PORT="${PORT:-3000}"
  ARGO_PORT="${ARGO_PORT:-}"
  NAME="${NAME:-}"
  ARGO_DOMAIN="${ARGO_DOMAIN:-}"
  ARGO_AUTH="${ARGO_AUTH:-}"
  DISABLE_ARGO="${DISABLE_ARGO:-}"
  ARGO_PROTOCOL="${ARGO_PROTOCOL:-http2}"
  HY2_PORT="${HY2_PORT:-}"
  TUIC_PORT="${TUIC_PORT:-}"
  REALITY_PORT="${REALITY_PORT:-}"
  REALITY_DOMAIN="${REALITY_DOMAIN:-www.iij.ad.jp}"
  SS_PORT="${SS_PORT:-}"
  SOCKS5_PORT="${SOCKS5_PORT:-}"
  TROJAN_PORT="${TROJAN_PORT:-}"
  ANYTLS_PORT="${ANYTLS_PORT:-}"
  KOMARI_DOMAIN="${KOMARI_DOMAIN:-${KOMARI_ENDPOINT:-}}"
  KOMARI_TOKEN="${KOMARI_TOKEN:-}"
  HY2_CERT_DOMAIN="${HY2_CERT_DOMAIN:-}"
  TUIC_CERT_DOMAIN="${TUIC_CERT_DOMAIN:-}"
  TROJAN_CERT_DOMAIN="${TROJAN_CERT_DOMAIN:-}"
  ANYTLS_CERT_DOMAIN="${ANYTLS_CERT_DOMAIN:-}"
  HY2_EXTRA_PORTS="${HY2_EXTRA_PORTS:-}"
  HY2_HOP_RANGE="${HY2_HOP_RANGE:-}"
  TUIC_EXTRA_PORTS="${TUIC_EXTRA_PORTS:-}"
  TUIC_HOP_RANGE="${TUIC_HOP_RANGE:-}"
  IP_VERSION="${IP_VERSION:-4}"
  SERVER_DOMAIN="${SERVER_DOMAIN:-}"
  PUBLIC_IP="${PUBLIC_IP:-${IP:-}}"
  CF_PREFER_HOST="${CF_PREFER_HOST:-cdns.doon.eu.org}"
  WS_PATH="${WS_PATH:-/fengyue}"

  setup_port_hop() {
    [ "$(id -u)" = "0" ] || return 0
    command -v nft >/dev/null 2>&1 && nft delete table inet singbox_hop 2>/dev/null || true
    if command -v iptables >/dev/null 2>&1; then
      iptables -t nat -F SINGBOX_HOP 2>/dev/null || true
      iptables -t nat -D PREROUTING -j SINGBOX_HOP 2>/dev/null || true
      iptables -t nat -X SINGBOX_HOP 2>/dev/null || true
    fi

    local _has_rule=0
    if command -v iptables >/dev/null 2>&1; then
      iptables -t nat -N SINGBOX_HOP 2>/dev/null || true
      if [ -n "$HY2_PORT" ] && [ -n "$HY2_HOP_RANGE" ]; then
        local s="${HY2_HOP_RANGE%%-*}" e="${HY2_HOP_RANGE##*-}"
        iptables -t nat -A SINGBOX_HOP -p udp --dport "${s}:${e}" -j REDIRECT --to-ports "$HY2_PORT" 2>/dev/null && _has_rule=1
      fi
      if [ -n "$TUIC_PORT" ] && [ -n "$TUIC_HOP_RANGE" ]; then
        local s="${TUIC_HOP_RANGE%%-*}" e="${TUIC_HOP_RANGE##*-}"
        iptables -t nat -A SINGBOX_HOP -p udp --dport "${s}:${e}" -j REDIRECT --to-ports "$TUIC_PORT" 2>/dev/null && _has_rule=1
      fi
      [ "$_has_rule" = "1" ] && iptables -t nat -I PREROUTING -j SINGBOX_HOP 2>/dev/null || true
    fi
  }

  mkdir -p "$STATE_DIR" "$APP_DIR"
  chmod 700 "$STATE_DIR" 2>/dev/null || true

  mkdir -p "$BIN_DIR" 2>/dev/null || {
    BIN_DIR="$HOME_DIR/sb-bin"
    SB_DIR="$BIN_DIR/singbox"
    SB_BIN="$SB_DIR/sing-box"
    CF_BIN="$BIN_DIR/cloudflared"
    KM_BIN="$BIN_DIR/komari-agent"
    mkdir -p "$BIN_DIR"
  }

  ensure_basic_deps

  if [ -n "$UUID" ]; then
    valid_uuid "$UUID" || die "UUID 格式不合法: ${UUID}"
    echo "$UUID" > "$UUID_FILE"
  elif [ -f "$UUID_FILE" ]; then
    UUID="$(cat "$UUID_FILE")"
    valid_uuid "$UUID" || die "uuid.txt 中的 UUID 格式已损坏"
  else
    UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
      || python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null \
      || od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8$9}')"
    echo "$UUID" > "$UUID_FILE"
  fi
  chmod 600 "$UUID_FILE" 2>/dev/null || true

  SOCKS5_USER="${UUID%%-*}"
  SOCKS5_PASS="${UUID##*-}"

  SS_PASS=""
  if command -v python3 >/dev/null 2>&1; then
    SS_PASS="$(python3 -c "u='$UUID'.replace('-','')[:32]; import base64, binascii; print(base64.b64encode(binascii.unhexlify(u)).decode())" 2>/dev/null)" || SS_PASS=""
  fi
  if [ -z "$SS_PASS" ] && command -v openssl >/dev/null 2>&1; then
    _hex="$(echo "$UUID" | tr -d '-' | cut -c1-32)"
    _hexesc="$(printf '%s' "$_hex" | sed 's/\(..\)/\\x\1/g')"
    SS_PASS="$(printf "$_hexesc" | openssl base64 -A 2>/dev/null)" || SS_PASS=""
  fi
  [ -z "$SS_PASS" ] && SS_PASS="$(head -c 16 /dev/urandom 2>/dev/null | b64)"

  case "$(uname -m)" in
    x86_64|amd64)  SB_ARCH="amd64";  CF_ARCH="linux-amd64"; KM_ARCH="linux-amd64" ;;
    aarch64|arm64) SB_ARCH="arm64";  CF_ARCH="linux-arm64"; KM_ARCH="linux-arm64" ;;
    armv7*|armv6*) SB_ARCH="armv7";  CF_ARCH="linux-arm";   KM_ARCH="linux-arm"   ;;
    i386|i686)     SB_ARCH="386";    CF_ARCH="linux-386";   KM_ARCH="linux-386"   ;;
    *)             SB_ARCH="amd64";  CF_ARCH="linux-amd64"; KM_ARCH="linux-amd64" ;;
  esac

  download_singbox() {
    mkdir -p "$SB_DIR"
    log "正在检查/获取 sing-box..."
    local SB_VER
    SB_VER="$(http_get 'https://api.github.com/repos/SagerNet/sing-box/releases/latest' \
      | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
    [ -z "$SB_VER" ] && SB_VER="v1.12.0"

    local _vnum="${SB_VER#v}"
    for _suffix in "-musl" ""; do
      local _asset="sing-box-${_vnum}-linux-${SB_ARCH}${_suffix}.tar.gz"
      if dl "https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/${_asset}" /tmp/sing-box.tar.gz; then
        if tar -tzf /tmp/sing-box.tar.gz >/dev/null 2>&1; then
          tar -xzf /tmp/sing-box.tar.gz -C "$SB_DIR" --strip-components=1
          chmod +x "$SB_BIN"
          rm -f /tmp/sing-box.tar.gz
          if "$SB_BIN" version >/dev/null 2>&1; then return 0; fi
        fi
      fi
    done
    return 1
  }

  download_cloudflared() {
    log "正在下载 cloudflared..."
    if dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${CF_ARCH}" "$CF_BIN"; then
      chmod +x "$CF_BIN"
      if "$CF_BIN" --version >/dev/null 2>&1; then return 0; fi
    fi
    warn "cloudflared 下载或校验失败，Argo 隧道本次将禁用"
    DISABLE_ARGO="true"
    return 1
  }

  pkill -f "$SB_BIN" 2>/dev/null || true
  pkill -f "$CF_BIN" 2>/dev/null || true
  pkill -f "$KM_BIN" 2>/dev/null || true

  [ -x "$SB_BIN" ] || download_singbox || die "sing-box 下载失败"
  if [ "${DISABLE_ARGO:-}" != "true" ]; then
    [ -x "$CF_BIN" ] || download_cloudflared || true
  fi
  if [ -n "$KOMARI_DOMAIN" ] && [ -n "$KOMARI_TOKEN" ]; then
    [ -x "$KM_BIN" ] || download_komari || true
  fi

  rm -f "$USED_PORTS_FILE"
  if [ "${DISABLE_ARGO:-}" != "true" ]; then
    if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
      ARGO_PORT="${ARGO_PORT:-8001}"
    else
      ARGO_PORT="${ARGO_PORT:-$(get_free_port)}"
    fi
    echo "$ARGO_PORT" >> "$USED_PORTS_FILE"
  fi

  if [ -z "$NAME" ]; then
    local COUNTRY ASN_ORG
    COUNTRY="$(http_get 'https://ipinfo.io/country' | tr -d '[:space:]')"
    ASN_ORG="$(http_get 'https://ipinfo.io/org' | sed -e 's/^AS[0-9]* //' -e 's/,\? *Inc\.*//' | cut -c1-20)"
    if [ -n "$COUNTRY" ] && [ -n "$ASN_ORG" ]; then
      NAME="${COUNTRY}-${ASN_ORG}"
    elif [ -n "$COUNTRY" ]; then
      NAME="${COUNTRY}-sbx"
    else
      NAME="sbx"
    fi
  fi
  NAME_ENCODED="$(url_encode "$NAME")"

  if [ -z "$PUBLIC_IP" ] && { [ -n "$HY2_PORT" ] || [ -n "$TUIC_PORT" ] || [ -n "$REALITY_PORT" ] || [ -n "$SS_PORT" ] || [ -n "$SOCKS5_PORT" ] || [ -n "$TROJAN_PORT" ] || [ -n "$ANYTLS_PORT" ]; }; then
    local _sources=()
    if [ "$IP_VERSION" = "6" ]; then
      _sources=('https://api6.ipify.org' 'https://api64.ipify.org' 'https://ifconfig.co/ip')
    else
      _sources=('https://api.ipify.org' 'https://ipinfo.io/ip' 'https://ifconfig.co/ip' 'https://icanhazip.com' 'https://api64.ipify.org')
    fi
    for _ipsrc in "${_sources[@]}"; do
      _cand="$(http_get "$_ipsrc" | tr -d '[:space:]')"
      if valid_ip "$_cand"; then PUBLIC_IP="$_cand"; break; fi
    done
  fi

  CERT_PATH=""
  KEY_PATH=""
  if [ -n "$HY2_PORT" ] || [ -n "$TUIC_PORT" ] || [ -n "$TROJAN_PORT" ] || [ -n "$ANYTLS_PORT" ]; then
    mkdir -p "$CERT_DIR"
    CERT_PATH="$CERT_DIR/cert.pem"
    KEY_PATH="$CERT_DIR/key.pem"
    if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
      if command -v openssl >/dev/null 2>&1; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 3650 -nodes \
          -keyout "$KEY_PATH" -out "$CERT_PATH" \
          -subj "/CN=bing.com/O=Microsoft/C=US" 2>/dev/null
      fi
    fi
    chmod 600 "$KEY_PATH" 2>/dev/null || true
  fi

  resolve_cert_for() {
    local _dom="$1"
    if [ -n "$_dom" ] && [ -f "$DOMAIN_CERT_DIR/$_dom/cert.pem" ] && [ -f "$DOMAIN_CERT_DIR/$_dom/key.pem" ]; then
      _RC_CERT="$DOMAIN_CERT_DIR/$_dom/cert.pem"
      _RC_KEY="$DOMAIN_CERT_DIR/$_dom/key.pem"
      _RC_SNI="$_dom"
      _RC_INSECURE=0
    else
      _RC_CERT="$CERT_PATH"
      _RC_KEY="$KEY_PATH"
      _RC_SNI=""
      _RC_INSECURE=1
    fi
  }

  resolve_cert_for "$HY2_CERT_DOMAIN"; HY2_TLS_CERT="$_RC_CERT"; HY2_TLS_KEY="$_RC_KEY"; HY2_TLS_SNI="$_RC_SNI"; HY2_TLS_INSECURE="$_RC_INSECURE"
  resolve_cert_for "$TUIC_CERT_DOMAIN"; TUIC_TLS_CERT="$_RC_CERT"; TUIC_TLS_KEY="$_RC_KEY"; TUIC_TLS_SNI="$_RC_SNI"; TUIC_TLS_INSECURE="$_RC_INSECURE"
  resolve_cert_for "$TROJAN_CERT_DOMAIN"; TROJAN_TLS_CERT="$_RC_CERT"; TROJAN_TLS_KEY="$_RC_KEY"; TROJAN_TLS_SNI="$_RC_SNI"; TROJAN_TLS_INSECURE="$_RC_INSECURE"
  resolve_cert_for "$ANYTLS_CERT_DOMAIN"; ANYTLS_TLS_CERT="$_RC_CERT"; ANYTLS_TLS_KEY="$_RC_KEY"; ANYTLS_TLS_SNI="$_RC_SNI"; ANYTLS_TLS_INSECURE="$_RC_INSECURE"

  REALITY_PRIV=""
  REALITY_PUB=""
  if [ -n "$REALITY_PORT" ]; then
    if [ -f "$REALITY_KEY_FILE" ]; then
      REALITY_PRIV="$(grep '^PrivateKey:' "$REALITY_KEY_FILE" | sed 's/PrivateKey: *//')"
      REALITY_PUB="$(grep  '^PublicKey:'  "$REALITY_KEY_FILE" | sed 's/PublicKey: *//')"
    fi
    if [ -z "$REALITY_PRIV" ] || [ -z "$REALITY_PUB" ]; then
      local KEYPAIR
      KEYPAIR="$("$SB_BIN" generate reality-keypair 2>/dev/null || true)"
      REALITY_PRIV="$(echo "$KEYPAIR" | grep PrivateKey | sed 's/PrivateKey: *//')"
      REALITY_PUB="$(echo  "$KEYPAIR" | grep PublicKey  | sed 's/PublicKey: *//')"
      if [ -n "$REALITY_PRIV" ] && [ -n "$REALITY_PUB" ]; then
        printf 'PrivateKey: %s\nPublicKey: %s\n' "$REALITY_PRIV" "$REALITY_PUB" > "$REALITY_KEY_FILE"
        chmod 600 "$REALITY_KEY_FILE"
      else
        REALITY_PORT=""
      fi
    fi
  fi

  EXTRA_OUTBOUND_JSON=""
  CUSTOM_OUT_TYPE=""
  if [ -f "$OUTBOUND_FILE" ]; then
    CUSTOM_OUT_TYPE="$(grep '^TYPE=' "$OUTBOUND_FILE" | cut -d'=' -f2-)"
    local o_addr o_port o_user o_pass
    o_addr="$(grep '^ADDR=' "$OUTBOUND_FILE" | cut -d'=' -f2-)"
    o_port="$(grep '^PORT=' "$OUTBOUND_FILE" | cut -d'=' -f2-)"
    o_user="$(grep '^USER=' "$OUTBOUND_FILE" | cut -d'=' -f2-)"
    o_pass="$(grep '^PASS=' "$OUTBOUND_FILE" | cut -d'=' -f2-)"
    if [ -n "$o_addr" ] && [ -n "$o_port" ]; then
      if [ -n "$o_user" ]; then
        EXTRA_OUTBOUND_JSON=",
    {
      \"type\": \"${CUSTOM_OUT_TYPE}\",
      \"tag\": \"custom-out\",
      \"server\": \"${o_addr}\",
      \"server_port\": ${o_port},
      \"username\": \"${o_user}\",
      \"password\": \"${o_pass}\"
    }"
      else
        EXTRA_OUTBOUND_JSON=",
    {
      \"type\": \"${CUSTOM_OUT_TYPE}\",
      \"tag\": \"custom-out\",
      \"server\": \"${o_addr}\",
      \"server_port\": ${o_port}
    }"
      fi
    fi
  fi

  HY2_ACTIVE=0; TUIC_ACTIVE=0; REALITY_ACTIVE=0; SS_ACTIVE=0; SOCKS5_ACTIVE=0; TROJAN_ACTIVE=0; ANYTLS_ACTIVE=0
  [ -n "$HY2_PORT" ]     && port_ok "$HY2_PORT"     && HY2_ACTIVE=1     || true
  [ -n "$TUIC_PORT" ]    && port_ok "$TUIC_PORT"    && TUIC_ACTIVE=1    || true
  [ -n "$REALITY_PORT" ] && port_ok "$REALITY_PORT" && REALITY_ACTIVE=1 || true
  [ -n "$SS_PORT" ] && [ -n "$SS_PASS" ] && port_ok "$SS_PORT" && SS_ACTIVE=1 || true
  [ -n "$SOCKS5_PORT" ]  && port_ok "$SOCKS5_PORT"  && SOCKS5_ACTIVE=1  || true
  [ -n "$TROJAN_PORT" ]  && port_ok "$TROJAN_PORT"  && TROJAN_ACTIVE=1  || true
  [ -n "$ANYTLS_PORT" ]  && port_ok "$ANYTLS_PORT"  && ANYTLS_ACTIVE=1  || true

  _inbounds=""
  _sep=""

  try_add_inbound() {
    local _label="$1" _snippet="$2"
    local _trial="${_inbounds}${_sep}
      ${_snippet}"
    local _tc="/tmp/sb-trycfg-$$.json"
    printf '{\n  "log": { "level": "warn" },\n  "inbounds": [\n    %s\n  ],\n  "outbounds": [{ "type": "direct", "tag": "direct" }]\n}\n' "$_trial" > "$_tc"
    if "$SB_BIN" check -c "$_tc" >/dev/null 2>&1; then
      _inbounds="$_trial"
      _sep=","
      rm -f "$_tc"
      return 0
    else
      warn "${_label} 配置校验未通过，已跳过该协议"
      rm -f "$_tc"
      return 1
    fi
  }

  if [ "${DISABLE_ARGO:-}" != "true" ]; then
    _vmess_json="{
        \"type\": \"vmess\",
        \"tag\": \"vmess-in\",
        \"listen\": \"127.0.0.1\",
        \"listen_port\": ${ARGO_PORT},
        \"users\": [{ \"uuid\": \"${UUID}\", \"alterId\": 0 }],
        \"transport\": { \"type\": \"ws\", \"path\": \"$(json_escape "$WS_PATH")\" }
      }"
    try_add_inbound "VMess/Argo" "$_vmess_json" || DISABLE_ARGO="true"
  fi

  HY2_ACTIVE_PORTS=""
  if [ "$HY2_ACTIVE" = "1" ]; then
    _hy2_ports="$HY2_PORT"
    [ -n "$HY2_EXTRA_PORTS" ] && _hy2_ports="$_hy2_ports $(parse_extra_ports "$HY2_EXTRA_PORTS")"
    _idx=0
    for _p in $_hy2_ports; do
      _idx=$((_idx + 1))
      _tag="hy2-in"
      [ "$_idx" -gt 1 ] && _tag="hy2-in-${_idx}"
      _hy2_json="{
        \"type\": \"hysteria2\",
        \"tag\": \"${_tag}\",
        \"listen\": \"::\",
        \"listen_port\": ${_p},
        \"users\": [{ \"password\": \"${UUID}\" }],
        \"masquerade\": \"https://bing.com\",
        \"tls\": {
          \"enabled\": true,
          \"alpn\": [\"h3\"],
          \"certificate_path\": \"${HY2_TLS_CERT}\",
          \"key_path\": \"${HY2_TLS_KEY}\"
        }
      }"
      if try_add_inbound "Hysteria2(${_p})" "$_hy2_json"; then
        HY2_ACTIVE_PORTS="${HY2_ACTIVE_PORTS}${HY2_ACTIVE_PORTS:+ }${_p}"
      fi
    done
    [ -z "$HY2_ACTIVE_PORTS" ] && HY2_ACTIVE=0
  fi

  TUIC_ACTIVE_PORTS=""
  if [ "$TUIC_ACTIVE" = "1" ]; then
    _tuic_ports="$TUIC_PORT"
    [ -n "$TUIC_EXTRA_PORTS" ] && _tuic_ports="$_tuic_ports $(parse_extra_ports "$TUIC_EXTRA_PORTS")"
    _idx=0
    for _p in $_tuic_ports; do
      _idx=$((_idx + 1))
      _tag="tuic-in"
      [ "$_idx" -gt 1 ] && _tag="tuic-in-${_idx}"
      _tuic_json="{
        \"type\": \"tuic\",
        \"tag\": \"${_tag}\",
        \"listen\": \"::\",
        \"listen_port\": ${_p},
        \"users\": [{ \"uuid\": \"${UUID}\", \"password\": \"${UUID}\" }],
        \"congestion_control\": \"bbr\",
        \"tls\": {
          \"enabled\": true,
          \"alpn\": [\"h3\"],
          \"certificate_path\": \"${TUIC_TLS_CERT}\",
          \"key_path\": \"${TUIC_TLS_KEY}\"
        }
      }"
      if try_add_inbound "TUIC(${_p})" "$_tuic_json"; then
        TUIC_ACTIVE_PORTS="${TUIC_ACTIVE_PORTS}${TUIC_ACTIVE_PORTS:+ }${_p}"
      fi
    done
    [ -z "$TUIC_ACTIVE_PORTS" ] && TUIC_ACTIVE=0
  fi

  if [ "$REALITY_ACTIVE" = "1" ]; then
    _reality_json="{
        \"type\": \"vless\",
        \"tag\": \"reality-in\",
        \"listen\": \"::\",
        \"listen_port\": ${REALITY_PORT},
        \"users\": [{ \"uuid\": \"${UUID}\", \"flow\": \"xtls-rprx-vision\" }],
        \"tls\": {
          \"enabled\": true,
          \"server_name\": \"${REALITY_DOMAIN}\",
          \"reality\": {
            \"enabled\": true,
            \"handshake\": { \"server\": \"${REALITY_DOMAIN}\", \"server_port\": 443 },
            \"private_key\": \"${REALITY_PRIV}\",
            \"short_id\": [\"\"]
          }
        }
      }"
    try_add_inbound "VLESS Reality" "$_reality_json" || REALITY_ACTIVE=0
  fi

  if [ "$SS_ACTIVE" = "1" ]; then
    _ss_json="{
        \"type\": \"shadowsocks\",
        \"tag\": \"ss-in\",
        \"listen\": \"::\",
        \"listen_port\": ${SS_PORT},
        \"network\": \"tcp\",
        \"method\": \"2022-blake3-aes-128-gcm\",
        \"password\": \"${SS_PASS}\"
      }"
    try_add_inbound "Shadowsocks" "$_ss_json" || SS_ACTIVE=0
  fi

  if [ "$SOCKS5_ACTIVE" = "1" ]; then
    _socks5_json="{
        \"type\": \"socks\",
        \"tag\": \"socks5-in\",
        \"listen\": \"::\",
        \"listen_port\": ${SOCKS5_PORT},
        \"users\": [{ \"username\": \"${SOCKS5_USER}\", \"password\": \"${SOCKS5_PASS}\" }]
      }"
    try_add_inbound "SOCKS5" "$_socks5_json" || SOCKS5_ACTIVE=0
  fi

  if [ "$TROJAN_ACTIVE" = "1" ]; then
    _trojan_json="{
        \"type\": \"trojan\",
        \"tag\": \"trojan-in\",
        \"listen\": \"::\",
        \"listen_port\": ${TROJAN_PORT},
        \"users\": [{ \"password\": \"${UUID}\" }],
        \"tls\": {
          \"enabled\": true,
          \"certificate_path\": \"${TROJAN_TLS_CERT}\",
          \"key_path\": \"${TROJAN_TLS_KEY}\"
        }
      }"
    try_add_inbound "Trojan" "$_trojan_json" || TROJAN_ACTIVE=0
  fi

  if [ "$ANYTLS_ACTIVE" = "1" ]; then
    _anytls_json="{
        \"type\": \"anytls\",
        \"tag\": \"anytls-in\",
        \"listen\": \"::\",
        \"listen_port\": ${ANYTLS_PORT},
        \"users\": [{ \"password\": \"${UUID}\" }],
        \"tls\": {
          \"enabled\": true,
          \"certificate_path\": \"${ANYTLS_TLS_CERT}\",
          \"key_path\": \"${ANYTLS_TLS_KEY}\"
        }
      }"
    try_add_inbound "AnyTLS" "$_anytls_json" || ANYTLS_ACTIVE=0
  fi

  [ -z "$_inbounds" ] && die "所有协议均校验失败，无法启动"

  local ROUTE_JSON=""
  [ -n "$EXTRA_OUTBOUND_JSON" ] && ROUTE_JSON=',
  "route": { "final": "custom-out" }'

  printf '{\n  "log": { "level": "warn", "timestamp": false },\n  "inbounds": [\n    %s\n  ],\n  "outbounds": [{ "type": "direct", "tag": "direct" }%s]%s\n}\n' \
    "$_inbounds" "$EXTRA_OUTBOUND_JSON" "$ROUTE_JSON" > "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"

  start_singbox() {
    "$SB_BIN" run -c "$CONFIG_FILE" &
    SB_PID=$!
    if [ "${DISABLE_ARGO:-}" != "true" ]; then
      wait_port 127.0.0.1 "$ARGO_PORT" 10
    fi
    if ! kill -0 $SB_PID 2>/dev/null; then return 1; fi
    log "sing-box 已启动 (PID: $SB_PID)"
    return 0
  }

  start_singbox || die "sing-box 启动失败"
  setup_port_hop

  KM_PID=""
  KM_ACTIVE=0
  start_komari() {
    [ -n "$KOMARI_DOMAIN" ] && [ -n "$KOMARI_TOKEN" ] || return 0
    local _endpoint
    _endpoint="$(format_komari_endpoint "$KOMARI_DOMAIN")"
    [ -x "$KM_BIN" ] || download_komari || return 1
    pkill -f "$KM_BIN" 2>/dev/null || true
    AGENT_IGNORE_UNSAFE_CERT=true nohup "$KM_BIN" -e "$_endpoint" -t "$KOMARI_TOKEN" >> "$KM_LOG" 2>&1 &
    KM_PID=$!
    KM_ACTIVE=1
    log "Komari 监控探针已启动 (PID: $KM_PID)"
    return 0
  }
  start_komari || true

  ARGO_HOST=""
  CF_PID=""
  start_cloudflared() {
    if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
      "$CF_BIN" tunnel --edge-ip-version auto --protocol "$ARGO_PROTOCOL" --no-autoupdate \
        run --token "$ARGO_AUTH" >/dev/null 2>&1 &
      CF_PID=$!
      sleep 3
      ARGO_HOST="$ARGO_DOMAIN"
    else
      rm -f "$CF_LOG"
      "$CF_BIN" tunnel --edge-ip-version auto --protocol "$ARGO_PROTOCOL" --no-autoupdate \
        --url "http://127.0.0.1:${ARGO_PORT}" \
        --logfile "$CF_LOG" >/dev/null 2>&1 &
      CF_PID=$!
      local i=0 _new_host=""
      while [ $i -lt 30 ]; do
        _new_host="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1 | sed 's|https://||')"
        [ -n "$_new_host" ] && break
        sleep 1
        i=$((i+1))
      done
      ARGO_HOST="${_new_host:-your-domain.com}"
    fi
    log "Argo 隧道域名: $ARGO_HOST"
    generate_sub
  }

  generate_sub() {
    local ALL_LINKS=""
    if [ "${DISABLE_ARGO:-}" != "true" ]; then
      local VMESS_JSON="{\"v\":\"2\",\"ps\":\"$(json_escape "$NAME")\",\"add\":\"cdns.doon.eu.org\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ARGO_HOST}\",\"path\":\"$(json_escape "$WS_PATH")\",\"tls\":\"tls\",\"sni\":\"${ARGO_HOST}\"}"
      ALL_LINKS="vmess://$(b64 "$VMESS_JSON")"
    fi

    # 全局直连连接主机名：优先使用自定义连接域名，留空则使用公网 IP
    local NODE_HOST="${SERVER_DOMAIN:-}"
    [ -z "$NODE_HOST" ] && [ -n "$PUBLIC_IP" ] && NODE_HOST="$(format_addr "$PUBLIC_IP")"

    if [ "$HY2_ACTIVE" = "1" ] && [ -n "$NODE_HOST" ]; then
      local _h_addr _h_sni _h_insec
      [ "$HY2_TLS_INSECURE" = "0" ] && { _h_addr="${HY2_TLS_SNI:-$NODE_HOST}"; _h_sni="$HY2_TLS_SNI"; _h_insec="0"; } || { _h_addr="$NODE_HOST"; _h_sni="www.bing.com"; _h_insec="1"; }
      for _p in $HY2_ACTIVE_PORTS; do
        local _link="hysteria2://${UUID}@${_h_addr}:${_p}?sni=${_h_sni}&insecure=${_h_insec}&alpn=h3&obfs=none#${NAME_ENCODED}"
        ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
      done
    fi

    if [ "$TUIC_ACTIVE" = "1" ] && [ -n "$NODE_HOST" ]; then
      local _t_addr _t_sni _t_insec
      [ "$TUIC_TLS_INSECURE" = "0" ] && { _t_addr="${TUIC_TLS_SNI:-$NODE_HOST}"; _t_sni="$TUIC_TLS_SNI"; _t_insec="0"; } || { _t_addr="$NODE_HOST"; _t_sni="www.bing.com"; _t_insec="1"; }
      for _p in $TUIC_ACTIVE_PORTS; do
        local _link="tuic://${UUID}:${UUID}@${_t_addr}:${_p}?sni=${_t_sni}&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=${_t_insec}#${NAME_ENCODED}"
        ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
      done
    fi

    if [ "$REALITY_ACTIVE" = "1" ] && [ -n "$NODE_HOST" ] && [ -n "$REALITY_PUB" ]; then
      local _link="vless://${UUID}@${NODE_HOST}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=firefox&pbk=${REALITY_PUB}&type=tcp&headerType=none#${NAME_ENCODED}"
      ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
    fi

    if [ "$SS_ACTIVE" = "1" ] && [ -n "$NODE_HOST" ]; then
      local SS_USERINFO
      SS_USERINFO="$(b64 "2022-blake3-aes-128-gcm:${SS_PASS}")"
      local _link="ss://${SS_USERINFO}@${NODE_HOST}:${SS_PORT}#${NAME_ENCODED}"
      ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
    fi

    if [ "$SOCKS5_ACTIVE" = "1" ] && [ -n "$NODE_HOST" ]; then
      local S5_USERINFO
      S5_USERINFO="$(b64 "${SOCKS5_USER}:${SOCKS5_PASS}")"
      local _link="socks://${S5_USERINFO}@${NODE_HOST}:${SOCKS5_PORT}#${NAME_ENCODED}"
      ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
    fi

    if [ "$TROJAN_ACTIVE" = "1" ] && [ -n "$NODE_HOST" ]; then
      local _tr_addr _tr_sni _tr_insec
      [ "$TROJAN_TLS_INSECURE" = "0" ] && { _tr_addr="${TROJAN_TLS_SNI:-$NODE_HOST}"; _tr_sni="$TROJAN_TLS_SNI"; _tr_insec="0"; } || { _tr_addr="$NODE_HOST"; _tr_sni="bing.com"; _tr_insec="1"; }
      local _link="trojan://${UUID}@${_tr_addr}:${TROJAN_PORT}?security=tls&sni=${_tr_sni}&allowInsecure=${_tr_insec}&fp=firefox#${NAME_ENCODED}"
      ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
    fi

    if [ "$ANYTLS_ACTIVE" = "1" ] && [ -n "$NODE_HOST" ]; then
      local _at_addr _at_sni _at_insec
      [ "$ANYTLS_TLS_INSECURE" = "0" ] && { _at_addr="${ANYTLS_TLS_SNI:-$NODE_HOST}"; _at_sni="$ANYTLS_TLS_SNI"; _at_insec="0"; } || { _at_addr="$NODE_HOST"; _at_sni="bing.com"; _at_insec="1"; }
      local _link="anytls://${UUID}@${_at_addr}:${ANYTLS_PORT}?sni=${_at_sni}&insecure=${_at_insec}#${NAME_ENCODED}"
      ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
    fi

    local SUB_BASE64
    SUB_BASE64="$(b64 "$ALL_LINKS")"
    echo "$SUB_BASE64" > "$SUB_FILE"
    chmod 600 "$SUB_FILE" 2>/dev/null || true

    log "================= 节点订阅刷新 ================="
    echo "$SUB_BASE64"
    log "================================================"
  }

  if [ "${DISABLE_ARGO:-}" != "true" ]; then
    start_cloudflared
  else
    generate_sub
  fi

  log "进入后台守护看门狗状态..."
  local SB_FAIL=0 CF_FAIL=0
  while true; do
    if ! kill -0 $SB_PID 2>/dev/null; then
      SB_FAIL=$((SB_FAIL + 1))
      warn "sing-box 异常退出 (第 $SB_FAIL 次)，正在重启..."
      sleep 3
      if start_singbox; then SB_FAIL=0; fi
    fi

    if [ "${DISABLE_ARGO:-}" != "true" ]; then
      if [ -z "$CF_PID" ] || ! kill -0 "$CF_PID" 2>/dev/null; then
        CF_FAIL=$((CF_FAIL + 1))
        warn "cloudflared 异常退出，正在重启并重获域名..."
        sleep 3
        start_cloudflared
      fi
    fi

    if [ "${KM_ACTIVE}" = "1" ]; then
      if [ -z "$KM_PID" ] || ! kill -0 "$KM_PID" 2>/dev/null; then
        warn "Komari 探针异常退出，正在重启..."
        sleep 2
        start_komari || true
      fi
    fi

    sleep 10
  done
}

# ==============================================================================
# 命令路由分发入口
# ==============================================================================
CMD="${1:-}"

case "$CMD" in
  install)
    shift; do_install "$@"
    ;;
  menu)
    shift; do_menu "$@"
    ;;
  sub)
    shift; do_sub "$@"
    ;;
  log)
    shift; do_log "$@"
    ;;
  edit)
    shift; do_edit "$@"
    ;;
  uninstall)
    shift; do_uninstall "$@"
    ;;
  restart)
    do_restart
    ;;
  status)
    check_status
    ;;
  stop)
    do_stop
    ;;
  renew-cron|cron-renew)
    do_cron_renew
    ;;
  run|daemon|start)
    shift; do_run "$@"
    ;;
  *)
    if [ ! -f "$ENV_FILE" ] && [ ! -f "$LEGACY_WRAPPER" ]; then
      do_install "$@"
    else
      if [ -t 0 ]; then
        do_menu "$@"
      else
        do_run "$@"
      fi
    fi
    ;;
esac
