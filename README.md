# singbox

基于 sing-box + Cloudflare Argo 隧道的轻量代理工具，支持 VMess、VLESS (Argo WS / Reality)、Hysteria2、TUIC v5、Trojan、Shadowsocks 2022、Socks5、AnyTLS 协议。

---

## 部署方式

### 方式一：Docker 部署
支持 `linux/amd64` 与 `linux/arm64` 双架构，镜像内置二进制并集成 openssl，秒级冷启动：

```bash
docker pull ghcr.io/zaofengyue/sbx:latest
```

```bash
docker run -d \
  -e UUID=你的UUID \
  -e ARGO_DOMAIN=你的域名 \
  -e ARGO_AUTH=你的Token \
  -e KOMARI_DOMAIN=你的Komari域名 \
  -e KOMARI_TOKEN=你的KomariToken \
  ghcr.io/zaofengyue/sbx:latest
```

### 方式二：Node.js 上传部署

上传 `nodejs` 目录下的文件至平台运行即可：

```text
nodejs/index.js
nodejs/package.json
nodejs/index.html（伪装页，可自行替换）
```

或直接下载 [Releases](https://github.com/zaofengyue/singbox/releases) 里的 `sbx.zip` 解压后上传。

启动命令：
```bash
npm install && npm start
# 或直接执行：node index.js
```

### 方式三：Python 部署
适用于各类 Python PaaS 平台（如 Koyeb、Zeabur、HuggingFace、Render 等）或 Linux / VPS 原生环境。支持 Linux 单进程内核接管技术，内存占用仅约 18MB：

上传 `python` 目录下的文件：
```text
python/app.py
python/requirements.txt
```

启动命令：
```bash
pip install -r requirements.txt
python app.py
```

### 方式四：Linux 一键脚本（含完整管理面板）

支持纯 IPv4、纯 IPv6、双栈以及 NAT4+IPv6 等多种复杂网络环境自适应：

**curl 运行：**
```bash
bash <(curl -sL https://raw.githubusercontent.com/zaofengyue/singbox/main/singbox.sh)
```

**wget 运行：**
```bash
bash <(wget -qO- https://raw.githubusercontent.com/zaofengyue/singbox/main/singbox.sh)
```

安装完成后可随时在终端使用快捷命令管理：

| 命令 | 说明 |
|------|------|
| `sb` | 交互式管理面板（查看节点、修改配置、证书管理、重启等）|
| `sb-sub` | 查看节点订阅与连接链接 |
| `sb-log` | 实时查看服务运行日志 |
| `sb-edit` | 快捷修改端口配置并自动重启生效 |
| `sb-del` | 彻底卸载清理相关服务与文件 |

---

## 环境变量说明

可通过环境变量或平台面板配置项进行自定义，留空则自动按默认逻辑运行：

### 1. 基础配置

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `UUID` | 节点唯一鉴权 UUID | 留空自动生成 |
| `PORT` | 对外 HTTP 监听端口（Web 伪装页与订阅） | 默认自动分配空闲端口（常用 3000 / 8080） |
| `PUBLIC_IP` / `IP` | 自定义公网 IP（NAT 服务器、云主机弹性 IP 时手动指定） | 留空多源自动探测 |
| `NAME` | 节点名称前缀 | 自动识别 IP 所在国家与组织 |
| `SUB` | 订阅路径后缀（例如填 `sub` 即对应 `/sub` 路径） | `sub` |

### 2. Argo 隧道配置

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `DISABLE_ARGO` | 禁用 Argo 隧道 | 留空启用，填 `true` 禁用 |
| `ARGO_DOMAIN` | 固定隧道域名（需搭配 Token 使用） | 留空使用 Cloudflare 临时隧道 |
| `ARGO_AUTH` | 固定隧道 Token 或凭证 | 留空使用 Cloudflare 临时隧道 |
| `ARGO_PORT` | Argo 内部转发端口 | 固定隧道默认 8001，临时隧道随机 |
| `ARGO_PROTOCOL` | Argo 隧道协议（可选 `quic`、`http2`） | 默认留空走高速 QUIC 优先链路 |
| `CF_PREFER_HOST` / `CF_IP` | Cloudflare 优选 CDN 域名或 IP（用于加速 Argo 节点） | 留空自动测速挑选内置优选池 |

### 3. 可选直连协议（填写端口则启用对应协议，留空不启动）

| 变量名 | 说明 | 协议类型 / 补充说明 |
|--------|------|-------------------|
| `HY2_PORT` | Hysteria2 端口 | UDP |
| `TUIC_PORT` | TUIC v5 端口 | UDP |
| `REALITY_PORT` | VLESS Reality 端口 | TCP |
| `REALITY_DOMAIN` | Reality 伪装域名 | 默认 `www.iij.ad.jp` |
| `SS_PORT` | Shadowsocks 2022 端口 | TCP（加密: `2022-blake3-aes-128-gcm`） |
| `SOCKS5_PORT` / `S5_PORT` | SOCKS5 端口 | TCP（认证: 用户名为 UUID 前8位，密码为后12位） |
| `ANYTLS_PORT` | AnyTLS 端口 | TCP（需核心版本 >= 1.12.0） |
| `TROJAN_PORT` | Trojan 端口 | TCP（注：Shell 脚本支持直连；Node/Python 版默认集成于 Argo WS 隧道） |

### 4. Komari 探针监控（可选，填写则上报监控，留空不启动）

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `KOMARI_DOMAIN` / `KOMARI_ENDPOINT` / `AGENT_ENDPOINT` | Komari 服务端域名或地址（如 `komari.example.com` 或 `http://IP:25774`） | 留空不启用 |
| `KOMARI_TOKEN` / `AGENT_TOKEN` | Komari 探针通信密钥 Token | 留空不启用 |

### 5. 进阶运行与运维控制（Node.js / Python 版通用）

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `SINGLE_PROCESS` / `FOREGROUND_CORE` | 极致单进程模式（填 `true` 开启，适合翼龙面板及 128MB 严苛容器） | `false` |
| `SHOW_LOG` | 控制台是否打印订阅信息（填 `false` 开启静默运行，防订阅泄露） | `true` |
| `LOG_CLEAR_MINUTES` | 控制台显示订阅信息后自动清屏销毁时间（分钟，填 `0` 不清屏） | `2`（分钟） |
| `TG_BOT_TOKEN` | Telegram Bot Token（配置后自动将订阅安全推送到 TG） | 留空不启用 |
| `TG_CHAT_ID` | Telegram Chat ID（接收推送的群组或个人 Chat ID） | 留空不启用 |

---

## 注意事项

- 本工具仅供学习与网络运维技术研究使用，请遵守当地法律法规。
- **临时隧道与固定隧道**：临时隧道在容器或服务重启后域名会重新分配，需要重新获取订阅；如需长期稳定使用，建议配置 Cloudflare 固定隧道（`ARGO_DOMAIN` + `ARGO_AUTH`）。
- **证书验证**：Hysteria2 / TUIC 默认使用自签证书，客户端连接时需开启“允许跳过证书验证”（`AllowInsecure` / `Insecure`）。
- **小内存与容器友好**：Docker 镜像已内置对应架构二进制与 openssl，秒级离线冷启动；Node.js 和 Python 版针对 Alpine/musl 环境深度优化，支持内存防膨胀（`GOMEMLIMIT`）与单进程运行模式。
