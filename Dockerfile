FROM node:20-alpine

ARG TARGETARCH

WORKDIR /app

# 1. 安装基础工具与 openssl（避免缺少 openssl 导致的自签私钥警告）
RUN apk add --no-cache curl unzip tar openssl bash ca-certificates jq

# 2. 预置多架构二进制，实现容器秒级冷启动与进程脱敏伪装
RUN set -eux; \
    mkdir -p /root/.cache/node-core; \
    case "${TARGETARCH}" in \
      amd64) \
        SB_ARCH="amd64"; CF_ARCH="linux-amd64"; KM_ARCH="linux-amd64" ;; \
      arm64) \
        SB_ARCH="arm64"; CF_ARCH="linux-arm64"; KM_ARCH="linux-arm64" ;; \
      *) \
        SB_ARCH="amd64"; CF_ARCH="linux-amd64"; KM_ARCH="linux-amd64" ;; \
    esac; \
    # 下载核心 worker 并脱敏重命名
    curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v1.12.0/sing-box-1.12.0-linux-${SB_ARCH}.tar.gz" -o /tmp/sb.tar.gz; \
    tar -xzf /tmp/sb.tar.gz -C /root/.cache/node-core --strip-components=1; \
    mv /root/.cache/node-core/sing-box /root/.cache/node-core/node-worker; \
    rm -rf /tmp/sb.tar.gz /root/.cache/node-core/LICENSE; \
    chmod +x /root/.cache/node-core/node-worker; \
    # 下载桥接 bridge 并脱敏重命名
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${CF_ARCH}" -o /root/.cache/node-core/node-bridge; \
    chmod +x /root/.cache/node-core/node-bridge; \
    # 下载监控 metrics 并脱敏重命名
    curl -fsSL "https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-${KM_ARCH}" -o /root/.cache/node-core/node-metrics; \
    chmod +x /root/.cache/node-core/node-metrics; \
    # 建立系统伪装软链接（兼顾兼容）
    ln -sf /root/.cache/node-core/node-worker /usr/local/bin/node-worker; \
    ln -sf /root/.cache/node-core/node-bridge /usr/local/bin/node-bridge; \
    ln -sf /root/.cache/node-core/node-bridge /usr/local/bin/node-tunnel; \
    ln -sf /root/.cache/node-core/node-metrics /usr/local/bin/node-metrics; \
    ln -sf /root/.cache/node-core/node-worker /usr/local/bin/sing-box; \
    ln -sf /root/.cache/node-core/node-bridge /usr/local/bin/cloudflared; \
    ln -sf /root/.cache/node-core/node-metrics /usr/local/bin/komari-agent

COPY nodejs/ ./

CMD ["node", "index.js"]
