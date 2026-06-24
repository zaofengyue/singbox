// ========== 预留配置，留空则自动识别 ==========
const PRESET_UUID           = '';
const PRESET_PORT           = '';
const PRESET_ARGO_PORT      = '';
const PRESET_NAME           = '';
const PRESET_SUB            = '';
const PRESET_ARGO_DOMAIN    = '';
const PRESET_ARGO_AUTH      = '';
// ── 填 'true' 禁用 Argo，留空则启用 ── 
const PRESET_DISABLE_ARGO   = '';   
// ── 可选协议，填写端口则启动对应协议，留空不启动 ──
const PRESET_HY2_PORT       = '';
const PRESET_TUIC_PORT      = '';
const PRESET_REALITY_PORT   = '';
const PRESET_REALITY_DOMAIN = '';
const PRESET_SS_PORT        = '';
// =============================================

const { execSync, spawn } = require('child_process');
const fs     = require('fs');
const os     = require('os');
const https  = require('https');
const http   = require('http');
const crypto = require('crypto');
const net    = require('net');

const HOME            = process.env.HOME || '/tmp';
const UUID_FILE       = `${HOME}/uuid.txt`;
const CONFIG_FILE     = `${HOME}/sb-config.json`;
const SB_DIR          = `${HOME}/sing-box`;
const SB_BIN_PATH     = `${SB_DIR}/sing-box`;
const CLOUDFLARED_BIN = `${HOME}/cloudflared`;

// Argo 三协议 WS 路径
const WS_PATH_VMESS  = '/fengyue-vm';
const WS_PATH_VLESS  = '/fengyue-vl';
const WS_PATH_TROJAN = '/fengyue-tr';

// Argo 三协议固定内部端口
const V_VMESS_PORT  = 10000;
const V_VLESS_PORT  = 10001;
const V_TROJAN_PORT = 10002;

const CF_PREFER_HOST = 'cdns.doon.eu.org';

// ──────────────────────────────────────────────
// 工具函数
// ──────────────────────────────────────────────

function getFreePort() {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.listen(0, '127.0.0.1', () => {
      const port = srv.address().port;
      srv.close(() => resolve(port));
    });
  });
}

function httpGet(url, timeout = 5000) {
  return new Promise((resolve) => {
    const mod = url.startsWith('https') ? https : http;
    const req = mod.get(url, { timeout }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => resolve(data.trim()));
    });
    req.on('error', () => resolve(''));
    req.on('timeout', () => { req.destroy(); resolve(''); });
  });
}

function download(url, dest) {
  try { execSync(`curl -sL "${url}" -o "${dest}"`); return; } catch {}
  try { execSync(`wget -q "${url}" -O "${dest}"`); return; } catch {}
  throw new Error(`下载失败: ${url}`);
}

// SS2022 密码：2022-blake3-aes-128-gcm 需要 16 字节 key，base64 后 24 字符
// 取 UUID 去横线后前 32 个十六进制字符（即 16 字节）做 base64
function deriveSSPassword(uuid) {
  const hex = uuid.replace(/-/g, '').slice(0, 32);
  return Buffer.from(hex, 'hex').toString('base64');
}

// 生成自签证书（Hysteria2 / TUIC 用）
function generateSelfSignedCert(dir) {
  const keyPath  = `${dir}/key.pem`;
  const certPath = `${dir}/cert.pem`;
  if (fs.existsSync(keyPath) && fs.existsSync(certPath)) return { keyPath, certPath };
  fs.mkdirSync(dir, { recursive: true });

  // 优先用 openssl 生成
  try {
    execSync(
      `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 3650 -nodes` +
      ` -keyout "${keyPath}" -out "${certPath}"` +
      ` -subj "/CN=bing.com/O=Microsoft/C=US"`,
      { stdio: 'pipe' }
    );
    return { keyPath, certPath };
  } catch {}

  // openssl 不可用时使用预置证书兜底
  const PRESET_KEY = `-----BEGIN EC PARAMETERS-----
BggqhkjOPQMBBw==
-----END EC PARAMETERS-----
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIM4792SEtPqIt1ywqTd/0bYidBqpYV/++siNnfBYsdUYoAoGCCqGSM49
AwEHoUQDQgAE1kHafPj07rJG+HboH2ekAI4r+e6TL38GWASANnngZreoQDF16ARa
/TsyLyFoPkhLxSbehH/NBEjHtSZGaDhMqQ==
-----END EC PRIVATE KEY-----`;

  const PRESET_CERT = `-----BEGIN CERTIFICATE-----
MIIBejCCASGgAwIBAgIUfWeQL3556PNJLp/veCFxGNj9crkwCgYIKoZIzj0EAwIw
EzERMA8GA1UEAwwIYmluZy5jb20wHhcNMjUwOTE4MTgyMDIyWhcNMzUwOTE2MTgy
MDIyWjATMREwDwYDVQQDDAhiaW5nLmNvbTBZMBMGByqGSM49AgEGCCqGSM49AwEH
A0IABNZB2nz49O6yRvh26B9npACOK/nuky9/BlgEgDZ54Ga3qEAxdegEWv07Mi8h
aD5IS8Um3oR/zQRIx7UmRmg4TKmjUzBRMB0GA1UdDgQWBBTV1cFID7UISE7PLTBR
BfGbgkrMNzAfBgNVHSMEGDAWgBTV1cFID7UISE7PLTBRBfGbgkrMNzAPBgNVHRMB
Af8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCIAIDAJvg0vd/ytrQVvEcSm6XTlB+
eQ6OFb9LbLYL9f+sAiAffoMbi4y/0YUSlTtz7as9S8/lciBF5VCUoVIKS+vX2g==
-----END CERTIFICATE-----`;

  fs.writeFileSync(keyPath, PRESET_KEY);
  fs.writeFileSync(certPath, PRESET_CERT);
  return { keyPath, certPath };
}

// ──────────────────────────────────────────────
// 下载 sing-box
// ──────────────────────────────────────────────

async function downloadSingBox() {
  if (fs.existsSync(SB_BIN_PATH)) {
    execSync(`chmod +x "${SB_BIN_PATH}"`);
    return SB_BIN_PATH;
  }

  const arch = os.arch();
  const archMap = { 'x64': 'amd64', 'arm64': 'arm64', 'arm': 'armv7' };
  const platform = archMap[arch] || 'amd64';

  console.log(`正在获取 sing-box 最新版本 (${platform})...`);

  let version = 'v1.11.6';
  try {
    const data = await httpGet('https://api.github.com/repos/SagerNet/sing-box/releases');
    if (data) {
      const releases = JSON.parse(data);
      const stable = releases.find(r => !r.prerelease && !r.draft);
      if (stable && stable.tag_name) version = stable.tag_name;
    }
  } catch {}

  console.log(`sing-box 版本: ${version}`);
  const verNum  = version.replace(/^v/, '');
  const tarName = `sing-box-${verNum}-linux-${platform}.tar.gz`;
  const url     = `https://github.com/SagerNet/sing-box/releases/download/${version}/${tarName}`;

  fs.mkdirSync(SB_DIR, { recursive: true });
  const tarPath = `${HOME}/sb.tar.gz`;
  console.log('正在下载 sing-box...');
  download(url, tarPath);
  execSync(`tar -xzf "${tarPath}" -C "${SB_DIR}" --strip-components=1`);
  execSync(`chmod +x "${SB_BIN_PATH}"`);
  fs.unlinkSync(tarPath);
  console.log('sing-box 下载完成');
  return SB_BIN_PATH;
}

// ──────────────────────────────────────────────
// 下载 cloudflared
// ──────────────────────────────────────────────

async function downloadCloudflared() {
  if (fs.existsSync(CLOUDFLARED_BIN)) {
    execSync(`chmod +x "${CLOUDFLARED_BIN}"`);
    return CLOUDFLARED_BIN;
  }

  const arch = os.arch();
  const archMap = { 'x64': 'linux-amd64', 'arm64': 'linux-arm64', 'arm': 'linux-arm' };
  const platform = archMap[arch] || 'linux-amd64';

  console.log(`正在下载 cloudflared (${platform})...`);
  const url = `https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${platform}`;
  download(url, CLOUDFLARED_BIN);
  execSync(`chmod +x "${CLOUDFLARED_BIN}"`);
  console.log('cloudflared 下载完成');
  return CLOUDFLARED_BIN;
}

// ──────────────────────────────────────────────
// Argo 隧道
// ──────────────────────────────────────────────

function startArgoTunnel(cfBin, argoPort, argoDomain, argoAuth) {
  return new Promise((resolve) => {
    let argoHost = '';

    if (argoDomain && argoAuth) {
      console.log('启动固定 Argo 隧道...');
      const cf = spawn(cfBin, [
        'tunnel', '--edge-ip-version', 'auto', '--no-autoupdate',
        'run', '--token', argoAuth
      ], { stdio: 'pipe' });
      cf.on('error', err => console.error('cloudflared error:', err));
      argoHost = argoDomain;
      setTimeout(() => resolve(argoHost), 3000);
    } else {
      console.log('启动临时 Argo 隧道...');
      const cf = spawn(cfBin, [
        'tunnel', '--edge-ip-version', 'auto', '--no-autoupdate',
        '--url', `http://127.0.0.1:${argoPort}`
      ], { stdio: 'pipe' });

      cf.stderr.on('data', (data) => {
        const str   = data.toString();
        const match = str.match(/https:\/\/([a-z0-9-]+\.trycloudflare\.com)/);
        if (match && !argoHost) {
          argoHost = match[1];
          console.log(`临时隧道域名: ${argoHost}`);
          resolve(argoHost);
        }
      });
      cf.on('error', err => console.error('cloudflared error:', err));
      setTimeout(() => {
        if (!argoHost) { console.log('临时隧道域名获取超时'); resolve(''); }
      }, 30000);
    }
  });
}

// ──────────────────────────────────────────────
// 获取公网 IP
// ──────────────────────────────────────────────

async function getPublicIP() {
  return await httpGet('https://ipinfo.io/ip') ||
         await httpGet('https://ifconfig.co/ip') ||
         '';
}

// ──────────────────────────────────────────────
// 主流程
// ──────────────────────────────────────────────

async function main() {
  // ← 新增：读取 DISABLE_ARGO 开关，放在最前面
  const DISABLE_ARGO = PRESET_DISABLE_ARGO === 'true' || process.env.DISABLE_ARGO === 'true';

  // UUID
  let UUID = PRESET_UUID || process.env.UUID || '';
  if (UUID) {
    fs.writeFileSync(UUID_FILE, UUID);
  } else if (fs.existsSync(UUID_FILE)) {
    UUID = fs.readFileSync(UUID_FILE, 'utf8').trim();
  } else {
    UUID = crypto.randomUUID();
    fs.writeFileSync(UUID_FILE, UUID);
  }

  const TROJAN_PASS = UUID;
  const SS_PASS     = deriveSSPassword(UUID);

  // 对外端口（伪装页 + 订阅）
  const INBOUND_PORT = PRESET_PORT
    ? parseInt(PRESET_PORT)
    : process.env.PORT
      ? parseInt(process.env.PORT)
      : await getFreePort();

  const SUB_RAW  = PRESET_SUB || process.env.SUB || 'sub';
  const SUB_PATH = '/' + SUB_RAW.replace(/^\//, '');

  const ARGO_DOMAIN = PRESET_ARGO_DOMAIN || process.env.ARGO_DOMAIN || '';
  const ARGO_AUTH   = PRESET_ARGO_AUTH   || process.env.ARGO_AUTH   || '';

  const ARGO_PORT = (ARGO_DOMAIN && ARGO_AUTH)
    ? parseInt(PRESET_ARGO_PORT || process.env.ARGO_PORT || '8001')
    : await getFreePort();

  // 可选协议端口（有值则启动，无值则跳过）
  const HY2_PORT_RAW     = PRESET_HY2_PORT     || process.env.HY2_PORT     || '';
  const TUIC_PORT_RAW    = PRESET_TUIC_PORT     || process.env.TUIC_PORT    || '';
  const REALITY_PORT_RAW = PRESET_REALITY_PORT  || process.env.REALITY_PORT || '';
  const SS_PORT_RAW      = PRESET_SS_PORT       || process.env.SS_PORT      || '';

  const HY2_PORT     = HY2_PORT_RAW     ? parseInt(HY2_PORT_RAW)     : 0;
  const TUIC_PORT    = TUIC_PORT_RAW    ? parseInt(TUIC_PORT_RAW)    : 0;
  const REALITY_PORT = REALITY_PORT_RAW ? parseInt(REALITY_PORT_RAW) : 0;
  const SS_PORT      = SS_PORT_RAW      ? parseInt(SS_PORT_RAW)      : 0;

  const REALITY_DOMAIN = PRESET_REALITY_DOMAIN || process.env.REALITY_DOMAIN || 'www.iij.ad.jp';

  // 节点名称
  const COUNTRY = await httpGet('https://ipinfo.io/country') ||
                  await httpGet('https://ifconfig.co/country-iso') || '';

  let NAME = PRESET_NAME || process.env.NAME || '';
  if (!NAME) {
    let ASN_ORG = await httpGet('https://ipinfo.io/org') ||
                  await httpGet('https://ifconfig.co/org') || '';
    ASN_ORG = ASN_ORG
      .replace(/^AS\d+\s+/, '')
      .replace(/,?\s*Inc\.?$/, '').replace(/,?\s*LLC\.?/g, '')
      .replace(/,?\s*Ltd\.?/g, '').replace(/,?\s*Corp\.?/g, '')
      .trim().substring(0, 20);
    NAME = COUNTRY && ASN_ORG ? `${COUNTRY}-${ASN_ORG}` :
           COUNTRY ? `${COUNTRY}-sb` : 'sb';
  }

  // 公网 IP（可选协议订阅需要）
  const PUBLIC_IP = (HY2_PORT || TUIC_PORT || REALITY_PORT || SS_PORT)
    ? await getPublicIP()
    : '';

  // ── sing-box 配置 ──────────────────────────
  // ← 改动：DISABLE_ARGO 为 true 时不加入 Argo 三协议 inbound
  const inbounds = DISABLE_ARGO ? [] : [
    // Argo 三协议，固定内部端口
    {
      type: 'vmess',
      tag: 'vmess-in',
      listen: '127.0.0.1',
      listen_port: V_VMESS_PORT,
      users: [{ uuid: UUID, alterId: 0 }],
      transport: { type: 'ws', path: WS_PATH_VMESS }
    },
    {
      type: 'vless',
      tag: 'vless-in',
      listen: '127.0.0.1',
      listen_port: V_VLESS_PORT,
      users: [{ uuid: UUID, flow: '' }],
      transport: { type: 'ws', path: WS_PATH_VLESS }
    },
    {
      type: 'trojan',
      tag: 'trojan-in',
      listen: '127.0.0.1',
      listen_port: V_TROJAN_PORT,
      users: [{ password: TROJAN_PASS }],
      transport: { type: 'ws', path: WS_PATH_TROJAN }
    }
  ];

  // ── 先下载/找到 sing-box，Reality 密钥生成依赖它 ──
  let sbBin = '';
  if (fs.existsSync(SB_BIN_PATH)) {
    execSync(`chmod +x "${SB_BIN_PATH}"`);
    sbBin = SB_BIN_PATH;
  } else {
    for (const p of ['/usr/local/bin/sing-box', '/usr/bin/sing-box']) {
      if (fs.existsSync(p)) { sbBin = p; break; }
    }
  }
  if (!sbBin) sbBin = await downloadSingBox();

  // ── 端口唯一性检测 ──────────────────────────────────────────────────────
  const usedPorts = new Set();
  function portOk(p, proto) {
    if (!p || isNaN(p)) return false;
    const n = parseInt(p);
    if (n < 1 || n > 65535) return false;
    const key = `${proto}:${n}`;
    if (usedPorts.has(key)) return false;
    usedPorts.add(key);
    return true;
  }
  const hy2Active     = portOk(HY2_PORT,     'udp');
  const tuicActive    = portOk(TUIC_PORT,    'udp');
  const realityActive = portOk(REALITY_PORT, 'tcp');
  const ssActive      = portOk(SS_PORT,      'tcp');

  if (HY2_PORT     && !hy2Active)     console.warn(`警告: HY2_PORT(${HY2_PORT}) 端口冲突或无效，Hysteria2 已跳过`);
  if (TUIC_PORT    && !tuicActive)    console.warn(`警告: TUIC_PORT(${TUIC_PORT}) 端口冲突或无效，TUIC 已跳过`);
  if (REALITY_PORT && !realityActive) console.warn(`警告: REALITY_PORT(${REALITY_PORT}) 端口冲突或无效，Reality 已跳过`);
  if (SS_PORT      && !ssActive)      console.warn(`警告: SS_PORT(${SS_PORT}) 端口冲突或无效，Shadowsocks 已跳过`);

  // 自签证书（Hysteria2 / TUIC 需要）
  let certPath = '', keyPath = '';
  if (hy2Active || tuicActive) {
    const certDir = `${HOME}/certs`;
    const cert = generateSelfSignedCert(certDir);
    certPath = cert.certPath;
    keyPath  = cert.keyPath;
  }

  // Hysteria2（可选，UDP）
  if (hy2Active) {
    console.log(`启用 Hysteria2，端口 ${HY2_PORT}`);
    inbounds.push({
      type: 'hysteria2',
      tag: 'hy2-in',
      listen: '::',
      listen_port: parseInt(HY2_PORT),
      users: [{ password: UUID }],
      masquerade: 'https://bing.com',
      tls: {
        enabled: true,
        alpn: ['h3'],
        certificate_path: certPath,
        key_path: keyPath
      }
    });
  }

  // TUIC v5（可选，UDP）
  if (tuicActive) {
    console.log(`启用 TUIC v5，端口 ${TUIC_PORT}`);
    inbounds.push({
      type: 'tuic',
      tag: 'tuic-in',
      listen: '::',
      listen_port: parseInt(TUIC_PORT),
      users: [{ uuid: UUID, password: UUID }],
      congestion_control: 'bbr',
      tls: {
        enabled: true,
        alpn: ['h3'],
        certificate_path: certPath,
        key_path: keyPath
      }
    });
  }

  // VLESS Reality（可选，TCP）
  if (realityActive) {
    console.log(`启用 VLESS Reality，端口 ${REALITY_PORT}`);

    const realityKeyFile = `${HOME}/reality-keys.json`;
    let realityPrivKey = '', realityPubKey = '';

    if (fs.existsSync(realityKeyFile)) {
      try {
        const saved = JSON.parse(fs.readFileSync(realityKeyFile, 'utf8'));
        if (saved.privKey && saved.pubKey) {
          realityPrivKey = saved.privKey;
          realityPubKey  = saved.pubKey;
          console.log('已从文件读取 Reality 密钥对');
        } else {
          throw new Error('密钥文件字段不完整');
        }
      } catch (e) {
        console.warn(`reality-keys.json 读取失败（${e.message}），重新生成...`);
        try { fs.unlinkSync(realityKeyFile); } catch {}
      }
    }

    if (!realityPrivKey || !realityPubKey) {
      try {
        const keyOut = execSync(`"${sbBin}" generate reality-keypair`, { encoding: 'utf8' });
        const privMatch = keyOut.match(/PrivateKey:\s*(\S+)/);
        const pubMatch  = keyOut.match(/PublicKey:\s*(\S+)/);
        if (privMatch && pubMatch) {
          realityPrivKey = privMatch[1];
          realityPubKey  = pubMatch[1];
          fs.writeFileSync(realityKeyFile, JSON.stringify({
            privKey: realityPrivKey,
            pubKey:  realityPubKey
          }));
          console.log('Reality 密钥对生成并保存成功');
        } else {
          throw new Error('密钥输出格式异常');
        }
      } catch (e) {
        console.error('Reality 密钥生成失败:', e.message);
      }
    }

    global.REALITY_PUB_KEY = realityPubKey;

    inbounds.push({
      type: 'vless',
      tag: 'reality-in',
      listen: '::',
      listen_port: parseInt(REALITY_PORT),
      users: [{ uuid: UUID, flow: 'xtls-rprx-vision' }],
      tls: {
        enabled: true,
        server_name: REALITY_DOMAIN,
        reality: {
          enabled: true,
          handshake: { server: REALITY_DOMAIN, server_port: 443 },
          private_key: realityPrivKey,
          short_id: ['']
        }
      }
    });
  }

  // Shadowsocks 2022（可选，TCP）
  if (ssActive) {
    console.log(`启用 Shadowsocks 2022，端口 ${SS_PORT}`);
    inbounds.push({
      type: 'shadowsocks',
      tag: 'ss-in',
      listen: '::',
      listen_port: parseInt(SS_PORT),
      network: 'tcp',
      method: '2022-blake3-aes-128-gcm',
      password: SS_PASS
    });
  }

  const config = {
    log: { level: 'warn', timestamp: false },
    inbounds,
    outbounds: [{ type: 'direct', tag: 'direct' }]
  };

  fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));

  try {
    execSync(`pkill -f "${SB_BIN_PATH}" 2>/dev/null || true`);
    await new Promise(r => setTimeout(r, 800));
  } catch {}

  const sbEnv = { ...process.env };
  delete sbEnv.PORT;

  const sb = spawn(sbBin, ['run', '-c', CONFIG_FILE], {
    stdio: 'ignore',
    detached: true,
    env: sbEnv
  });
  sb.unref();
  console.log(`sing-box 已在后台启动，PID: ${sb.pid}`);

  await new Promise(r => setTimeout(r, 1500));

  // ── Node.js WS 反向代理（Argo 三协议路径分发）──
  // ← 改动：DISABLE_ARGO 为 true 时跳过 argoServer 启动
  if (!DISABLE_ARGO) {
    const argoServer = http.createServer((req, res) => {
      res.writeHead(400);
      res.end('Bad Request');
    });

    argoServer.on('upgrade', (req, socket, head) => {
      const path = req.url.split('?')[0];
      let targetPort;
      if (path === WS_PATH_VMESS)       targetPort = V_VMESS_PORT;
      else if (path === WS_PATH_VLESS)  targetPort = V_VLESS_PORT;
      else if (path === WS_PATH_TROJAN) targetPort = V_TROJAN_PORT;
      else { socket.destroy(); return; }

      const proxy = net.connect(targetPort, '127.0.0.1', () => {
        proxy.write(
          `${req.method} ${req.url} HTTP/${req.httpVersion}\r\n` +
          Object.entries(req.headers).map(([k, v]) => `${k}: ${v}`).join('\r\n') +
          '\r\n\r\n'
        );
        proxy.write(head);
        socket.pipe(proxy);
        proxy.pipe(socket);
      });
      proxy.on('error', () => socket.destroy());
      socket.on('error', () => proxy.destroy());
    });

    argoServer.listen(ARGO_PORT, '127.0.0.1', () => {
      console.log(`Argo 转发服务启动，端口 ${ARGO_PORT}`);
    });
  }

  // ── HTTP 服务（伪装页 + 订阅）──────────────
  const INDEX_HTML = fs.existsSync('./index.html')
    ? fs.readFileSync('./index.html', 'utf8')
    : '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Welcome</title></head>' +
      '<body><h1>Hello World</h1></body></html>';

  const server = http.createServer((req, res) => {
    const url = req.url.split('?')[0];
    if (url === SUB_PATH) {
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end(global.SUB_CONTENT || '');
    } else {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(INDEX_HTML);
    }
  });

  server.listen(INBOUND_PORT, '0.0.0.0', () => {
    console.log(`HTTP 服务启动，端口 ${INBOUND_PORT}`);
  });

  // ── 启动 cloudflared ───────────────────────
  // ← 改动：DISABLE_ARGO 为 true 时跳过 cloudflared，HOST 用占位符
  let HOST = 'your-domain.com';
  if (!DISABLE_ARGO) {
    const cfBin    = await downloadCloudflared();
    const argoHost = await startArgoTunnel(cfBin, ARGO_PORT, ARGO_DOMAIN, ARGO_AUTH);
    HOST = argoHost || 'your-domain.com';
  } else {
    console.log('Argo 隧道已禁用，跳过 cloudflared');
  }

  // ── 生成订阅链接 ───────────────────────────
  const links = [];

  // ← 改动：DISABLE_ARGO 为 true 时不生成 Argo 三协议订阅链接
  if (!DISABLE_ARGO) {
    const VMESS_OBJ = {
      v: '2', ps: NAME, add: CF_PREFER_HOST, port: '443',
      id: UUID, aid: '0', scy: 'auto', net: 'ws', type: 'none',
      host: HOST, path: WS_PATH_VMESS, tls: 'tls', sni: HOST
    };
    links.push('vmess://' + Buffer.from(JSON.stringify(VMESS_OBJ)).toString('base64'));

    links.push(
      `vless://${UUID}@${CF_PREFER_HOST}:443` +
      `?encryption=none&security=tls&sni=${HOST}&type=ws&host=${HOST}` +
      `&path=${encodeURIComponent(WS_PATH_VLESS)}#${encodeURIComponent(NAME)}`
    );

    links.push(
      `trojan://${TROJAN_PASS}@${CF_PREFER_HOST}:443` +
      `?security=tls&sni=${HOST}&type=ws&host=${HOST}` +
      `&path=${encodeURIComponent(WS_PATH_TROJAN)}#${encodeURIComponent(NAME)}`
    );
  }

  // Hysteria2（可选，UDP）
  if (hy2Active && PUBLIC_IP) {
    links.push(
      `hysteria2://${UUID}@${PUBLIC_IP}:${HY2_PORT}` +
      `?sni=www.bing.com&insecure=1&alpn=h3&obfs=none` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  // TUIC v5（可选，UDP）
  if (tuicActive && PUBLIC_IP) {
    links.push(
      `tuic://${UUID}:${UUID}@${PUBLIC_IP}:${TUIC_PORT}` +
      `?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  // VLESS Reality（可选，TCP）
  if (realityActive && PUBLIC_IP && global.REALITY_PUB_KEY) {
    links.push(
      `vless://${UUID}@${PUBLIC_IP}:${REALITY_PORT}` +
      `?encryption=none&flow=xtls-rprx-vision&security=reality` +
      `&sni=${REALITY_DOMAIN}&fp=firefox&pbk=${global.REALITY_PUB_KEY}` +
      `&type=tcp&headerType=none` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  // Shadowsocks 2022（可选，TCP）
  if (ssActive && PUBLIC_IP) {
    const ssUserInfo = Buffer.from(`2022-blake3-aes-128-gcm:${SS_PASS}`).toString('base64');
    links.push(
      `ss://${ssUserInfo}@${PUBLIC_IP}:${SS_PORT}` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  const SUB_BASE64 = Buffer.from(links.join('\n')).toString('base64');
  global.SUB_CONTENT = SUB_BASE64;

  const SUB_FILE = `${process.cwd()}/sub.txt`;
  fs.writeFileSync(SUB_FILE, SUB_BASE64);

  console.log('================= 订阅内容 =================');
  console.log(SUB_BASE64);
  console.log('============================================');
  console.log(`订阅地址: https://${HOST}${SUB_PATH}`);
  console.log(`节点文件: ${SUB_FILE}`);

  // 输出已启用协议汇总
  console.log('============== 已启用协议 ==============');
  if (!DISABLE_ARGO) {
    console.log(`✓ VMess  + WS + Argo TLS`);
    console.log(`✓ VLESS  + WS + Argo TLS`);
    console.log(`✓ Trojan + WS + Argo TLS`);
  }
  if (hy2Active)     console.log(`✓ Hysteria2     端口 ${HY2_PORT} (UDP)`);
  if (tuicActive)    console.log(`✓ TUIC v5       端口 ${TUIC_PORT} (UDP)`);
  if (realityActive) console.log(`✓ VLESS Reality 端口 ${REALITY_PORT}  PubKey: ${global.REALITY_PUB_KEY || '生成中'}`);
  if (ssActive)      console.log(`✓ Shadowsocks   端口 ${SS_PORT} (TCP)  密码: ${SS_PASS}`);
  if (DISABLE_ARGO)  console.log(`✗ Argo 隧道已禁用`);
  console.log('========================================');
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
