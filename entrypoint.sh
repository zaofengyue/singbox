#!/bin/sh
set -eu

export TERM="${TERM:-xterm}"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# ========== 配置变量 ==========
UUID="${UUID:-}"
PORT="${PORT:-}"
ARGO_PORT="${ARGO_PORT:-}"
NAME="${NAME:-}"
ARGO_DOMAIN="${ARGO_DOMAIN:-}"
ARGO_AUTH="${ARGO_AUTH:-}"
CF_PREFER_HOST="cdns.doon.eu.org"
WS_PATH="/fengyue"
# ==============================

HOME_DIR="${HOME:-/tmp}"
UUID_FILE="$HOME_DIR/uuid.txt"
CONFIG_FILE="$HOME_DIR/sb-config.json"
SB_DIR="$HOME_DIR/singbox"
SB_BIN="$SB_DIR/sing-box"
CF_BIN="$HOME_DIR/cloudflared"
SUB_FILE="$(pwd)/sub.txt"

# 获取空闲端口
get_free_port() {
  python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()" 2>/dev/null || \
  python -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()" 2>/dev/null || \
  echo "10086"
}

# UUID 管理
if [ -n "$UUID" ]; then
  echo "$UUID" > "$UUID_FILE"
elif [ -f "$UUID_FILE" ]; then
  UUID="$(cat "$UUID_FILE")"
else
  UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || python -c 'import uuid; print(uuid.uuid4())')"
  echo "$UUID" > "$UUID_FILE"
fi

# 对外端口
if [ -n "$PORT" ]; then
  INBOUND_PORT="$PORT"
else
  INBOUND_PORT="$(get_free_port)"
fi

# 下载 sing-box
download_singbox() {
  mkdir -p "$SB_DIR"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)  SB_ARCH="amd64" ;;
    aarch64) SB_ARCH="arm64" ;;
    armv7*)  SB_ARCH="armv7" ;;
    *)       SB_ARCH="amd64" ;;
  esac

  echo "正在下载 sing-box ($SB_ARCH)..."
  SB_VERSION="$(curl -sL https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name"' | cut -d'"' -f4 || echo 'v1.10.0')"
  SB_VERSION="${SB_VERSION:-v1.10.0}"
  SB_URL="https://github.com/SagerNet/sing-box/releases/download/${SB_VERSION}/sing-box-${SB_VERSION#v}-linux-${SB_ARCH}.tar.gz"

  if command -v curl >/dev/null 2>&1; then
    curl -sL "$SB_URL" -o /tmp/sing-box.tar.gz
  else
    wget -q "$SB_URL" -O /tmp/sing-box.tar.gz
  fi

  tar -xzf /tmp/sing-box.tar.gz -C /tmp/
  find /tmp -name "sing-box" -type f | head -1 | xargs -I{} mv {} "$SB_BIN"
  chmod +x "$SB_BIN"
  rm -f /tmp/sing-box.tar.gz
  echo "sing-box 下载完成"
}

# 下载 cloudflared
download_cloudflared() {
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)  CF_ARCH="linux-amd64" ;;
    aarch64) CF_ARCH="linux-arm64" ;;
    armv7*)  CF_ARCH="linux-arm" ;;
    *)       CF_ARCH="linux-amd64" ;;
  esac

  echo "正在下载 cloudflared ($CF_ARCH)..."
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${CF_ARCH}"

  if command -v curl >/dev/null 2>&1; then
    curl -sL "$CF_URL" -o "$CF_BIN"
  else
    wget -q "$CF_URL" -O "$CF_BIN"
  fi

  chmod +x "$CF_BIN"
  echo "cloudflared 下载完成"
}

# 检查并下载 sing-box
if [ ! -x "$SB_BIN" ]; then
  download_singbox
fi

# 检查并下载 cloudflared
if [ ! -x "$CF_BIN" ]; then
  download_cloudflared
fi

# 确定 Argo 端口
if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
  if [ -z "$ARGO_PORT" ]; then
    ARGO_PORT="8001"
  fi
else
  ARGO_PORT="$(get_free_port)"
fi

# 获取国家和 ASN
COUNTRY="$(curl -s --max-time 5 https://ipinfo.io/country 2>/dev/null || \
           curl -s --max-time 5 https://ifconfig.co/country-iso 2>/dev/null || \
           echo '')"
ASN_ORG="$(curl -s --max-time 5 https://ipinfo.io/org 2>/dev/null || \
           curl -s --max-time 5 https://ifconfig.co/org 2>/dev/null || \
           echo '')"
ASN_ORG="$(echo "$ASN_ORG" \
  | sed 's/^AS[0-9]* //' \
  | sed 's/,\? *Inc\.$//' \
  | sed 's/,\? *LLC\.*//' \
  | sed 's/,\? *Ltd\.*//' \
  | sed 's/,\? *Corp\.*//' \
  | sed 's/ *$//' \
  | cut -c1-20)"

if [ -z "$NAME" ]; then
  if [ -n "$COUNTRY" ] && [ -n "$ASN_ORG" ]; then
    NAME="${COUNTRY}-${ASN_ORG}"
  elif [ -n "$COUNTRY" ]; then
    NAME="${COUNTRY}-sbx"
  else
    NAME="sbx"
  fi
fi

# 生成 sing-box 配置
cat > "$CONFIG_FILE" << SBCONF
{
  "log": { "level": "warn" },
  "inbounds": [{
    "type": "vmess",
    "listen": "127.0.0.1",
    "listen_port": ${ARGO_PORT},
    "users": [{ "uuid": "${UUID}", "alterId": 0 }],
    "transport": {
      "type": "ws",
      "path": "${WS_PATH}"
    }
  }],
  "outbounds": [{ "type": "direct" }]
}
SBCONF

# 启动 sing-box
echo "正在启动 sing-box..."
"$SB_BIN" run -c "$CONFIG_FILE" &
SB_PID=$!
sleep 2

if ! kill -0 $SB_PID 2>/dev/null; then
  echo "FATAL: sing-box 启动失败"
  exit 1
fi
echo "sing-box 已启动 (PID: $SB_PID)"

# 启动 Argo 隧道
ARGO_HOST=""
if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
  echo "启动固定 Argo 隧道..."
  "$CF_BIN" tunnel --edge-ip-version auto --no-autoupdate run --token "$ARGO_AUTH" &
  sleep 3
  ARGO_HOST="$ARGO_DOMAIN"
else
  echo "启动临时 Argo 隧道..."
  "$CF_BIN" tunnel --edge-ip-version auto --no-autoupdate \
    --url "http://127.0.0.1:${ARGO_PORT}" \
    --logfile /tmp/cf.log &
  sleep 8
  ARGO_HOST="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cf.log | head -1 | sed 's|https://||')"
fi

if [ -z "$ARGO_HOST" ]; then
  ARGO_HOST="your-domain.com"
  echo "警告: 隧道域名获取失败，请检查日志"
fi

echo "隧道域名: $ARGO_HOST"

# 生成 VMess 链接
VMESS_JSON="{\"v\":\"2\",\"ps\":\"${NAME}\",\"add\":\"${CF_PREFER_HOST}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ARGO_HOST}\",\"path\":\"${WS_PATH}\",\"tls\":\"tls\",\"sni\":\"${ARGO_HOST}\"}"
VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0 2>/dev/null || echo -n "$VMESS_JSON" | base64)"

echo "================= VMESS ================="
echo "$VMESS_LINK"
echo "========================================="

echo "$VMESS_LINK" > "$SUB_FILE"
echo "节点文件: $SUB_FILE"

# 保持前台运行
wait $SB_PID
