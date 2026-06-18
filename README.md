# singbox

基于 sing-box + Cloudflare Argo 隧道的轻量代理工具，支持 VMess、Hysteria2、TUIC、VLESS Reality、Shadowsocks 协议。

## 部署方式

### 方式一：Docker 部署

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

上传 `entrypoint.sh` 到平台，设置启动命令为：

```bash
bash entrypoint.sh
```

### 方式三：一键脚本（含管理面板）

curl：
```bash
bash <(curl -sL https://raw.githubusercontent.com/zaofengyue/singbox/main/install.sh)
```

wget：
```bash
bash <(wget -qO- https://raw.githubusercontent.com/zaofengyue/singbox/main/install.sh)
```

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
| `PORT` | 对外监听端口 | 3000 |
| `NAME` | 节点名称前缀 | 自动识别|

### Argo 隧道

| 变量名 | 说明 | 默认值 |
|--------|------|--------|
| `ARGO_DOMAIN` | 固定隧道域名 | 留空使用临时隧道 |
| `ARGO_AUTH` | 固定隧道 Token | 留空使用临时隧道 |
| `ARGO_PORT` | Argo 内部端口 | 临时隧道随机，固定隧道默认 8001 |
| `DISABLE_ARGO` | 禁用 Argo 隧道 | 留空启用，填 `true` 禁用 |

### 可选协议（填写端口则启用，留空不启动）

| 变量名 | 说明 | 协议类型 |
|--------|------|----------|
| `HY2_PORT` | Hysteria2 端口 | UDP |
| `TUIC_PORT` | TUIC v5 端口 | UDP |
| `REALITY_PORT` | VLESS Reality 端口 | TCP |
| `REALITY_DOMAIN` | Reality 伪装域名 | 默认 `www.iij.ad.jp` |
| `SS_PORT` | Shadowsocks 2022 端口 | TCP |


## 注意事项

- 仅供学习研究使用，请遵守当地法律法规
- 临时隧道重启后域名会变，需要重新导入节点
- 固定隧道需要 Cloudflare 账号和托管域名
- sing-box 和 cloudflared 首次启动时自动下载，需要网络连接
- Hysteria2 / TUIC 使用自签证书，客户端需开启跳过证书验证
