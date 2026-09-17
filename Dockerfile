FROM node:20-alpine

ARG TARGETARCH

WORKDIR /app

# 1. 安装基础工具与 openssl（避免缺少 openssl 导致的自签私钥警告）
RUN apk add --no-cache curl unzip tar openssl bash ca-certificates jq

# 2. 预置多架构二进制 (sing-box, cloudflared, komari-agent)，实现容器秒级离线冷启动
RUN set -eux; \
    mkdir -p /root/sing-box /root/komari-agent; \
    case "${TARGETARCH}" in \
      amd64) \
        SB_ARCH="amd64"; CF_ARCH="linux-amd64"; KM_ARCH="linux-amd64" ;; \
      arm64) \
        SB_ARCH="arm64"; CF_ARCH="linux-arm64"; KM_ARCH="linux-arm64" ;; \
      *) \
        SB_ARCH="amd64"; CF_ARCH="linux-amd64"; KM_ARCH="linux-amd64" ;; \
    esac; \
    # 下载 sing-box (v1.12.0 稳定版)
    curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v1.12.0/sing-box-1.12.0-linux-${SB_ARCH}.tar.gz" -o /tmp/sb.tar.gz; \
    tar -xzf /tmp/sb.tar.gz -C /root/sing-box --strip-components=1; \
    rm -f /tmp/sb.tar.gz; \
    chmod +x /root/sing-box/sing-box; \
    # 下载 cloudflared
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${CF_ARCH}" -o /root/cloudflared; \
    chmod +x /root/cloudflared; \
    # 下载 komari-agent
    curl -fsSL "https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-${KM_ARCH}" -o /root/komari-agent/komari-agent; \
    chmod +x /root/komari-agent/komari-agent; \
    # 建立系统全局软链接
    ln -sf /root/sing-box/sing-box /usr/local/bin/sing-box; \
    ln -sf /root/cloudflared /usr/local/bin/cloudflared; \
    ln -sf /root/komari-agent/komari-agent /usr/local/bin/komari-agent

COPY package.json index.js index.html ./

CMD ["node", "index.js"]
