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
SOCKS5_PORT="${SOCKS5_PORT:-}"
TROJAN_PORT="${TROJAN_PORT:-}"
ANYTLS_PORT="${ANYTLS_PORT:-}"
# 优选地址
CF_PREFER_HOST="${CF_PREFER_HOST:-cdns.doon.eu.org}"
WS_PATH="${WS_PATH:-/fengyue}"
# ==============================

HOME_DIR="${HOME:-/tmp}"
APP_DIR="$HOME_DIR/singbox"
# 所有含密钥/密码的文件集中放这一个目录下，目录本身 chmod 700，
# 不再散落在 $HOME 根目录（uuid.txt / sb-config.json / reality-keys.txt / outbound.conf / certs 到处都是）。
STATE_DIR="$APP_DIR/state"
mkdir -p "$STATE_DIR" "$APP_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

UUID_FILE="$STATE_DIR/uuid.txt"
CONFIG_FILE="$STATE_DIR/sb-config.json"
REALITY_KEY_FILE="$STATE_DIR/reality-keys.txt"
OUTBOUND_FILE="$STATE_DIR/outbound.conf"
CERT_DIR="$STATE_DIR/certs"
SUB_FILE="$APP_DIR/sub.txt"
CF_LOG="$APP_DIR/cf.log"

# 兼容旧版本：把之前散落在 $HOME 根目录下的文件自动迁移到新位置，避免升级后 UUID/密钥丢失
for _pair in "uuid.txt:$UUID_FILE" "sb-config.json:$CONFIG_FILE" \
             "reality-keys.txt:$REALITY_KEY_FILE" "outbound.conf:$OUTBOUND_FILE"; do
  _legacy_src="$HOME_DIR/${_pair%%:*}"
  _legacy_dst="${_pair#*:}"
  if [ -f "$_legacy_src" ] && [ ! -f "$_legacy_dst" ]; then
    mv "$_legacy_src" "$_legacy_dst" 2>/dev/null || true
  fi
done
if [ -d "$HOME_DIR/certs" ] && [ ! -d "$CERT_DIR" ]; then
  mv "$HOME_DIR/certs" "$CERT_DIR" 2>/dev/null || true
fi

# 二进制优先落在 /tmp，避免 $HOME noexec 问题
BIN_DIR="/tmp/sb-bin"
SB_DIR="$BIN_DIR/singbox"
SB_BIN="$SB_DIR/sing-box"
CF_BIN="$BIN_DIR/cloudflared"

# ── 工具函数 ──────────────────────────────────────────────────────────────────

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }
die()  { echo "[ERROR] $*"; exit 1; }

# 在 Alpine/musl 等极简发行版上，curl/tar 甚至 openssl 都可能没预装。
# 这里尝试自动装（仅在识别到 apk/apt 且是 root 时），装不了就明确报错退出，
# 而不是让脚本在后面某个 http_get/dl 调用里悄悄返回空字符串、最后死得不明不白。
try_install_pkg() {
  _pkg="$1"
  if command -v apk >/dev/null 2>&1; then
    [ "$(id -u)" = "0" ] && apk add --no-cache "$_pkg" >/dev/null 2>&1
  elif command -v apt-get >/dev/null 2>&1; then
    [ "$(id -u)" = "0" ] && { apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq "$_pkg" >/dev/null 2>&1; }
  fi
}

ensure_basic_deps() {
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    warn "缺少 curl/wget，尝试自动安装 curl..."
    try_install_pkg curl
  fi
  if ! command -v tar >/dev/null 2>&1; then
    warn "缺少 tar，尝试自动安装..."
    try_install_pkg tar
  fi
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    die "缺少 curl/wget，且自动安装失败。Alpine 请手动执行: apk add --no-cache curl；Debian/Ubuntu: apt-get install -y curl"
  fi
  if ! command -v tar >/dev/null 2>&1; then
    die "缺少 tar，且自动安装失败。Alpine 请手动执行: apk add --no-cache tar"
  fi
}
ensure_basic_deps

http_get() {
  if command -v curl >/dev/null 2>&1; then
    curl -sL --max-time 5 "$1" 2>/dev/null || true
  else
    wget -qO- --timeout=5 "$1" 2>/dev/null || true
  fi
}

dl() {
  # 下载并校验：失败(网络错误/HTTP错误码/空文件)会重试，最终仍失败则返回非零
  _url="$1"; _out="$2"; _tries=0
  while [ "$_tries" -lt 3 ]; do
    if command -v curl >/dev/null 2>&1; then
      curl -sL --fail --max-time 60 "$_url" -o "$_out" 2>/dev/null
    else
      wget -q --timeout=60 "$_url" -O "$_out" 2>/dev/null
    fi
    if [ -s "$_out" ]; then
      return 0
    fi
    _tries=$((_tries + 1))
    warn "下载失败(第 ${_tries} 次): $_url"
    rm -f "$_out"
    sleep 2
  done
  return 1
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

# JSON 字符串转义（反斜杠和双引号），用于任何可能包含特殊字符的用户输入
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# IPv6 地址加方括号包裹，IPv4 原样返回
format_addr() {
  case "$1" in
    *:*) printf '[%s]' "$1" ;;
    *)   printf '%s' "$1" ;;
  esac
}

# 端口合法性检查（参数：端口值，协议 tcp/udp，已用端口列表文件）
USED_PORTS_FILE="/tmp/sb-used-ports.txt"

# 探测端口是否已被系统上其他进程占用（TCP 和 UDP 都查），
# 这是 sing-box check 覆盖不到的：check 只校验配置语法，不做实际 bind 测试，
# 真正 bind 失败要等到 run 时才会暴露，而且会导致整个多协议进程直接退出。
port_in_use_os() {
  _p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":${_p} " && return 0
    ss -lun 2>/dev/null | grep -q ":${_p} " && return 0
    return 1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -q ":${_p} " && return 0
    netstat -lun 2>/dev/null | grep -q ":${_p} " && return 0
    return 1
  fi
  return 1
}

port_ok() {
  _p="$1"
  [ -z "$_p" ] && return 1
  case "$_p" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$_p" -lt 1 ] || [ "$_p" -gt 65535 ] && return 1
  grep -qx "$_p" "$USED_PORTS_FILE" 2>/dev/null && return 1
  if port_in_use_os "$_p"; then
    return 1
  fi
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
# 严格校验 UUID 格式：UUID 可能来自外部环境变量/表单输入，
# 不校验的话它会被原样拼进下面的 python -c "..." 源码字符串里，
# 精心构造的值（比如带单引号和分号）可以借此执行任意 python 代码。
valid_uuid() {
  case "$1" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
      return 0 ;;
    *) return 1 ;;
  esac
}

if [ -n "$UUID" ]; then
  valid_uuid "$UUID" || die "UUID 格式不合法: ${UUID}（必须是标准格式，如 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx）"
  echo "$UUID" > "$UUID_FILE"
elif [ -f "$UUID_FILE" ]; then
  UUID="$(cat "$UUID_FILE")"
  valid_uuid "$UUID" || die "uuid.txt 中的 UUID 格式已损坏，请删除该文件后重试: $UUID_FILE"
else
  UUID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
    || python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null \
    || python  -c 'import uuid; print(uuid.uuid4())' 2>/dev/null \
    || od -x /dev/urandom | head -1 | awk '{print $2$3"-"$4"-"$5"-"$6"-"$7$8$9}')"
  echo "$UUID" > "$UUID_FILE"
fi
chmod 600 "$UUID_FILE" 2>/dev/null || true

# SS2022 密码：取 UUID 前 16 字节做 base64（24字符）
# 优先 python3，备选 openssl（不再依赖 xxd，Alpine/busybox 环境通常没有 xxd）
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
if [ -z "$SS_PASS" ] && [ -n "$SS_PORT" ] && ! command -v openssl >/dev/null 2>&1; then
  warn "缺少 openssl，尝试自动安装..."
  try_install_pkg openssl
fi
if [ -z "$SS_PASS" ] && command -v openssl >/dev/null 2>&1; then
  _hex="$(echo "$UUID" | tr -d '-' | cut -c1-32)"
  # 把十六进制字符串转成 \xHH 转义序列交给 printf 还原成原始字节，不再需要 xxd
  _hexesc="$(printf '%s' "$_hex" | sed 's/\(..\)/\\x\1/g')"
  SS_PASS="$(printf "$_hexesc" | openssl base64 -A 2>/dev/null)" || SS_PASS=""
fi
if [ -z "$SS_PASS" ] && [ -n "$SS_PORT" ]; then
  warn "SS2022 密码生成失败（需要 python3/python/openssl），Shadowsocks 将被跳过"
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
  if [ -z "$SB_VER" ]; then
    SB_VER="v1.12.0"
    warn "获取最新版本号失败（可能是 GitHub API 限流），回退到 ${SB_VER}，较新协议（如 AnyTLS）可能不受支持"
  fi
  SB_VER_NUM="${SB_VER#v}"
  log "下载 sing-box ${SB_VER} (${SB_ARCH})..."
  if ! dl "https://github.com/SagerNet/sing-box/releases/download/${SB_VER}/sing-box-${SB_VER_NUM}-linux-${SB_ARCH}.tar.gz" \
     /tmp/sing-box.tar.gz; then
    die "sing-box 下载失败（网络问题或版本 ${SB_VER} 不存在该架构的构建），请检查网络后重试"
  fi
  if ! tar -tzf /tmp/sing-box.tar.gz >/dev/null 2>&1; then
    rm -f /tmp/sing-box.tar.gz
    die "sing-box 压缩包已损坏（下载不完整），请重新运行脚本"
  fi
  tar -xzf /tmp/sing-box.tar.gz -C "$SB_DIR" --strip-components=1
  chmod +x "$SB_BIN"
  rm -f /tmp/sing-box.tar.gz
  if ! "$SB_BIN" version >/dev/null 2>&1; then
    rm -f "$SB_BIN"
    die "sing-box 二进制无法执行（架构可能不匹配: ${SB_ARCH}），请检查系统架构"
  fi
  log "sing-box 下载完成: $("$SB_BIN" version 2>/dev/null | head -1)"
}

# ── 下载 cloudflared ──────────────────────────────────────────────────────────
download_cloudflared() {
  log "正在下载 cloudflared (${CF_ARCH})..."
  if ! dl "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${CF_ARCH}" "$CF_BIN"; then
    warn "cloudflared 下载失败，Argo 隧道本次将被禁用"
    DISABLE_ARGO="true"
    return 1
  fi
  chmod +x "$CF_BIN"
  if ! "$CF_BIN" --version >/dev/null 2>&1; then
    warn "cloudflared 二进制无法执行（架构可能不匹配: ${CF_ARCH}），Argo 隧道本次将被禁用"
    rm -f "$CF_BIN"
    DISABLE_ARGO="true"
    return 1
  fi
  log "cloudflared 下载完成"
}

# 清理旧进程
pkill -f "$SB_BIN"    2>/dev/null || true
pkill -f "$CF_BIN"    2>/dev/null || true
sleep 1

[ -x "$SB_BIN" ] && ! "$SB_BIN" version >/dev/null 2>&1 && { warn "已存在的 sing-box 二进制无法运行，重新下载"; rm -f "$SB_BIN"; }
[ -x "$SB_BIN" ] || download_singbox

if [ "${DISABLE_ARGO:-}" != "true" ]; then
  [ -x "$CF_BIN" ] && ! "$CF_BIN" --version >/dev/null 2>&1 && { warn "已存在的 cloudflared 二进制无法运行，重新下载"; rm -f "$CF_BIN"; }
  [ -x "$CF_BIN" ] || download_cloudflared || true
fi

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
# 校验拿到的到底像不像一个 IP：出口网络异常时，ipinfo.io 之类的接口可能返回
# 代理拦截页/验证码页/captive portal 的 HTML，而不是纯 IP 文本。不校验的话，
# 这段垃圾内容会被原样拼进 SOCKS5/Trojan/Hysteria2 等订阅链接里。
valid_ip() {
  _v="$1"
  [ -z "$_v" ] && return 1
  [ "${#_v}" -gt 45 ] && return 1
  case "$_v" in
    *[!0-9a-fA-F:.]*) return 1 ;;
    *[0-9]*) : ;;
    *) return 1 ;;
  esac
  return 0
}

PUBLIC_IP=""
if [ -n "$HY2_PORT" ] || [ -n "$TUIC_PORT" ] || [ -n "$REALITY_PORT" ] || [ -n "$SS_PORT" ] || [ -n "$SOCKS5_PORT" ] || [ -n "$TROJAN_PORT" ] || [ -n "$ANYTLS_PORT" ]; then
  for _ipsrc in 'https://ipinfo.io/ip' 'https://ifconfig.co/ip' 'https://api64.ipify.org' 'https://v6.ident.me'; do
    _cand="$(http_get "$_ipsrc" | tr -d '[:space:]')"
    if valid_ip "$_cand"; then
      PUBLIC_IP="$_cand"
      break
    fi
  done
  if [ -z "$PUBLIC_IP" ]; then
    warn "公网 IP 获取失败或返回内容不像有效 IP，依赖公网 IP 的协议（HY2/TUIC/Reality/SS/SOCKS5/Trojan/AnyTLS）本次订阅链接将缺失对应节点"
  fi
fi

# ── 自签证书（HY2 / TUIC 用）─────────────────────────────────────────────────
CERT_PATH=""
KEY_PATH=""
if [ -n "$HY2_PORT" ] || [ -n "$TUIC_PORT" ] || [ -n "$TROJAN_PORT" ] || [ -n "$ANYTLS_PORT" ]; then
  mkdir -p "$CERT_DIR"
  CERT_PATH="$CERT_DIR/cert.pem"
  KEY_PATH="$CERT_DIR/key.pem"
  if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
    if ! command -v openssl >/dev/null 2>&1; then
      warn "缺少 openssl，尝试自动安装（否则将回退到内置的共享自签证书）..."
      try_install_pkg openssl
    fi
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
  chmod 600 "$KEY_PATH" 2>/dev/null || true
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
      chmod 600 "$REALITY_KEY_FILE" 2>/dev/null || true
      log "Reality 密钥生成完成"
    else
      warn "Reality 密钥生成失败，VLESS Reality 将被跳过"
      REALITY_PORT=""
    fi
  else
    log "已从文件读取 Reality 密钥对"
  fi
fi

# ── 自定义出口（SOCKS/HTTP）──────────────────────────────────────────────────
CUSTOM_OUT_TYPE=""
CUSTOM_OUT_ADDR=""
CUSTOM_OUT_PORT=""
CUSTOM_OUT_USER=""
CUSTOM_OUT_PASS=""
EXTRA_OUTBOUND_JSON=""

if [ -f "$OUTBOUND_FILE" ]; then
  CUSTOM_OUT_TYPE="$(grep '^TYPE=' "$OUTBOUND_FILE" | sed 's/^TYPE=//')"
  CUSTOM_OUT_ADDR="$(grep '^ADDR=' "$OUTBOUND_FILE" | sed 's/^ADDR=//')"
  CUSTOM_OUT_PORT="$(grep '^PORT=' "$OUTBOUND_FILE" | sed 's/^PORT=//')"
  CUSTOM_OUT_USER="$(grep '^USER=' "$OUTBOUND_FILE" | sed 's/^USER=//')"
  CUSTOM_OUT_PASS="$(grep '^PASS=' "$OUTBOUND_FILE" | sed 's/^PASS=//')"
fi

if [ "$CUSTOM_OUT_TYPE" = "socks" ] || [ "$CUSTOM_OUT_TYPE" = "http" ]; then
  if [ -n "$CUSTOM_OUT_ADDR" ] && [ -n "$CUSTOM_OUT_PORT" ]; then
    log "检测到自定义出口配置: ${CUSTOM_OUT_TYPE}://${CUSTOM_OUT_ADDR}:${CUSTOM_OUT_PORT}"
    if [ -n "$CUSTOM_OUT_USER" ]; then
      EXTRA_OUTBOUND_JSON=",
    {
      \"type\": \"${CUSTOM_OUT_TYPE}\",
      \"tag\": \"custom-out\",
      \"server\": \"${CUSTOM_OUT_ADDR}\",
      \"server_port\": ${CUSTOM_OUT_PORT},
      \"username\": \"${CUSTOM_OUT_USER}\",
      \"password\": \"${CUSTOM_OUT_PASS}\"
    }"
    else
      EXTRA_OUTBOUND_JSON=",
    {
      \"type\": \"${CUSTOM_OUT_TYPE}\",
      \"tag\": \"custom-out\",
      \"server\": \"${CUSTOM_OUT_ADDR}\",
      \"server_port\": ${CUSTOM_OUT_PORT}
    }"
    fi
  else
    warn "outbound.conf 配置不完整，自定义出口已跳过"
  fi
fi

# ── 端口合法性检查 ────────────────────────────────────────────────────────────
HY2_ACTIVE=0; TUIC_ACTIVE=0; REALITY_ACTIVE=0; SS_ACTIVE=0; SOCKS5_ACTIVE=0; TROJAN_ACTIVE=0; ANYTLS_ACTIVE=0

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
if [ -n "$SOCKS5_PORT" ]; then
  if port_ok "$SOCKS5_PORT"; then SOCKS5_ACTIVE=1;
  else warn "SOCKS5_PORT(${SOCKS5_PORT}) 无效或冲突，SOCKS5 已跳过"; fi
fi
if [ -n "$TROJAN_PORT" ]; then
  if port_ok "$TROJAN_PORT"; then TROJAN_ACTIVE=1;
  else warn "TROJAN_PORT(${TROJAN_PORT}) 无效或冲突，Trojan 已跳过"; fi
fi
if [ -n "$ANYTLS_PORT" ]; then
  if port_ok "$ANYTLS_PORT"; then ANYTLS_ACTIVE=1;
  else warn "ANYTLS_PORT(${ANYTLS_PORT}) 无效或冲突，AnyTLS 已跳过"; fi
fi

# ── 生成 sing-box 配置 ────────────────────────────────────────────────────────
# 逐协议增量校验：每加入一个 inbound 就用 sing-box check 单独验证一次，
# 校验失败只跳过该协议（并关闭其 _ACTIVE 标记，保证后续订阅/日志展示一致），
# 不再因为某一个协议不兼容当前 sing-box 版本就让整个脚本直接退出。
# 校验失败时可能要把 sing-box 的报错甚至配置文件本身打到日志(journal)里排查，
# 但配置里有 UUID / SS 密码 / Reality 私钥，直接照抄会把这些明文写进日志，
# 尤其是 systemd Restart=always 场景下会一次次重复泄露。统一做脱敏。
redact_secrets() {
  sed \
    -e "s|${UUID:-__no_uuid__}|<UUID>|g" \
    -e "s|${SS_PASS:-__no_ss_pass__}|<SS_PASSWORD>|g" \
    -e "s|${REALITY_PRIV:-__no_reality_priv__}|<REALITY_PRIVATE_KEY>|g"
}

_inbounds=""
_sep=""

# $1=协议标签(用于日志)  $2=该协议的 inbound JSON 片段（不带前导逗号）
try_add_inbound() {
  _label="$1"
  _snippet="$2"
  _trial="${_inbounds}${_sep}
    ${_snippet}"
  _tc="/tmp/sb-trycfg-$$.json"
  _tl="/tmp/sb-trylog-$$.log"
  : > "$_tc"; chmod 600 "$_tc" 2>/dev/null || true
  : > "$_tl"; chmod 600 "$_tl" 2>/dev/null || true
  printf '{\n  "log": { "level": "warn" },\n  "inbounds": [\n    %s\n  ],\n  "outbounds": [{ "type": "direct", "tag": "direct" }]\n}\n' "$_trial" > "$_tc"
  if "$SB_BIN" check -c "$_tc" >"$_tl" 2>&1; then
    _inbounds="$_trial"
    _sep=","
    rm -f "$_tc" "$_tl"
    return 0
  else
    warn "${_label} 配置校验未通过，已跳过该协议（不影响其他协议启动）:"
    redact_secrets < "$_tl" | sed 's/^/    /'
    rm -f "$_tc" "$_tl"
    return 1
  fi
}

# Argo VMess inbound
if [ "${DISABLE_ARGO:-}" != "true" ]; then
  _vmess_json="{
      \"type\": \"vmess\",
      \"tag\": \"vmess-in\",
      \"listen\": \"127.0.0.1\",
      \"listen_port\": ${ARGO_PORT},
      \"users\": [{ \"uuid\": \"${UUID}\", \"alterId\": 0 }],
      \"transport\": { \"type\": \"ws\", \"path\": \"$(json_escape "$WS_PATH")\" }
    }"
  if ! try_add_inbound "VMess/Argo" "$_vmess_json"; then
    warn "VMess 基础入口校验失败，Argo 隧道本次将不启动"
    DISABLE_ARGO="true"
  fi
fi

if [ "$HY2_ACTIVE" = "1" ]; then
  _hy2_json="{
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
  try_add_inbound "Hysteria2" "$_hy2_json" || HY2_ACTIVE=0
fi

if [ "$TUIC_ACTIVE" = "1" ]; then
  _tuic_json="{
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
  try_add_inbound "TUIC" "$_tuic_json" || TUIC_ACTIVE=0
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
      \"users\": [{ \"username\": \"singbox\", \"password\": \"${UUID}\" }]
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
        \"certificate_path\": \"${CERT_PATH}\",
        \"key_path\": \"${KEY_PATH}\"
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
        \"certificate_path\": \"${CERT_PATH}\",
        \"key_path\": \"${KEY_PATH}\"
      }
    }"
  try_add_inbound "AnyTLS" "$_anytls_json" || ANYTLS_ACTIVE=0
fi

if [ -z "$_inbounds" ]; then
  die "所有协议均校验失败，没有任何可用入口，终止启动（请检查 sing-box 版本是否过旧）"
fi

ROUTE_JSON=""
[ -n "$EXTRA_OUTBOUND_JSON" ] && ROUTE_JSON=',
  "route": { "final": "custom-out" }'

printf '{\n  "log": { "level": "warn", "timestamp": false },\n  "inbounds": [\n    %s\n  ],\n  "outbounds": [{ "type": "direct", "tag": "direct" }%s]%s\n}\n' \
  "$_inbounds" "$EXTRA_OUTBOUND_JSON" "$ROUTE_JSON" > "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE" 2>/dev/null || true

# 最终整体校验：单个 inbound 都已验证过，这一步主要防的是出站/路由部分的问题
# （比如自定义出口配置有误）。如果失败，先尝试去掉自定义出口再试一次，仍失败才终止。
_fc="/tmp/sb-finalcheck-$$.log"
: > "$_fc"; chmod 600 "$_fc" 2>/dev/null || true
if ! "$SB_BIN" check -c "$CONFIG_FILE" 2>"$_fc"; then
  warn "整体配置校验失败，尝试去除自定义出口后重试："
  redact_secrets < "$_fc" | sed 's/^/    /'
  if [ -n "$EXTRA_OUTBOUND_JSON" ]; then
    EXTRA_OUTBOUND_JSON=""
    ROUTE_JSON=""
    printf '{\n  "log": { "level": "warn", "timestamp": false },\n  "inbounds": [\n    %s\n  ],\n  "outbounds": [{ "type": "direct", "tag": "direct" }]\n}\n' \
      "$_inbounds" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    if "$SB_BIN" check -c "$CONFIG_FILE" 2>/dev/null; then
      warn "已回退为直连出口，自定义出口本次未生效"
    else
      warn "sing-box 配置校验仍然失败，输出配置内容以供排查（已脱敏 UUID/密码/私钥）："
      redact_secrets < "$CONFIG_FILE"
      rm -f "$_fc"
      # 持续性故障标记：如果 60 秒内已经因为同样的原因失败过，
      # 说明这不是偶发问题（比如配置本身就有问题），额外等待，
      # 避免 systemd Restart=always 把同样的报错每 10 秒刷一遍日志。
      _failmark="$STATE_DIR/.last-config-fail"
      _now="$(date +%s 2>/dev/null || echo 0)"
      if [ -f "$_failmark" ]; then
        _last="$(cat "$_failmark" 2>/dev/null || echo 0)"
        if [ $((_now - _last)) -lt 60 ]; then
          warn "60 秒内已重复失败，额外等待 60 秒再退出，避免刷屏..."
          sleep 60
        fi
      fi
      echo "$_now" > "$_failmark" 2>/dev/null || true
      die "配置无效，终止启动"
    fi
  else
    warn "sing-box 配置校验仍然失败，输出配置内容以供排查（已脱敏 UUID/密码/私钥）："
    redact_secrets < "$CONFIG_FILE"
    rm -f "$_fc"
    die "配置无效，终止启动"
  fi
else
  rm -f "$_fc"
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

# ── Argo 隧道启动/重连函数 ────────────────────────────────────────────────────
# 临时隧道每次(重新)连接都会拿到一个新的随机 trycloudflare.com 域名，
# 所以这个函数封装了"启动 cloudflared + 解析新域名"，并在结尾统一调用
# generate_sub 用新域名重写订阅文件。看门狗每次重启 cloudflared 都会调用它，
# 而不再是只在脚本启动时解析一次域名。
ARGO_HOST=""
CF_PID=""

start_cloudflared() {
  if [ -n "$ARGO_DOMAIN" ] && [ -n "$ARGO_AUTH" ]; then
    log "启动固定 Argo 隧道..."
    "$CF_BIN" tunnel --edge-ip-version auto --no-autoupdate \
      run --token "$ARGO_AUTH" >/dev/null 2>&1 &
    CF_PID=$!
    sleep 3
    ARGO_HOST="$ARGO_DOMAIN"
  else
    log "启动临时 Argo 隧道..."
    rm -f "$CF_LOG"
    "$CF_BIN" tunnel --edge-ip-version auto --no-autoupdate \
      --url "http://127.0.0.1:${ARGO_PORT}" \
      --logfile "$CF_LOG" >/dev/null 2>&1 &
    CF_PID=$!
    _new_host=""
    i=0
    while [ $i -lt 30 ]; do
      _new_host="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null \
        | head -1 | sed 's|https://||')"
      [ -n "$_new_host" ] && break
      sleep 1
      i=$((i+1))
    done
    if [ -n "$_new_host" ]; then
      ARGO_HOST="$_new_host"
    else
      warn "隧道域名获取失败，沿用上一次的域名（如果有），订阅可能暂时无法使用"
      [ -z "$ARGO_HOST" ] && ARGO_HOST="your-domain.com"
    fi
  fi

  if [ "$ARGO_HOST" = "your-domain.com" ]; then
    warn "隧道域名仍为占位符，订阅链接将暂时无效"
  else
    log "隧道域名: $ARGO_HOST"
  fi

  # 每次(重新)拿到域名后都要重写订阅文件，这是修复"重启后订阅永久失效"的关键
  generate_sub
}

# ── 生成订阅链接（可重复调用，用于隧道重连后刷新 sub.txt）────────────────────
generate_sub() {
  ALL_LINKS=""

  if [ "${DISABLE_ARGO:-}" != "true" ]; then
    VMESS_JSON="{\"v\":\"2\",\"ps\":\"$(json_escape "$NAME")\",\"add\":\"cdns.doon.eu.org\",\"port\":\"443\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ARGO_HOST}\",\"path\":\"$(json_escape "$WS_PATH")\",\"tls\":\"tls\",\"sni\":\"${ARGO_HOST}\"}"
    ALL_LINKS="vmess://$(b64 "$VMESS_JSON")"
  fi

  if [ "$HY2_ACTIVE" = "1" ] && [ -n "$PUBLIC_IP" ]; then
    _link="hysteria2://${UUID}@$(format_addr "$PUBLIC_IP"):${HY2_PORT}?sni=www.bing.com&insecure=1&alpn=h3&obfs=none#${NAME_ENCODED}"
    ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
  fi

  if [ "$TUIC_ACTIVE" = "1" ] && [ -n "$PUBLIC_IP" ]; then
    _link="tuic://${UUID}:${UUID}@$(format_addr "$PUBLIC_IP"):${TUIC_PORT}?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1#${NAME_ENCODED}"
    ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
  fi

  if [ "$REALITY_ACTIVE" = "1" ] && [ -n "$PUBLIC_IP" ] && [ -n "$REALITY_PUB" ]; then
    _link="vless://${UUID}@$(format_addr "$PUBLIC_IP"):${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_DOMAIN}&fp=firefox&pbk=${REALITY_PUB}&type=tcp&headerType=none#${NAME_ENCODED}"
    ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
  fi

  if [ "$SS_ACTIVE" = "1" ] && [ -n "$PUBLIC_IP" ]; then
    SS_USERINFO="$(b64 "2022-blake3-aes-128-gcm:${SS_PASS}")"
    _link="ss://${SS_USERINFO}@$(format_addr "$PUBLIC_IP"):${SS_PORT}#${NAME_ENCODED}"
    ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
  fi

  if [ "$SOCKS5_ACTIVE" = "1" ] && [ -n "$PUBLIC_IP" ]; then
    _link="socks5://singbox:${UUID}@$(format_addr "$PUBLIC_IP"):${SOCKS5_PORT}#${NAME_ENCODED}"
    ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
  fi

  if [ "$TROJAN_ACTIVE" = "1" ] && [ -n "$PUBLIC_IP" ]; then
    _link="trojan://${UUID}@$(format_addr "$PUBLIC_IP"):${TROJAN_PORT}?security=tls&sni=bing.com&allowInsecure=1&fp=firefox#${NAME_ENCODED}"
    ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
  fi

  if [ "$ANYTLS_ACTIVE" = "1" ] && [ -n "$PUBLIC_IP" ]; then
    _link="anytls://${UUID}@$(format_addr "$PUBLIC_IP"):${ANYTLS_PORT}?sni=bing.com&insecure=1#${NAME_ENCODED}"
    ALL_LINKS="${ALL_LINKS:+${ALL_LINKS}
}${_link}"
  fi

  SUB_BASE64="$(b64 "$ALL_LINKS")"
  echo "$SUB_BASE64" > "$SUB_FILE"
  chmod 600 "$SUB_FILE" 2>/dev/null || true

  log "================= 订阅内容 (已刷新) ================="
  echo "$SUB_BASE64"
  log "======================================================"
  log "节点文件: $SUB_FILE"
}

if [ "${DISABLE_ARGO:-}" != "true" ]; then
  start_cloudflared
else
  # Argo 被禁用时也要生成一次订阅（只含直连协议的节点）
  generate_sub
fi

log "============== 已启用协议 =============="
[ "${DISABLE_ARGO:-}" != "true" ] && log "✓ VMess + WS + Argo TLS  (域名: $ARGO_HOST)"
[ "${DISABLE_ARGO:-}" = "true"  ] && log "✗ Argo 隧道已禁用"
[ "$HY2_ACTIVE"     = "1" ] && log "✓ Hysteria2     端口 $HY2_PORT (UDP)"
[ "$TUIC_ACTIVE"    = "1" ] && log "✓ TUIC v5       端口 $TUIC_PORT (UDP)"
[ "$REALITY_ACTIVE" = "1" ] && log "✓ VLESS Reality 端口 $REALITY_PORT  PubKey: $REALITY_PUB"
[ "$SS_ACTIVE"      = "1" ] && log "✓ Shadowsocks   端口 $SS_PORT (TCP)"
[ "$SOCKS5_ACTIVE"  = "1" ] && log "✓ SOCKS5        端口 $SOCKS5_PORT (TCP/UDP)  用户: singbox"
[ "$TROJAN_ACTIVE"  = "1" ] && log "✓ Trojan        端口 $TROJAN_PORT (TCP)"
[ "$ANYTLS_ACTIVE"  = "1" ] && log "✓ AnyTLS        端口 $ANYTLS_PORT (TCP)"
[ -n "$EXTRA_OUTBOUND_JSON" ] && log "✓ 自定义出口    ${CUSTOM_OUT_TYPE}://${CUSTOM_OUT_ADDR}:${CUSTOM_OUT_PORT}"
log "========================================"

# ── 守护循环 ──────────────────────────────────────────────────────────────────
# sing-box 和 cloudflared 分别独立检测、独立重启，互不依赖：
# 以前 cloudflared 崩溃只有在 sing-box 也一起崩溃时才会被顺带重拉，
# 现在两者各自都有存活检查。cloudflared 每次重启都会重新调用
# start_cloudflared，临时隧道的新域名会被重新解析并写回 sub.txt。
# 加入退避重试：如果是持续性故障（比如端口被别的进程永久占用），
# 不会每 10-15 秒就重启一次刷屏，重试间隔会随连续失败次数递增，最长封顶 60 秒。
log "进入守护模式..."
SB_FAIL_COUNT=0
CF_FAIL_COUNT=0
while true; do
  if ! kill -0 $SB_PID 2>/dev/null; then
    SB_FAIL_COUNT=$((SB_FAIL_COUNT + 1))
    _backoff=$((SB_FAIL_COUNT * 5))
    [ "$_backoff" -gt 60 ] && _backoff=60
    warn "sing-box 意外退出（连续第 ${SB_FAIL_COUNT} 次），${_backoff} 秒后重启..."
    sleep "$_backoff"
    if start_singbox; then
      SB_FAIL_COUNT=0
    else
      warn "重启失败，继续等待..."
      sleep 10
      continue
    fi
  fi

  if [ "${DISABLE_ARGO:-}" != "true" ]; then
    if [ -z "$CF_PID" ] || ! kill -0 "$CF_PID" 2>/dev/null; then
      CF_FAIL_COUNT=$((CF_FAIL_COUNT + 1))
      _cf_backoff=$((CF_FAIL_COUNT * 5))
      [ "$_cf_backoff" -gt 60 ] && _cf_backoff=60
      warn "cloudflared 意外退出（或未运行，连续第 ${CF_FAIL_COUNT} 次），${_cf_backoff} 秒后重启..."
      pkill -f "$CF_BIN" 2>/dev/null || true
      sleep "$_cf_backoff"
      start_cloudflared
    else
      CF_FAIL_COUNT=0
    fi
  fi

  sleep 10
done
