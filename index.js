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
const PRESET_S5_PORT        = '';
const PRESET_ANYTLS_PORT    = '';
// =============================================

const { execSync, spawn } = require('child_process');
const fs     = require('fs');
const os     = require('os');
const https  = require('https');
const http   = require('http');
const crypto = require('crypto');
const net    = require('net');

const HOME            = process.env.HOME || os.tmpdir();
const UUID_FILE       = `${HOME}/uuid.txt`;
const CONFIG_FILE     = `${HOME}/sb-config.json`;
const SB_DIR          = `${HOME}/sing-box`;
const SB_BIN_NAME     = os.platform() === 'win32' ? 'sing-box.exe' : 'sing-box';
const SB_BIN_PATH     = `${SB_DIR}/${SB_BIN_NAME}`;
const CLOUDFLARED_BIN = `${HOME}/cloudflared${os.platform() === 'win32' ? '.exe' : ''}`;

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

// 跨平台下载：优先 curl，再 wget，最后用 Node 原生 https 请求兜底
// （部分容器环境可能既没有 curl 也没有 wget）
function download(url, dest) {
  try { execSync(`curl -fsSL "${url}" -o "${dest}"`, { stdio: 'pipe' }); return; } catch {}
  try { execSync(`wget -q "${url}" -O "${dest}"`, { stdio: 'pipe' }); return; } catch {}
  return downloadWithNode(url, dest);
}

function downloadWithNode(url, dest) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith('https') ? https : http;
    const file = fs.createWriteStream(dest);
    const req = mod.get(url, (res) => {
      // 处理重定向
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        file.close();
        fs.unlinkSync(dest);
        return downloadWithNode(res.headers.location, dest).then(resolve, reject);
      }
      if (res.statusCode !== 200) {
        file.close();
        return reject(new Error(`下载失败，HTTP状态码: ${res.statusCode}`));
      }
      res.pipe(file);
      file.on('finish', () => file.close(resolve));
    });
    req.on('error', (err) => { try { fs.unlinkSync(dest); } catch {} reject(err); });
  });
}

// SS2022 密码：2022-blake3-aes-128-gcm 需要 16 字节 key，base64 后 24 字符
// 取 UUID 去横线后前 32 个十六进制字符（即 16 字节）做 base64
function deriveSSPassword(uuid) {
  const hex = uuid.replace(/-/g, '').slice(0, 32);
  return Buffer.from(hex, 'hex').toString('base64');
}

// ──────────────────────────────────────────────
// 自签证书：每个部署实例都生成独一无二的密钥
// ──────────────────────────────────────────────

function generateSelfSignedCert(dir) {
  const keyPath  = `${dir}/key.pem`;
  const certPath = `${dir}/cert.pem`;
  if (fs.existsSync(keyPath) && fs.existsSync(certPath)) {
    return { keyPath, certPath };
  }
  fs.mkdirSync(dir, { recursive: true });

  // 优先用系统 openssl 生成
  try {
    execSync(
      `openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -days 3650 -nodes` +
      ` -keyout "${keyPath}" -out "${certPath}"` +
      ` -subj "/CN=bing.com/O=Microsoft/C=US"`,
      { stdio: 'pipe' }
    );
    secureFilePermissions(keyPath);
    return { keyPath, certPath };
  } catch {
    console.log('系统未检测到 openssl，使用 Node.js 内置 crypto 现场生成专属证书...');
  }

  // ⚠️ 安全警示：以下为共享兜底证书，仅适用于个人测试/学习场景。
  // 该私钥已写入源码、随脚本公开传播，任何使用此兜底路径的部署实例
  // 用的都是同一套私钥。生产环境或对外提供服务，请务必安装 openssl
  // 让上面的分支生成你自己独有的证书，不要依赖这段兜底。
  console.warn(
    '\x1b[33m%s\x1b[0m',
    '[警告] 系统缺少 openssl，将使用源码内置的共享测试证书（私钥已公开，仅供个人测试，请勿用于生产/对外服务）'
  );
  const FALLBACK_PRIVATE_KEY = `-----BEGIN EC PARAMETERS-----
BggqhkjOPQMBBw==
-----END EC PARAMETERS-----
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIM4792SEtPqIt1ywqTd/0bYidBqpYV/++siNnfBYsdUYoAoGCCqGSM49
AwEHoUQDQgAE1kHafPj07rJG+HboH2ekAI4r+e6TL38GWASANnngZreoQDF16ARa
/TsyLyFoPkhLxSbehH/NBEjHtSZGaDhMqQ==
-----END EC PRIVATE KEY-----`;
  const FALLBACK_CERT = `-----BEGIN CERTIFICATE-----
MIIBejCCASGgAwIBAgIUfWeQL3556PNJLp/veCFxGNj9crkwCgYIKoZIzj0EAwIw
EzERMA8GA1UEAwwIYmluZy5jb20wHhcNMjUwOTE4MTgyMDIyWhcNMzUwOTE2MTgy
MDIyWjATMREwDwYDVQQDDAhiaW5nLmNvbTBZMBMGByqGSM49AgEGCCqGSM49AwEH
A0IABNZB2nz49O6yRvh26B9npACOK/nuky9/BlgEgDZ54Ga3qEAxdegEWv07Mi8h
aD5IS8Um3oR/zQRIx7UmRmg4TKmjUzBRMB0GA1UdDgQWBBTV1cFID7UISE7PLTBR
BfGbgkrMNzAfBgNVHSMEGDAWgBTV1cFID7UISE7PLTBRBfGbgkrMNzAPBgNVHRMB
Af8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCIAIDAJvg0vd/ytrQVvEcSm6XTlB+
eQ6OFb9LbLYL9f+sAiAffoMbi4y/0YUSlTtz7as9S8/lciBF5VCUoVIKS+vX2g==
-----END CERTIFICATE-----`;

  fs.writeFileSync(keyPath, FALLBACK_PRIVATE_KEY);
  fs.writeFileSync(certPath, FALLBACK_CERT);
  secureFilePermissions(keyPath);
  return { keyPath, certPath };
}

// 限制密钥文件权限，仅当前用户可读写，降低同机其他用户/进程读取风险
function secureFilePermissions(filePath) {
  if (os.platform() === 'win32') return; // Windows 权限模型不同，跳过
  try { fs.chmodSync(filePath, 0o600); } catch (e) {
    console.warn(`设置文件权限失败 ${filePath}: ${e.message}`);
  }
}

// ──────────────────────────────────────────────
// 下载 sing-box（跨平台架构识别）
// ──────────────────────────────────────────────

function detectArch() {
  const arch = os.arch();
  const archMap = {
    x64:   'amd64',
    arm64: 'arm64',
    arm:   'armv7',
    ia32:  '386',
  };
  return archMap[arch] || 'amd64';
}

function detectOS() {
  const platform = os.platform();
  if (platform === 'darwin') return 'darwin';
  if (platform === 'win32') return 'windows';
  return 'linux';
}

async function downloadSingBox() {
  if (fs.existsSync(SB_BIN_PATH)) {
    if (os.platform() !== 'win32') execSync(`chmod +x "${SB_BIN_PATH}"`);
    return SB_BIN_PATH;
  }

  const arch = detectArch();
  const platform = detectOS();

  console.log(`正在获取 sing-box 最新版本 (${platform}-${arch})...`);

  // 兜底版本必须 >= 1.12.0，否则 AnyTLS 协议类型无法被识别，
  // sing-box 会在配置校验阶段整体拒绝启动（影响全部协议，不仅是AnyTLS）
  let version = 'v1.12.0';
  try {
    const data = await httpGet('https://api.github.com/repos/SagerNet/sing-box/releases');
    if (data) {
      const releases = JSON.parse(data);
      const stable = releases.find(r => !r.prerelease && !r.draft);
      if (stable && stable.tag_name) version = stable.tag_name;
    }
  } catch {}

  console.log(`sing-box 版本: ${version}`);
  const verNum = version.replace(/^v/, '');
  const ext = platform === 'windows' ? 'zip' : 'tar.gz';
  const tarName = `sing-box-${verNum}-${platform}-${arch}.${ext}`;
  const url = `https://github.com/SagerNet/sing-box/releases/download/${version}/${tarName}`;

  fs.mkdirSync(SB_DIR, { recursive: true });
  const tarPath = `${HOME}/sb.${ext}`;
  console.log('正在下载 sing-box...');
  await download(url, tarPath);

  if (ext === 'zip') {
    // Windows 环境用 PowerShell 解压，避免依赖 unzip
    execSync(`powershell -Command "Expand-Archive -Path '${tarPath}' -DestinationPath '${SB_DIR}' -Force"`);
  } else {
    execSync(`tar -xzf "${tarPath}" -C "${SB_DIR}" --strip-components=1`);
  }

  if (platform !== 'windows') execSync(`chmod +x "${SB_BIN_PATH}"`);
  fs.unlinkSync(tarPath);
  console.log('sing-box 下载完成');
  return SB_BIN_PATH;
}

// ──────────────────────────────────────────────
// 下载 cloudflared（跨平台架构识别）
// ──────────────────────────────────────────────

async function downloadCloudflared() {
  if (fs.existsSync(CLOUDFLARED_BIN)) {
    if (os.platform() !== 'win32') execSync(`chmod +x "${CLOUDFLARED_BIN}"`);
    return CLOUDFLARED_BIN;
  }

  const platform = os.platform();
  const arch = os.arch();

  const archMap = {
    linux:  { x64: 'linux-amd64',   arm64: 'linux-arm64',   arm: 'linux-arm' },
    darwin: { x64: 'darwin-amd64',  arm64: 'darwin-arm64' },
    win32:  { x64: 'windows-amd64.exe', ia32: 'windows-386.exe' },
  };

  const suffix = (archMap[platform] && archMap[platform][arch]) || 'linux-amd64';
  console.log(`正在下载 cloudflared (${suffix})...`);
  const url = `https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-${suffix}`;
  await download(url, CLOUDFLARED_BIN);
  if (platform !== 'win32') execSync(`chmod +x "${CLOUDFLARED_BIN}"`);
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
  secureFilePermissions(UUID_FILE);

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

  // 可选协议端口
  const HY2_PORT_RAW     = PRESET_HY2_PORT     || process.env.HY2_PORT     || '';
  const TUIC_PORT_RAW    = PRESET_TUIC_PORT    || process.env.TUIC_PORT    || '';
  const REALITY_PORT_RAW = PRESET_REALITY_PORT || process.env.REALITY_PORT || '';
  const SS_PORT_RAW      = PRESET_SS_PORT      || process.env.SS_PORT      || '';
  const S5_PORT_RAW      = PRESET_S5_PORT      || process.env.S5_PORT      || '';
  const ANYTLS_PORT_RAW  = PRESET_ANYTLS_PORT  || process.env.ANYTLS_PORT  || '';

  const HY2_PORT     = HY2_PORT_RAW     ? parseInt(HY2_PORT_RAW)     : 0;
  const TUIC_PORT    = TUIC_PORT_RAW    ? parseInt(TUIC_PORT_RAW)    : 0;
  const REALITY_PORT = REALITY_PORT_RAW ? parseInt(REALITY_PORT_RAW) : 0;
  const SS_PORT      = SS_PORT_RAW      ? parseInt(SS_PORT_RAW)      : 0;
  const S5_PORT       = S5_PORT_RAW     ? parseInt(S5_PORT_RAW)      : 0;
  const ANYTLS_PORT   = ANYTLS_PORT_RAW ? parseInt(ANYTLS_PORT_RAW)  : 0;

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

  // 公网 IP（可选协议订阅需要，新增 S5/AnyTLS 也依赖公网IP）
  const PUBLIC_IP = (HY2_PORT || TUIC_PORT || REALITY_PORT || SS_PORT || S5_PORT || ANYTLS_PORT)
    ? await getPublicIP()
    : '';

  // ── sing-box 配置 ──────────────────────────
  const inbounds = DISABLE_ARGO ? [] : [
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
    if (os.platform() !== 'win32') execSync(`chmod +x "${SB_BIN_PATH}"`);
    sbBin = SB_BIN_PATH;
  } else {
    const candidatePaths = os.platform() === 'win32'
      ? ['C:\\sing-box\\sing-box.exe']
      : ['/usr/local/bin/sing-box', '/usr/bin/sing-box'];
    for (const p of candidatePaths) {
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
  const s5Active      = portOk(S5_PORT,      'tcp');
  const anytlsActive  = portOk(ANYTLS_PORT,  'tcp');

  if (HY2_PORT     && !hy2Active)     console.warn(`警告: HY2_PORT(${HY2_PORT}) 端口冲突或无效，Hysteria2 已跳过`);
  if (TUIC_PORT    && !tuicActive)    console.warn(`警告: TUIC_PORT(${TUIC_PORT}) 端口冲突或无效，TUIC 已跳过`);
  if (REALITY_PORT && !realityActive) console.warn(`警告: REALITY_PORT(${REALITY_PORT}) 端口冲突或无效，Reality 已跳过`);
  if (SS_PORT      && !ssActive)      console.warn(`警告: SS_PORT(${SS_PORT}) 端口冲突或无效，Shadowsocks 已跳过`);
  if (S5_PORT      && !s5Active)      console.warn(`警告: S5_PORT(${S5_PORT}) 端口冲突或无效，Socks5 已跳过`);
  if (ANYTLS_PORT  && !anytlsActive)  console.warn(`警告: ANYTLS_PORT(${ANYTLS_PORT}) 端口冲突或无效，AnyTLS 已跳过`);

  // 自签证书（Hysteria2 / TUIC / AnyTLS 需要）
  // 证书生成失败只影响这三个依赖证书的协议，不应让整个脚本崩溃退出
  let certPath = '', keyPath = '';
  let certReady = false;
  if (hy2Active || tuicActive || anytlsActive) {
    try {
      const certDir = `${HOME}/certs`;
      const cert = generateSelfSignedCert(certDir);
      certPath = cert.certPath;
      keyPath  = cert.keyPath;
      certReady = true;
    } catch (e) {
      console.error(`证书生成失败，Hysteria2/TUIC/AnyTLS 将被跳过: ${e.message}`);
      certReady = false;
    }
  }
  // 证书不可用时，强制关闭依赖证书的协议，避免后续用空路径写入畸形配置
  if (!certReady) {
    if (hy2Active)    console.warn('因证书不可用，Hysteria2 已跳过');
    if (tuicActive)   console.warn('因证书不可用，TUIC 已跳过');
    if (anytlsActive) console.warn('因证书不可用，AnyTLS 已跳过');
  }
  const hy2Final     = hy2Active && certReady;
  const tuicFinal    = tuicActive && certReady;
  const anytlsFinal  = anytlsActive && certReady;

  // Hysteria2（可选，UDP）
  if (hy2Final) {
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
  if (tuicFinal) {
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
          secureFilePermissions(realityKeyFile);
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

  // ───── 新增：Socks5（可选，TCP） ─────
  if (s5Active) {
    console.log(`启用 Socks5，端口 ${S5_PORT}`);
    inbounds.push({
      type: 'socks',
      tag: 's5-in',
      listen: '::',
      listen_port: parseInt(S5_PORT),
      users: [
        {
          username: UUID.substring(0, 8),
          password: UUID.slice(-12)
        }
      ]
    });
  }

  // ───── 新增：AnyTLS（可选，TCP） ─────
  if (anytlsFinal) {
    console.log(`启用 AnyTLS，端口 ${ANYTLS_PORT}`);
    inbounds.push({
      type: 'anytls',
      tag: 'anytls-in',
      listen: '::',
      listen_port: parseInt(ANYTLS_PORT),
      users: [{ password: UUID }],
      tls: {
        enabled: true,
        certificate_path: certPath,
        key_path: keyPath
      }
    });
  }

  const config = {
    log: { level: 'warn', timestamp: false },
    inbounds,
    outbounds: [{ type: 'direct', tag: 'direct' }]
  };

  fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2));

  // 打印实际拿到的 sing-box 版本，方便排查"协议不支持"类问题
  try {
    const verOut = execSync(`"${sbBin}" version`, { encoding: 'utf8' });
    console.log('sing-box 版本信息:\n' + verOut.trim());
  } catch (e) {
    console.warn(`无法获取 sing-box 版本信息: ${e.message}`);
  }

  // 启动前先做一次配置校验。sing-box 对配置文件是整体原子校验的——
  // 任何一个 inbound 类型不被当前版本识别，都会导致进程拒绝启动，
  // 进而连累所有协议（包括 Argo 转发依赖的 vmess/vless/trojan）。
  // 提前 check 可以在真正启动前就发现问题，并把错误打印出来，
  // 而不是让 sing-box 静默崩溃、什么日志都看不到。
  const SB_LOG_FILE = `${SB_DIR}/run.log`;
  try {
    execSync(`"${sbBin}" check -c "${CONFIG_FILE}"`, { encoding: 'utf8', stdio: 'pipe' });
    console.log('sing-box 配置校验通过');
  } catch (e) {
    const detail = (e.stdout || '') + (e.stderr || '') + e.message;
    console.error('================ sing-box 配置校验失败 ================');
    console.error(detail.trim());
    console.error('========================================================');
    console.error(
      '常见原因：当前 sing-box 版本过旧，不支持某个已启用的协议类型' +
      '（例如 AnyTLS 需要 sing-box >= 1.12.0）。' +
      '请删除本地 sing-box 二进制后重新运行脚本以下载最新版本，' +
      '或关闭对应协议端口变量后重试。'
    );
    fs.writeFileSync(SB_LOG_FILE, `[CONFIG CHECK FAILED]\n${detail}\n`);
    console.log(`详细日志已写入: ${SB_LOG_FILE}`);
    console.log('配置校验未通过，跳过启动 sing-box（Argo/HTTP订阅服务仍会继续运行）。');
    global.SB_START_FAILED = true;
  }

  try {
    if (os.platform() !== 'win32') {
      execSync(`pkill -f "${SB_BIN_PATH}" 2>/dev/null || true`);
    }
    await new Promise(r => setTimeout(r, 800));
  } catch {}

  const sbEnv = { ...process.env };
  delete sbEnv.PORT;

  if (!global.SB_START_FAILED) {
    // 不再用 stdio: 'ignore' 丢弃输出，改为写入日志文件，
    // 这样在翼龙/Pterodactyl 等只能看面板日志的环境下，
    // sing-box 启动失败时也能看到具体报错原因。
    const sbLogFd = fs.openSync(SB_LOG_FILE, 'a');
    const sb = spawn(sbBin, ['run', '-c', CONFIG_FILE], {
      stdio: ['ignore', sbLogFd, sbLogFd],
      detached: os.platform() !== 'win32',
      env: sbEnv
    });
    sb.unref();
    console.log(`sing-box 已在后台启动，PID: ${sb.pid}`);
    console.log(`运行日志: ${SB_LOG_FILE}`);

    sb.on('error', (err) => {
      console.error(`sing-box 进程启动失败: ${err.message}`);
    });
  }

  await new Promise(r => setTimeout(r, 1500));

  // ── Node.js WS 反向代理（Argo 三协议路径分发）──
  if (!DISABLE_ARGO) {
    const argoServer = http.createServer((req, res) => {
      res.writeHead(400);
      res.end('Bad Request');
    });

    argoServer.on('upgrade', (req, socket, head) => {
      const reqPath = req.url.split('?')[0];
      let targetPort;
      if (reqPath === WS_PATH_VMESS)       targetPort = V_VMESS_PORT;
      else if (reqPath === WS_PATH_VLESS)  targetPort = V_VLESS_PORT;
      else if (reqPath === WS_PATH_TROJAN) targetPort = V_TROJAN_PORT;
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

  if (hy2Final && PUBLIC_IP) {
    links.push(
      `hysteria2://${UUID}@${PUBLIC_IP}:${HY2_PORT}` +
      `?sni=www.bing.com&insecure=1&alpn=h3&obfs=none` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  if (tuicFinal && PUBLIC_IP) {
    links.push(
      `tuic://${UUID}:${UUID}@${PUBLIC_IP}:${TUIC_PORT}` +
      `?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  if (realityActive && PUBLIC_IP && global.REALITY_PUB_KEY) {
    links.push(
      `vless://${UUID}@${PUBLIC_IP}:${REALITY_PORT}` +
      `?encryption=none&flow=xtls-rprx-vision&security=reality` +
      `&sni=${REALITY_DOMAIN}&fp=firefox&pbk=${global.REALITY_PUB_KEY}` +
      `&type=tcp&headerType=none` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  if (ssActive && PUBLIC_IP) {
    const ssUserInfo = Buffer.from(`2022-blake3-aes-128-gcm:${SS_PASS}`).toString('base64');
    links.push(
      `ss://${ssUserInfo}@${PUBLIC_IP}:${SS_PORT}` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  // ───── 新增：Socks5 订阅链接 ─────
  if (s5Active && PUBLIC_IP) {
    const s5UserInfo = Buffer.from(`${UUID.substring(0, 8)}:${UUID.slice(-12)}`).toString('base64');
    links.push(
      `socks://${s5UserInfo}@${PUBLIC_IP}:${S5_PORT}` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  // ───── 新增：AnyTLS 订阅链接 ─────
  if (anytlsFinal && PUBLIC_IP) {
    links.push(
      `anytls://${UUID}@${PUBLIC_IP}:${ANYTLS_PORT}` +
      `?security=tls&sni=www.bing.com&fp=chrome&insecure=1&allowInsecure=1` +
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
  if (hy2Final)      console.log(`✓ Hysteria2     端口 ${HY2_PORT} (UDP)`);
  if (tuicFinal)     console.log(`✓ TUIC v5       端口 ${TUIC_PORT} (UDP)`);
  if (realityActive) console.log(`✓ VLESS Reality 端口 ${REALITY_PORT}  PubKey: ${global.REALITY_PUB_KEY || '生成中'}`);
  if (ssActive)      console.log(`✓ Shadowsocks   端口 ${SS_PORT} (TCP)  密码: ${SS_PASS}`);
  if (s5Active)      console.log(`✓ Socks5        端口 ${S5_PORT} (TCP)  账号: ${UUID.substring(0, 8)}`);
  if (anytlsFinal)   console.log(`✓ AnyTLS        端口 ${ANYTLS_PORT} (TCP)`);
  if (DISABLE_ARGO)  console.log(`✗ Argo 隧道已禁用`);
  console.log(`运行环境: ${detectOS()}-${detectArch()}`);
  console.log('========================================');
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
