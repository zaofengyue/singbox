# singbox

基于 sing-box + Cloudflare Argo 隧道的轻量代理工具。


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

### 方式三：一键脚本

curl：

```bash
bash <(curl -sL https://raw.githubusercontent.com/zaofengyue/singbox/main/entrypoint.sh)
```

wget：

```bash
bash <(wget -qO- https://raw.githubusercontent.com/zaofengyue/singbox/main/entrypoint.sh)
```

## 环境变量

| 变量名 | 说明 | 默认值 |
|---|---|---|
| `UUID` | 节点唯一ID | 自动生成 |
| `PORT` | 对外监听端口 | 自动找空闲 |
| `ARGO_PORT` | Argo 内部端口 | 临时隧道随机，固定隧道默认8001 |
| `NAME` | 节点名称 | 自动识别 |
| `ARGO_DOMAIN` | 固定隧道域名 | 留空用临时隧道 |
| `ARGO_AUTH` | 固定隧道Token | 留空用临时隧道 |

## 节点查看

部署成功后节点链接会输出到日志，同时写入 `sub.txt` 文件。

## 注意事项

- 仅供学习研究使用，请遵守当地法律法规
- 临时隧道重启后域名会变，需要重新导入节点
- 固定隧道需要 Cloudflare 账号和托管域名
- sing-box 和 cloudflared 启动时自动下载，首次启动需要联网
