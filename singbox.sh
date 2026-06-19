#!/bin/sh
export TERM="${TERM:-xterm}"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# ========== 配置变量 ==========
UUID="${UUID:-}"
PORT="${PORT:-3000}"
ARGO_PORT="${ARGO_PORT:-}"
NAME="${NAME:-}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
ARGO_AUTH="${ARGO_AUTH:-}"
DISABLE_ARGO="${DISABLE_ARGO:-}"
# 可选协议端口（填写则启用，留空不启动）
HY2_PORT="${HY2_PORT:-}"
TUIC_PORT="${TUIC_PORT:-}"
REALITY_PORT="${REALITY_PORT:-}"
REALITY_DOMAIN="${REALITY_DOMAIN:-www.iij.ad.jp}"
SS_PORT="${SS_PORT:-}"
# 优选地址
CF_PREFER_HOST="${CF_PREFER_HOST:-cdns.doon.eu.org}"
WS_PATH="${WS_PATH:-/fengyue}"
# ==============================

HOME_DIR="${HOME:-/tmp}"
UUID_FILE="$HOME_DIR/uuid.txt"
CONFIG_FILE="$HOME_DIR/sb-config.json"
REALITY_KEY_FILE="$HOME_DIR/reality-keys.txt"
CERT_DIR="$HOME_DIR/certs"
SUB_FILE="${HOME:-/tmp}/singbox/sub.txt"
mkdir -p "$(dirname "$SUB_FILE")"

# 二进制优先落在 /tmp，避免 $HOME noexec 问题
BIN_DIR="/tmp/sb-bin"
SB_DIR="$BIN_DIR/singbox"
SB_BIN="$SB_DIR/sing-box"
CF_BIN="$BIN_DIR/cloudflared"

# ── 工具函数 ──────────────────────────────────────────────────────────────────

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
die()  { echo "[ERROR] $*"; exit 1; }

http_get() {
  if command -v curl >/dev/null 2>&1; then
    curl -sL --max-time 5 "$1" 2>/dev/null || true
  else
    wget -qO- --timeout=5 "$1" 2>/dev/null || true
  fi
}

dl() {
  if command -v curl >/dev/null 2>&1; then
    curl -sL "$1" -o "$2"
  else
    wget -q "$1" -O "$2"
  fi
}

# base64 编码，兼容无 -w0 的环境
b64() {
  printf '%s' "$1" | base64 -w0 2>/dev/null || printf '%s' "$1" | base64 | tr -d '\n'
}

# URL 编码（只编码空格和常见特殊字符）
url_encode() {
  printf '%s' "$1" | sed \
    -e 's/ /%20/g' \
    -e 's/#/%23/g' \
    -e 's/&/%26/g' \
    -e 's/+/%2B/g' \
    -e 's/,/%2C/g' \
    -e 's/:/%3A/g' \
    -e 's/;/%3B/g' \
    -e 's/=/%3D/g' \
    -e 's/?/%3F/g' \
    -e 's/@/%40/g'
}

# 端口合法性检查（参数：端口值，协议 tcp/udp，已用端口列表文件）
USED_PORTS_FILE="/tmp/sb-used-ports.txt"
port_ok() {
  _p="$1"
  [ -z "$_p" ] && return 1
  case "$_p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$_p" -lt 1 ] || [ "$_p" -gt 65535 ] && return 1
  grep -qx "$_p" "$USED_PORTS_FILE" 2>/dev/null && return 1
  echo "$_p" >> "$USED_PORTS_FILE"
  return 0
}

get_free_port() {
  # 优先用 ss/netstat 找空闲端口，不依赖 Python
  _port=10086
  if command -v ss >/dev/null 2>&1; then
    for _try in 10086 10087 10088 10089 10090; do
      ss -ltn 2>/dev/null | grep -q ":${_try} " || { _port=$_try; break; }
    done
  elif command -v python3 >/dev/null 2>&1; then
    _port=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)" 2>/dev/null) || _port=10086
  elif command -v python >/dev/null 2>&1; then
    _port=$(python -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)" 2>/dev/null) || _port=10086
  fi
  echo "$_port"
}

# 等待端口就绪（最多等 N 秒）
wait_port() {
  _host="$1"; _port="$2"; _max="${3:-10}"
  _i=0
  while [ "$_i" -lt "$_max" ]; do
    if command -v nc >/dev/null 2>&1; then
      nc -z "$_host" "$_port" 2>/dev/null && return 0
    elif command -v ss >/dev/null 2>&1; then
      ss -ltn 2>/dev/null | grep -q ":${_port} " && return 0
    else
      sleep 1
      return 0
    fi
    sleep 1
    _i=$((_i + 1))
  done
  return 1
}

# ── UUID 管理 ─────────────────────────────────────────────────────────────────
if [ -n "$UUID" ]; then
  echo "$UUID" > "$UUID_FILE"
elif [ -f "$UUID_FILE" ]; then
  UUID="$(cat "$UUID_FILE")"
else
  UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null \
    || python  -c 'import uuid; print(uuid.uuid4())' 2>/dev/null \
    || od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8$9}')"
  echo "$UUID" > "$UUID_FILE"
fi

# SS2022 密码：取 UUID 前 16 字节做 base64（24字符）
# 优先 python3，备选 openssl，都没有则报错提示
SS_PASS=""
if command -v python3 >/dev/null 2>&1; then
  SS_PASS="$(python3 -c "
u='$UUID'.replace('-','')[:32]
import base64, binascii
print(base64.b64encode(binascii.unhexlify(u)).decode())
" 2>/dev/null)" || SS_PASS=""
fi
if [ -z "$SS_PASS" ] && command -v python >/dev/null 2>&1; then
  SS_PASS="$(python -c "
u='$UUID'.replace('-','')[:32]
import base64, binascii
print(base64.b64encode(binascii.unhexlify(u)).decode())
" 2>/dev/null)" || SS_PASS=""
fi
if [ -z "$SS_PASS" ] && command -v openssl >/dev/null 2>&1; then
  _hex="$(echo "$UUID" | tr -d '-' | cut -c1-32)"
  SS_PASS="$(printf '%s' "$_hex" | xxd -r -p 2>/dev/null | openssl base64 -A 2>/dev/null)" || SS_PASS=""
fi
if [ -z "$SS_PASS" ] && [ -n "$SS_PORT" ]; then
  warn "SS2022 密码生成失败（需要 python3/python/openssl+xxd），Shadowsocks 将被跳过"
fi

# ── 架构检测 ──────────────────────────────────────────────────────────────────
case "$(uname -m)" in
  x86_64|amd64)  SB_ARCH="amd64";  CF_ARCH="linux-amd64" ;;
  aarch64|arm64) SB_ARCH="arm64";  CF_ARCH="linux-arm64" ;;
  armv7*|armv6*) SB_ARCH="armv7";  CF_ARCH="linux-arm"   ;;
  i386|i686)     SB_ARCH="386";    CF_ARCH="linux-386"   ;;
  *)
    warn "未知架构 $(uname -m)，fallback 到 amd64"
    SB_ARCH="amd64"; CF_ARCH="linux-amd64"
    ;;
esac

# ── 二进制目录：优先 /tmp，fallback $HOME ─────────────────────────────────────
mkdir -p "$BIN_DIR" 2>/dev/null || {
  warn "/tmp/sb-bin 不可用，fallback 到 $HOME_DIR/sb-bin"
  BIN_DIR="$HOME_DIR/sb-bin"
  SB_DIR="$BIN_DIR/singbox"
  SB_BIN="$SB_DIR/sing-box"
  CF_BIN="$BIN_DIR/cloudflared"
  mkdir -p "$BIN_DIR"
}

# 验证目录可执行
_test_bin="$BIN_DIR/.exectest"
printf '#!/bin/sh\nexit 0\n' > "$_test_bin" 2>/dev/null
chmod +x "$_test_bin" 2>/dev/null
if ! "$_test_bin" 2>/dev/null; then
  warn "$BIN_DIR 挂载为 noexec，尝试其他路径..."
  for _try_dir in /var/tmp /dev/shm "$HOME_DIR"; do
    _test_bin2="$_try_dir/.exectest"
    printf '#!/bin/sh\nexit 0\n' > "$_test_bin2" 2>/dev/null
    chmod +x "$_test_bin2" 2>/dev/null
    if "$_test_bin2" 2>/dev/null; then
      BIN_DIR="$_try_dir/sb-bin"
      SB_DIR="$BIN_DIR/singbox"
      SB_BIN="$SB_DIR/sing-box"
      CF_BIN="$BIN_DIR/cloudflared"
      mkdir -p "$BIN_DIR"
      rm -f "$_test_bin2"
      log "使用可执行目录: $BIN_DIR"
      break
    fi
    rm -f "$_test_bin2"
  done
fi
rm -f "$_test_bin"

# ── 下载 sing-box ─────────────────────────────────────────────────────────────
download_singbox() {
  mkdir -p "$SB_DIR"
  log "正在获取 sing-box 最新版本..."
  SB_VER="$(http_get 'https://api.github.com/repos/SagerNet/sing-box/releases/latest' \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
  SB_VER="${SB_VER:-v1.11.6}"
  SB_VER_NUM="${SB_VER#v}"
  log "下载 sing-box ${SB_VER} (${SB_ARCH})..."

  DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/sing-box-${SB_VER_NUM}-linux-${SB_ARCH}.tar.gz"
  log "下载地址: $DOWNLOAD_URL"
  dl "$DOWNLOAD_URL" /tmp/sing-box.tar.gz

  if [ ! -s /tmp/sing-box.tar.gz ]; then
    die "sing-box 下载失败，文件为空：$DOWNLOAD_URL"
  fi

  log "文件大小: $(wc -c < /tmp/sing-box.tar.gz) bytes"

  if ! tar -tzf /tmp/sing-box.tar.gz >/dev/null 2>&1; then
    log "下载的文件内容（前200字符，用于排查）："
    head -c 200 /tmp/sing-box.tar.gz
    die "sing-box 压缩包损坏，可能下载失败或被拦截"
  fi

  tar -xzf /tmp/sing-box.tar.gz -C "$SB_DIR" --strip-components=1
log "解压后目录内容："
ls -la "$SB_DIR"
chmod +x "$SB_BIN" 2>/dev/null || warn "chmod 失败，$SB_BIN 可能不存在"
rm -f /tmp/sing-box.tar.gz
log "sing-box 下载完成"
}

# ── 下载 cloudflared ──────────────────────────────────────────────────────────
download_cloudflared() {
  log "正在下载 cloudflared (${CF_ARCH})..."
  dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${CF_ARCH}" "$CF_BIN"
  chmod +x "$CF_BIN"
  log "cloudflared 下载完成"
}

# 清理旧进程
pkill -f "$SB_BIN"    2>/dev/null || true
pkill -f "$CF_BIN"    2>/dev/null || true
sleep 1

[ -x "$SB_BIN" ] || download_singbox
[ -x "$CF_BIN" ] || { [ "${DISABLE_ARGO:-}" != "true" ] && download_cloudflared || true; }

# ── 端口分配 ──────────────────────────────────────────────────────────────────
rm -f "$USED_PORTS_FILE"

if [ "${DISABLE_ARGO:-}" != "true" ]; then
  if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
    ARGO_PORT="${ARGO_PORT:-8001}"
  else
    ARGO_PORT="${ARGO_PORT:-$(get_free_port)}"
  fi
  echo "$ARGO_PORT" >> "$USED_PORTS_FILE"
fi

# ── 节点名称 ──────────────────────────────────────────────────────────────────
if [ -z "$NAME" ]; then
  COUNTRY="$(http_get 'https://ipinfo.io/country' | tr -d '[:space:]')"
  ASN_ORG="$(http_get 'https://ipinfo.io/org' \
    | sed 's/^AS[0-9]* //' \
    | sed 's/,\? *Inc\.*//' | sed 's/,\? *LLC\.*//' \
    | sed 's/,\? *Ltd\.*//' | sed 's/,\? *Corp\.*//' \
    | sed 's/[[:space:]]*$//' | cut -c1-20)"
  if [ -n "$COUNTRY" ] && [ -n "$ASN_ORG" ]; then
    NAME="${COUNTRY}-${ASN_ORG}"
  elif [ -n "$COUNTRY" ]; then
    NAME="${COUNTRY}-sbx"
  else
    NAME="sbx"
  fi
fi
NAME_ENCODED="$(url_encode "$NAME")"

# ── 公网 IP ───────────────────────────────────────────────────────────────────
PUBLIC_IP=""
if [ -n "$HY2_PORT" ] || [ -n "$TUIC_PORT" ] || [ -n "$REALITY_PORT" ] || [ -n "$SS_PORT" ]; then
  PUBLIC_IP="$(http_get 'https://ipinfo.io/ip' | tr -d '[:space:]')"
  [ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(http_get 'https://ifconfig.co/ip' | tr -d '[:space:]')"
fi

# ── 自签证书（HY2 / TUIC 用）─────────────────────────────────────────────────
CERT_PATH=""
KEY_PATH=""
if [ -n "$HY2_PORT" ] || [ -n "$TUIC_PORT" ]; then
  mkdir -p "$CERT_DIR"
  CERT_PATH="$CERT_DIR/cert.pem"
  KEY_PATH="$CERT_DIR/key.pem"
  if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
    if command -v openssl >/dev/null 2>&1; then
      openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 3650 -nodes \
        -keyout "$KEY_PATH" -out "$CERT_PATH" \
        -subj "/CN=bing.com/O=Microsoft/C=US" 2>/dev/null
    else
      cat > "$KEY_PATH" << 'KEYEOF'
-----BEGIN EC PARAMETERS-----
BggqhkjOPQMBBw==
-----END EC PARAMETERS-----
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIM4792SEtPqIt1ywqTd/0bYidBqpYV/++siNnfBYsdUYoAoGCCqGSM49
AwEHoUQDQgAE1kHafPj07rJG+HboH2ekAI4r+e6TL38GWASANnngZreoQDF16ARa
/TsyLyFoPkhLxSbehH/NBEjHtSZGaDhMqQ==
-----END EC PRIVATE KEY-----
KEYEOF
      cat > "$CERT_PATH" << 'CERTEOF'
-----BEGIN CERTIFICATE-----
MIIBejCCASGgAwIBAgIUfWeQL3556PNJLp/veCFxGNj9crkwCgYIKoZIzj0EAwIw
EzERMA8GA1UEAwwIYmluZy5jb20wHhcNMjUwOTE4MTgyMDIyWhcNMzUwOTE2MTgy
MDIyWjATMREwDwYDVQQDDAhiaW5nLmNvbTBZMBMGByqGSM49AgEGCCqGSM49AwEH
A0IABNZB2nz49O6yRvh26B9npACOK/nuky9/BlgEgDZ54Ga3qEAxdegEWv07Mi8h
aD5IS8Um3oR/zQRIx7UmRmg4TKmjUzBRMB0GA1UdDgQWBBTV1cFID7UISE7PLTBR
BfGbgkrMNzAfBgNVHSMEGDAWgBTV1cFID7UISE7PLTBRBfGbgkrMNzAPBgNVHRMB
Af8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCIAIDAJvg0vd/ytrQVvEcSm6XTlB+
eQ6OFb9LbLYL9f+sAiAffoMbi4y/0YUSlTtz7as9S8/lciBF5VCUoVIKS+vX2g==
-----END CERTIFICATE-----
CERTEOF
    fi
  fi
fi

# ── Reality 密钥 ──────────────────────────────────────────────────────────────
REALITY_PRIV=""
REALITY_PUB=""
if [ -n "$REALITY_PORT" ]; then
  if [ -f "$REALITY_KEY_FILE" ]; then
    REALITY_PRIV="$(grep '^PrivateKey:' "$REALITY_KEY_FILE" | sed 's/PrivateKey: *//')"
    REALITY_PUB="$(grep  '^PublicKey:'  "$REALITY_KEY_FILE" | sed 's/PublicKey: *//')"
  fi
  if [ -z "$REALITY_PRIV" ] || [ -z "$REALITY_PUB" ]; then
    KEYPAIR="$("$SB_BIN" generate reality-keypair 2>/dev/null || true)"
    REALITY_PRIV="$(echo "$KEYPAIR" | grep PrivateKey | sed 's/PrivateKey: *//')"
    REALITY_PUB="$(echo  "$KEYPAIR" | grep PublicKey  | sed 's/PublicKey: *//')"
    if [ -n "$REALITY_PRIV" ] && [ -n "$REALITY_PUB" ]; then
      printf 'PrivateKey: %s\nPublicKey: %s\n' "$REALITY_PRIV" "$REALITY_PUB" > "$REALITY_KEY_FILE"
      log "Reality 密钥生成完成"
    else
      warn "Reality 密钥生成失败，VLESS Reality 将被跳过"
      REALITY_PORT=""
    fi
  else
    log "已从文件读取 Reality 密钥对"
  fi
fi

# ── 端口合法性检查 ────────────────────────────────────────────────────────────
HY2_ACTIVE=0; TUIC_ACTIVE=0; REALITY_ACTIVE=0; SS_ACTIVE=0

if [ -n "$HY2_PORT" ]; then
  if port_ok "$HY2_PORT"; then HY2_ACTIVE=1;
  else warn "HY2_PORT(${HY2_PORT}) 无效或冲突，Hysteria2 已跳过"; fi
fi
if [ -n "$TUIC_PORT" ]; then
  if port_ok "$TUIC_PORT"; then TUIC_ACTIVE=1;
  else warn "TUIC_PORT(${TUIC_PORT}) 无效或冲突，TUIC 已跳过"; fi
fi
if [ -n "$REALITY_PORT" ]; then
  if port_ok "$REALITY_PORT"; then REALITY_ACTIVE=1;
  else warn "REALITY_PORT(${REALITY_PORT}) 无效或冲突，Reality 已跳过"; fi
fi
if [ -n "$SS_PORT" ] && [ -n "$SS_PASS" ]; then
  if port_ok "$SS_PORT"; then SS_ACTIVE=1;
  else warn "SS_PORT(${SS_PORT}) 无效或冲突，Shadowsocks 已跳过"; fi
fi

# ── 生成 sing-box 配置 ────────────────────────────────────────────────────────
# 用 printf 拼接，避免 heredoc 变量展开歧义；最后用 sing-box check 校验
_inbounds=""

# Argo VMess inbound
if [ "${DISABLE_ARGO:-}" != "true" ]; then
  _inbounds="$(printf '%s' "$_inbounds"){
      \"type\": \"vmess\",
      \"tag\": \"vmess-in\",
      \"listen\": \"127.0.0.1\",
      \"listen_port\": ${ARGO_PORT},
      \"users\": [{ \"uuid\": \"${UUID}\" }],
      \"transport\": { \"type\": \"ws\", \"path\": \"${WS_PATH}\" }
    }"
  _sep=","
else
  _sep=""
fi

if [ "$HY2_ACTIVE" = "1" ]; then
  _inbounds="${_inbounds}${_sep}
    {
      \"type\": \"hysteria2\",
      \"tag\": \"hy2-in\",
      \"listen\": \"::\",
      \"listen_port\": ${HY2_PORT},
      \"users\": [{ \"password\": \"${UUID}\" }],
      \"masquerade\": \"https://bing.com\",
      \"tls\": {
        \"enabled\": true,
        \"alpn\": [\"h3\"],
        \"certificate_path\": \"${CERT_PATH}\",
        \"key_path\": \"${KEY_PATH}\"
      }
    }"
  _sep=","
fi

if [ "$TUIC_ACTIVE" = "1" ]; then
  _inbounds="${_inbounds}${_sep}
    {
      \"type\": \"tuic\",
      \"tag\": \"tuic-in\",
      \"listen\": \"::\",
      \"listen_port\": ${TUIC_PORT},
      \"users\": [{ \"uuid\": \"${UUID}\", \"password\": \"${UUID}\" }],
      \"congestion_control\": \"bbr\",
      \"tls\": {
        \"enabled\": true,
        \"alpn\": [\"h3\"],
        \"certificate_path\": \"${CERT_PATH}\",
        \"key_path\": \"${KEY_PATH}\"
      }
    }"
  _sep=","
fi

if [ "$REALITY_ACTIVE" = "1" ]; then
  _inbounds="${_inbounds}${_sep}
    {
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
  _sep=","
fi

if [ "$SS_ACTIVE" = "1" ]; then
  _inbounds="${_inbounds}${_sep}
    {
      \"type\": \"shadowsocks\",
      \"tag\": \"ss-in\",
      \"listen\": \"::\",
      \"listen_port\": ${SS_PORT},
      \"network\": \"tcp\",
      \"method\": \"2022-blake3-aes-128-gcm\",
      \"password\": \"${SS_PASS}\"
    }"
fi

printf '{\n  "log": { "level": "warn", "timestamp": false },\n  "inbounds": [\n    %s\n  ],\n  "outbounds": [{ "type": "direct", "tag": "direct" }]\n}\n' \
  "$_inbounds" > "$CONFIG_FILE"

# 校验配置
if ! "$SB_BIN" check -c "$CONFIG_FILE"; then
  warn "sing-box 配置校验失败，尝试输出配置内容以供排查："
  cat "$CONFIG_FILE"
  die "配置无效，终止启动"
fi

# ── 启动 sing-box（守护循环）─────────────────────────────────────────────────
start_singbox() {
  "$SB_BIN" run -c "$CONFIG_FILE" &
  SB_PID=$!
  # 等待端口就绪，最多 10 秒
  if [ "${DISABLE_ARGO:-}" != "true" ]; then
    wait_port 127.0.0.1 "$ARGO_PORT" 10
  fi
  if ! kill -0 $SB_PID 2>/dev/null; then
    warn "sing-box 进程已退出"
    return 1
  fi
  log "sing-box 已启动 (PID: $SB_PID)"
  return 0
}

start_singbox || die "sing-box 首次启动失败"

# ── 启动 Argo 隧道 ────────────────────────────────────────────────────────────
ARGO_HOST=""
CF_LOG="$HOME_DIR/cf.log"

if [ "${DISABLE_ARGO:-}" != "true" ]; then
  if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
    log "启动固定 Argo 隧道..."
    "$CF_BIN" tunnel --edge-ip-version auto --no-autoupdate \
      run --token "$ARGO_AUTH" >/dev/null 2>&1 &
    sleep 3
    ARGO_HOST="$ARGO_DOMAIN"
  else
    log "启动临时 Argo 隧道..."
    rm -f "$CF_LOG"
    "$CF_BIN" tunnel --edge-ip-version auto --no-autoupdate \
      --url "http://127.0.0.1:${ARGO_PORT}" \
      --logfile "$CF_LOG" >/dev/null 2>&1 &
    i=0
    while [ $i -lt 30 ]; do
      ARGO_HOST="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null \
        | head -1 | sed 's|https://||')"
      [ -n "$ARGO_HOST" ] && break
      sleep 1
      i=$((i+1))
    done
  fi

  if [ -z "$ARGO_HOST" ]; then
    warn "隧道域名获取失败，订阅链接将使用占位符 your-domain.com"
    ARGO_HOST="your-domain.com"
  else
    log "隧道域名: $ARGO_HOST"
  fi
fi

# ── 生成订阅链接 ──────────────────────────────────────────────────────────────
ALL_LINKS=""

if [ "${DISABLE_ARGO:-}" != "true" ]; then
  VMESS_JSON="{\"v\":\"2\",\"ps\":\"${NAME}\",\"add\":\"cdns.doon.eu.org\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ARGO_HOST}\",\"path\":\"${WS_PATH}\",\"tls\":\"tls\",\"sni\":\"${ARGO_HOST}\"}"
  ALL_LINKS="vmess://$(b64 "$VMESS_JSON")"
fi

if [ "$HY2_ACTIVE" = "1" ] && [ -n "$PUBLIC_IP" ]; then
  _link="hysteria2://${UUID}@${PUBLIC_IP}:${HY2_PORT}?sni=www.bing.com&insecure=1&alpn=h3&obfs=none#${NAME_ENCODED}"
  ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
fi

if [ "$TUIC_ACTIVE" = "1" ] && [ -n "$PUBLIC_IP" ]; then
  _link="tuic://${UUID}:${UUID}@${PUBLIC_IP}:${TUIC_PORT}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${NAME_ENCODED}"
  ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
fi

if [ "$REALITY_ACTIVE" = "1" ] && [ -n "$PUBLIC_IP" ] && [ -n "$REALITY_PUB" ]; then
  _link="vless://${UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=firefox&pbk=${REALITY_PUB}&type=tcp&headerType=none#${NAME_ENCODED}"
  ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
fi

if [ "$SS_ACTIVE" = "1" ] && [ -n "$PUBLIC_IP" ]; then
  SS_USERINFO="$(b64 "2022-blake3-aes-128-gcm:${SS_PASS}")"
  _link="ss://${SS_USERINFO}@${PUBLIC_IP}:${SS_PORT}#${NAME_ENCODED}"
  ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
fi

SUB_BASE64="$(b64 "$ALL_LINKS")"
echo "$SUB_BASE64" > "$SUB_FILE"

log "================= 订阅内容 ================="
echo "$SUB_BASE64"
log "============================================="
log "节点文件: $SUB_FILE"

log "============== 已启用协议 =============="
[ "${DISABLE_ARGO:-}" != "true" ] && log "✓ VMess + WS + Argo TLS  (域名: $ARGO_HOST)"
[ "${DISABLE_ARGO:-}" = "true"  ] && log "✗ Argo 隧道已禁用"
[ "$HY2_ACTIVE"     = "1" ] && log "✓ Hysteria2     端口 $HY2_PORT (UDP)"
[ "$TUIC_ACTIVE"    = "1" ] && log "✓ TUIC v5       端口 $TUIC_PORT (UDP)"
[ "$REALITY_ACTIVE" = "1" ] && log "✓ VLESS Reality 端口 $REALITY_PORT  PubKey: $REALITY_PUB"
[ "$SS_ACTIVE"      = "1" ] && log "✓ Shadowsocks   端口 $SS_PORT (TCP)"
log "========================================"

# ── 守护循环：sing-box 崩溃自动重启，同时清理孤儿进程 ────────────────────────
log "进入守护模式..."
while true; do
  if ! kill -0 $SB_PID 2>/dev/null; then
    warn "sing-box 意外退出，5 秒后重启..."
    # 清理可能残留的 cloudflared
    pkill -f "$CF_BIN" 2>/dev/null || true
    sleep 5
    start_singbox || { warn "重启失败，继续等待..."; sleep 10; continue; }
    # cloudflared 如果也挂了一并重拉
    if [ "${DISABLE_ARGO:-}" != "true" ] && ! pgrep -f "$CF_BIN" >/dev/null 2>&1; then
      warn "cloudflared 也已退出，尝试重启..."
      if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
        "$CF_BIN" tunnel --edge-ip-version auto --no-autoupdate \
          run --token "$ARGO_AUTH" >/dev/null 2>&1 &
      else
        "$CF_BIN" tunnel --edge-ip-version auto --no-autoupdate \
          --url "http://127.0.0.1:${ARGO_PORT}" \
          --logfile "$CF_LOG" >/dev/null 2>&1 &
      fi
    fi
  fi
  sleep 10
done
