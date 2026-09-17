# singbox

基于 sing-box + Cloudflare Argo 隧道的轻量代理工具，支持 VMess、Hysteria2、TUIC、VLESS Reality、Trojan、Shadowsocks、Socks5、Anytls 协议。

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
  ghcr.io/zaofengyue/sbx:latest
```

### 方式二：上传文件部署

上传以下文件即可：

```
index.js
package.json
index.html（可选）
```

或直接下载 [Releases](https://github.com/zaofengyue/singbox/releases) 里的 `sbx.zip` 解压后上传。

### 方式三：一键脚本（含管理面板）

curl：
```bash
bash <(curl -sL https://raw.githubusercontent.com/zaofengyue/singbox/main/singbox.sh)
```

wget：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/zaofengyue/singbox/main/singbox.sh)
```

> **提示**：支持指定分支安装与测试，例如使用 `beta` 分支：
> ```bash
> BRANCH=beta bash <(curl -sL https://raw.githubusercontent.com/zaofengyue/singbox/beta/singbox.sh)
> ```

安装完成后可使用以下命令管理：

| 命令 | 说明 |
|------|------|
| `sb` | 管理面板（查看节点、修改配置、重启等）|
| `sb-sub` | 查看节点订阅 |
| `sb-log` | 查看运行日志 |
| `sb-edit` | 修改配置并重启 |
| `sb-del` | 彻底删除 |

## 环境变量

### 基础配置

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `UUID` | 节点唯一 ID | 自动生成 |
| `PORT` | 对外 HTTP 监听端口（Web 伪装页与订阅） | 3000 |
| `NAME` | 节点名称前缀 | 自动识别 IP 所在国家与组织 |
| `SUB` | 订阅路径后缀（如 `/sub`） | `sub` |

### Argo 隧道

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `DISABLE_ARGO` | 禁用 Argo 隧道 | 留空启用，填 `true` 禁用 |
| `ARGO_DOMAIN` | 固定隧道域名 | 留空使用临时隧道 |
| `ARGO_AUTH` | 固定隧道 Token / 凭证 | 留空使用临时隧道 |
| `ARGO_PORT` | Argo 内部转发端口 | 固定隧道默认 8001，临时隧道随机 |
| `ARGO_PROTOCOL` | Argo 隧道协议（`http2` / `quic` / `auto`） | `http2` |

### 可选协议（填写端口则启用对应协议，留空不启动）

| 变量名 | 说明 | 协议类型 |
|--------|------|----------|
| `HY2_PORT` | Hysteria2 端口 | UDP |
| `TUIC_PORT` | TUIC v5 端口 | UDP |
| `REALITY_PORT` | VLESS Reality 端口 | TCP |
| `REALITY_DOMAIN` | Reality 伪装域名 | 默认 `www.iij.ad.jp` |
| `SS_PORT` | Shadowsocks 2022 端口 | TCP |
| `SOCKS5_PORT` / `S5_PORT` | SOCKS5 端口 | TCP/UDP |
| `TROJAN_PORT` | Trojan 端口 | TCP |
| `ANYTLS_PORT` | AnyTLS 端口 | TCP |

### Komari 探针监控（可选，填写则上报监控，留空不启动）

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `KOMARI_DOMAIN` | Komari 服务端域名（如 `komari.example.com`） | 留空不启用 |
| `KOMARI_TOKEN` | Komari 探针通信密钥 Token | 留空不启用 |

### 日志控制与 Telegram 推送（Node 版独占）

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `SHOW_LOG` | 是否在控制台输出节点订阅日志（填 `false` 则完全不显示敏感信息） | `true` |
| `LOG_CLEAR_MINUTES` | 控制台显示节点信息后自动清除日志的等待时间（分钟，填 `0` 则不自动清理） | `2`（2分钟后自动清屏） |
| `TG_BOT_TOKEN` | Telegram Bot Token（配置后自动向 TG 发送节点信息与订阅） | 留空不启用 |
| `TG_CHAT_ID` | Telegram 接收推送的 Chat ID（在 `SHOW_LOG=false` 时依然能在 TG 安全查收） | 留空不启用 |

## 注意事项

- 仅供学习研究使用，请遵守当地法律法规
- 临时隧道重启后域名会变，需要重新导入节点
- 固定隧道需要 Cloudflare 账号和托管域名
- Docker 镜像已预置对应架构二进制与 openssl，容器秒级离线冷启动；Shell 脚本部署首次运行会自动拉取并持久化
- Hysteria2 / TUIC 使用自签证书，客户端需开启跳过证书验证
