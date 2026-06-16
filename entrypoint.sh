#!/bin/sh
set -eu

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
SB_DIR="$HOME_DIR/singbox"
SB_BIN="$SB_DIR/sing-box"
CF_BIN="$HOME_DIR/cloudflared"
SUB_FILE="$(pwd)/sub.txt"

# ── 工具函数 ──────────────────────────────────────────────────────────────────

get_free_port() {
  python3 -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)" 2>/dev/null || \
  python  -c "import socket; s=socket.socket(); s.bind(('',0)); p=s.getsockname()[1]; s.close(); print(p)" 2>/dev/null || \
  echo "10086"
}

http_get() {
  if command -v curl >/dev/null 2>&1; then
    curl -sL --max-time 5 "$1" 2>/dev/null || echo ''
  else
    wget -qO- --timeout=5 "$1" 2>/dev/null || echo ''
  fi
}

dl() {
  if command -v curl >/dev/null 2>&1; then
    curl -sL "$1" -o "$2"
  else
    wget -q "$1" -O "$2"
  fi
}

b64() {
  echo -n "$1" | base64 -w0 2>/dev/null || echo -n "$1" | base64
}

# ── UUID 管理 ─────────────────────────────────────────────────────────────────
if [ -n "$UUID" ]; then
  echo "$UUID" > "$UUID_FILE"
elif [ -f "$UUID_FILE" ]; then
  UUID="$(cat "$UUID_FILE")"
else
  UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || \
          python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null || \
          python  -c 'import uuid; print(uuid.uuid4())')"
  echo "$UUID" > "$UUID_FILE"
fi

# SS2022 密码：取 UUID 前 16 字节做 base64（24字符）
SS_PASS="$(python3 -c "u='$UUID'.replace('-','')[:32]; import base64,binascii; print(base64.b64encode(binascii.unhexlify(u)).decode())" 2>/dev/null || \
           python  -c "u='$UUID'.replace('-','')[:32]; import base64,binascii; print(base64.b64encode(binascii.unhexlify(u)).decode())" 2>/dev/null || \
           echo '')"

# ── 架构检测 ──────────────────────────────────────────────────────────────────
case "$(uname -m)" in
  x86_64)        SB_ARCH="amd64";  CF_ARCH="linux-amd64" ;;
  aarch64|arm64) SB_ARCH="arm64";  CF_ARCH="linux-arm64" ;;
  armv7*)        SB_ARCH="armv7";  CF_ARCH="linux-arm"   ;;
  *)             SB_ARCH="amd64";  CF_ARCH="linux-amd64" ;;
esac

# ── 下载 sing-box ─────────────────────────────────────────────────────────────
download_singbox() {
  mkdir -p "$SB_DIR"
  echo "正在获取 sing-box 最新版本..."
  SB_VER="$(http_get 'https://api.github.com/repos/SagerNet/sing-box/releases/latest' \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')"
  SB_VER="${SB_VER:-v1.11.6}"
  SB_VER_NUM="${SB_VER#v}"
  echo "下载 sing-box ${SB_VER} (${SB_ARCH})..."
  dl "https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/sing-box-${SB_VER_NUM}-linux-${SB_ARCH}.tar.gz" \
     /tmp/sing-box.tar.gz
  tar -xzf /tmp/sing-box.tar.gz -C "$SB_DIR" --strip-components=1
  chmod +x "$SB_BIN"
  rm -f /tmp/sing-box.tar.gz
  echo "sing-box 下载完成"
}

# ── 下载 cloudflared ──────────────────────────────────────────────────────────
download_cloudflared() {
  echo "正在下载 cloudflared (${CF_ARCH})..."
  dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${CF_ARCH}" "$CF_BIN"
  chmod +x "$CF_BIN"
  echo "cloudflared 下载完成"
}

[ -x "$SB_BIN" ] || download_singbox
[ -x "$CF_BIN" ] || download_cloudflared

# ── 端口分配 ──────────────────────────────────────────────────────────────────
if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
  ARGO_PORT="${ARGO_PORT:-8001}"
else
  ARGO_PORT="${ARGO_PORT:-$(get_free_port)}"
fi

# ── 节点名称 ──────────────────────────────────────────────────────────────────
if [ -z "$NAME" ]; then
  COUNTRY="$(http_get 'https://ipinfo.io/country')"
  ASN_ORG="$(http_get 'https://ipinfo.io/org' | \
    sed 's/^AS[0-9]* //' | \
    sed 's/,\? *Inc\.//' | sed 's/,\? *LLC\.//' | \
    sed 's/,\? *Ltd\.//' | sed 's/,\? *Corp\.//' | \
    sed 's/[[:space:]]*$//' | cut -c1-20)"
  if [ -n "$COUNTRY" ] && [ -n "$ASN_ORG" ]; then
    NAME="${COUNTRY}-${ASN_ORG}"
  elif [ -n "$COUNTRY" ]; then
    NAME="${COUNTRY}-sbx"
  else
    NAME="sbx"
  fi
fi

# ── 公网 IP（直连协议订阅需要）───────────────────────────────────────────────
PUBLIC_IP=""
if [ -n "$HY2_PORT" ] || [ -n "$TUIC_PORT" ] || [ -n "$REALITY_PORT" ] || [ -n "$SS_PORT" ]; then
  PUBLIC_IP="$(http_get 'https://ipinfo.io/ip')"
  [ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(http_get 'https://ifconfig.co/ip')"
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
    KEYPAIR="$("$SB_BIN" generate reality-keypair 2>/dev/null || echo '')"
    REALITY_PRIV="$(echo "$KEYPAIR" | grep PrivateKey | sed 's/PrivateKey: *//')"
    REALITY_PUB="$(echo  "$KEYPAIR" | grep PublicKey  | sed 's/PublicKey: *//')"
    printf 'PrivateKey: %s\nPublicKey: %s\n' "$REALITY_PRIV" "$REALITY_PUB" > "$REALITY_KEY_FILE"
    echo "Reality 密钥生成完成"
  else
    echo "已从文件读取 Reality 密钥对"
  fi
fi

# ── 生成 sing-box 配置 ────────────────────────────────────────────────────────
# VMess + WS 直接监听 ARGO_PORT，cloudflared 指向它，无需反代层
cat > "$CONFIG_FILE" << SBCONF
{
  "log": { "level": "warn", "timestamp": false },
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "127.0.0.1",
      "listen_port": ${ARGO_PORT},
      "users": [{ "uuid": "${UUID}", "alterId": 0 }],
      "transport": { "type": "ws", "path": "${WS_PATH}" }
    }
SBCONF

# Hysteria2（可选）
if [ -n "$HY2_PORT" ]; then
  echo "启用 Hysteria2，端口 $HY2_PORT"
  cat >> "$CONFIG_FILE" << HYEOF
    ,{
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [{ "password": "${UUID}" }],
      "masquerade": "https://bing.com",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${CERT_PATH}",
        "key_path": "${KEY_PATH}"
      }
    }
HYEOF
fi

# TUIC v5（可选）
if [ -n "$TUIC_PORT" ]; then
  echo "启用 TUIC v5，端口 $TUIC_PORT"
  cat >> "$CONFIG_FILE" << TUICEOF
    ,{
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${TUIC_PORT},
      "users": [{ "uuid": "${UUID}" }],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${CERT_PATH}",
        "key_path": "${KEY_PATH}"
      }
    }
TUICEOF
fi

# VLESS Reality（可选）
if [ -n "$REALITY_PORT" ] && [ -n "$REALITY_PRIV" ]; then
  echo "启用 VLESS Reality，端口 $REALITY_PORT"
  cat >> "$CONFIG_FILE" << REALEOF
    ,{
      "type": "vless",
      "tag": "reality-in",
      "listen": "::",
      "listen_port": ${REALITY_PORT},
      "users": [{ "uuid": "${UUID}", "flow": "xtls-rprx-vision" }],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_DOMAIN}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${REALITY_DOMAIN}", "server_port": 443 },
          "private_key": "${REALITY_PRIV}",
          "short_id": [""]
        }
      }
    }
REALEOF
fi

# Shadowsocks 2022（可选）
if [ -n "$SS_PORT" ] && [ -n "$SS_PASS" ]; then
  echo "启用 Shadowsocks 2022，端口 $SS_PORT"
  cat >> "$CONFIG_FILE" << SSEOF
    ,{
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${SS_PORT},
      "network": "tcp",
      "method": "2022-blake3-aes-128-gcm",
      "password": "${SS_PASS}"
    }
SSEOF
fi

cat >> "$CONFIG_FILE" << SBEND
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
SBEND

# ── 启动 sing-box ─────────────────────────────────────────────────────────────
echo "正在启动 sing-box..."
"$SB_BIN" run -c "$CONFIG_FILE" &
SB_PID=$!
sleep 2

if ! kill -0 $SB_PID 2>/dev/null; then
  echo "FATAL: sing-box 启动失败"
  exit 1
fi
echo "sing-box 已启动 (PID: $SB_PID)"

# ── 启动 Argo 隧道 ────────────────────────────────────────────────────────────
ARGO_HOST=""
if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
  echo "启动固定 Argo 隧道..."
  "$CF_BIN" tunnel --edge-ip-version auto --no-autoupdate \
    run --token "$ARGO_AUTH" >/dev/null 2>&1 &
  sleep 3
  ARGO_HOST="$ARGO_DOMAIN"
else
  echo "启动临时 Argo 隧道..."
  rm -f /tmp/cf.log
  "$CF_BIN" tunnel --edge-ip-version auto --no-autoupdate \
    --url "http://127.0.0.1:${ARGO_PORT}" \
    --logfile /tmp/cf.log >/dev/null 2>&1 &
  i=0
  while [ $i -lt 30 ]; do
    ARGO_HOST="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cf.log 2>/dev/null \
      | head -1 | sed 's|https://||')"
    [ -n "$ARGO_HOST" ] && break
    sleep 1
    i=$((i+1))
  done
fi

if [ -z "$ARGO_HOST" ]; then
  ARGO_HOST="your-domain.com"
  echo "警告: 隧道域名获取失败"
fi
echo "隧道域名: $ARGO_HOST"

# ── 生成订阅链接 ──────────────────────────────────────────────────────────────
VMESS_JSON="{\"v\":\"2\",\"ps\":\"${NAME}\",\"add\":\"${CF_PREFER_HOST}\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ARGO_HOST}\",\"path\":\"${WS_PATH}\",\"tls\":\"tls\",\"sni\":\"${ARGO_HOST}\"}"
VMESS_LINK="vmess://$(b64 "$VMESS_JSON")"

ALL_LINKS="$VMESS_LINK"

if [ -n "$HY2_PORT" ] && [ -n "$PUBLIC_IP" ]; then
  ALL_LINKS="${ALL_LINKS}
hysteria2://${UUID}@${PUBLIC_IP}:${HY2_PORT}?sni=www.bing.com&insecure=1&alpn=h3&obfs=none#${NAME}"
fi

if [ -n "$TUIC_PORT" ] && [ -n "$PUBLIC_IP" ]; then
  ALL_LINKS="${ALL_LINKS}
tuic://${UUID}:@${PUBLIC_IP}:${TUIC_PORT}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${NAME}"
fi

if [ -n "$REALITY_PORT" ] && [ -n "$PUBLIC_IP" ] && [ -n "$REALITY_PUB" ]; then
  ALL_LINKS="${ALL_LINKS}
vless://${UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=firefox&pbk=${REALITY_PUB}&type=tcp&headerType=none#${NAME}"
fi

if [ -n "$SS_PORT" ] && [ -n "$PUBLIC_IP" ] && [ -n "$SS_PASS" ]; then
  SS_USERINFO="$(b64 "2022-blake3-aes-128-gcm:${SS_PASS}")"
  ALL_LINKS="${ALL_LINKS}
ss://${SS_USERINFO}@${PUBLIC_IP}:${SS_PORT}#${NAME}"
fi

SUB_BASE64="$(b64 "$ALL_LINKS")"
echo "$SUB_BASE64" > "$SUB_FILE"

echo "================= 订阅内容 ================="
echo "$SUB_BASE64"
echo "============================================="
echo "节点文件: $SUB_FILE"

echo "============== 已启用协议 =============="
echo "✓ VMess + WS + Argo TLS"
[ -n "$HY2_PORT" ]     && echo "✓ Hysteria2     端口 $HY2_PORT (UDP)"
[ -n "$TUIC_PORT" ]    && echo "✓ TUIC v5       端口 $TUIC_PORT (UDP)"
[ -n "$REALITY_PORT" ] && echo "✓ VLESS Reality 端口 $REALITY_PORT  PubKey: $REALITY_PUB"
[ -n "$SS_PORT" ]      && echo "✓ Shadowsocks   端口 $SS_PORT (TCP)"
echo "========================================"

wait $SB_PID
