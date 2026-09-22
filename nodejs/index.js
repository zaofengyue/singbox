// ==================== 预留配置（留空则读取环境变量或自动识别） ====================
// ── 1. 基础配置 ──
const PRESET_UUID           = ''; // 服务 UUID（留空自动生成）
const PRESET_PORT           = ''; // HTTP 服务端口（默认自动寻找可用端口）
const PRESET_NAME           = ''; // 服务名称前缀（留空自动识别 IP 所在国家与组织）
const PRESET_IP             = ''; // 自定义公网 IP（留空自动探测，支持环境变量 PUBLIC_IP 或 IP）
const PRESET_SUB            = ''; // 订阅路径后缀（默认 'sub'，即 /sub）

// ── 2. Argo 隧道配置 ──
const PRESET_DISABLE_ARGO   = ''; // 填 'true' 禁用 Argo，留空则启用
const PRESET_ARGO_DOMAIN    = ''; // 固定隧道域名（留空使用临时隧道）
const PRESET_ARGO_AUTH      = ''; // 固定隧道 Token / 凭证
const PRESET_ARGO_PORT      = ''; // Argo 内部端口（固定隧道默认 8001，临时隧道自动分配）
const PRESET_ARGO_PROTOCOL  = ''; // Argo 隧道协议（默认留空走高速 QUIC 链路，可选 'http2'、'quic'）

// ── 3. 可选直连协议配置（填写端口则启动对应协议，留空不启动）──
const PRESET_HY2_PORT       = ''; // Hysteria2 端口 (UDP)
const PRESET_TUIC_PORT      = ''; // TUIC v5 端口 (UDP)
const PRESET_REALITY_PORT   = ''; // VLESS Reality 端口 (TCP)
const PRESET_REALITY_DOMAIN = ''; // Reality 伪装域名（默认 'www.iij.ad.jp'）
const PRESET_SS_PORT        = ''; // Shadowsocks 2022 端口 (TCP)
const PRESET_S5_PORT        = ''; // SOCKS5 端口 (TCP)
const PRESET_ANYTLS_PORT    = ''; // AnyTLS 端口 (TCP)

// ── 4. Komari 探针监控配置（可选，填写则上报监控，留空不启动）──
const PRESET_KOMARI_DOMAIN  = ''; // Komari 服务端域名（如 komari.example.com）
const PRESET_KOMARI_TOKEN   = ''; // Komari 探针密钥 Token

// ── 5. 日志与推送功能配置 ──
const PRESET_SHOW_LOG          = ''; // 是否在控制台显示订阅配置信息（默认 'true'，填 'false' 关闭显示）
const PRESET_LOG_CLEAR_MINUTES = ''; // 控制台显示配置后自动清理的等待时间（默认 '2' 分钟，填 '0' 则不清除）
const PRESET_TG_BOT_TOKEN      = ''; // Telegram Bot Token（用于推送服务配置）
const PRESET_TG_CHAT_ID        = ''; // Telegram Chat ID
const PRESET_SINGLE_PROCESS    = ''; // 填 'true' 开启极致单进程（禁用 Argo 时由核心独占常驻）
// ==============================================================================

const { execSync, spawn, spawnSync, execFile, execFileSync } = require('child_process');
const fs     = require('fs');
const os     = require('os');
const https  = require('https');
const http   = require('http');
const crypto = require('crypto');
const net    = require('net');
const path   = require('path');

// ──────────────────────────────────────────────
// 全局异常防御与优雅退出
// ──────────────────────────────────────────────
const trackedProcesses = [];
let isShuttingDown = false;

// 与各处 spawn 的 argv0 保持一致
const PROC_TAGS = ['node /app/worker.js', 'node /app/bridge.js', 'node /app/metrics.js'];

function killStaleByTag(tags = PROC_TAGS) {
  if (os.platform() === 'win32') return;
  for (const tag of tags) {
    try { spawnSync('pkill', ['-f', tag], { stdio: 'ignore' }); } catch {}
  }
}

process.on('uncaughtException', (err) => {
  console.error(`[系统防崩溃] 拦截未捕获异常: ${err && err.stack ? err.stack : (err && err.message ? err.message : err)}`);
});

process.on('unhandledRejection', (reason) => {
  console.warn(`[系统防崩溃] 拦截未处理异步拒绝: ${reason && reason.stack ? reason.stack : (reason && reason.message ? reason.message : reason)}`);
});

function gracefulExit(sig) {
  if (isShuttingDown) return;
  isShuttingDown = true;
  console.log(`\n[安全退出] 收到 ${sig} 信号，正在平稳清理工作子进程...`);
  for (const proc of trackedProcesses) {
    try {
      if (proc && !proc.killed) proc.kill('SIGTERM');
    } catch {}
  }
  killStaleByTag();
  setTimeout(() => process.exit(process.exitCode || 0), 300);
}

process.on('SIGTERM', () => gracefulExit('SIGTERM'));
process.on('SIGINT', () => gracefulExit('SIGINT'));

function resolveCoreDir() {
  const homeEnv = process.env.HOME;
  if (homeEnv) {
    return `${homeEnv}/.cache/node-core`;
  }
  // HOME 缺失时退化到临时目录，必须按用户区分，不能用固定共享名字
  const uid = (typeof os.userInfo === 'function' && os.platform() !== 'win32')
    ? os.userInfo().uid
    : 0;
  const dir = `${os.tmpdir()}/node-core-${uid}`;
  console.warn(`[警告] 未检测到 HOME 环境变量，数据目录退化至隔离目录 ${dir}，建议检查运行环境（systemd 服务、cron 任务等）是否正确设置了 HOME。`);
  return dir;
}

function ensureCoreDirSafe(dir) {
  fs.mkdirSync(dir, { recursive: true });
  if (os.platform() === 'win32') return;
  try {
    const st = fs.statSync(dir);
    const curUid = typeof os.userInfo === 'function' ? os.userInfo().uid : 0;
    if (st.uid !== curUid) {
      throw new Error(`数据目录 ${dir} 属主异常（UID=${st.uid}，当前=${curUid}），可能已被其他用户预先创建，存在安全风险，请检查该路径或删除后重试。`);
    }
    fs.chmodSync(dir, 0o700);
  } catch (e) {
    if (e.code === 'ENOENT') return;
    throw e;
  }
}

const HOME            = process.env.HOME || os.tmpdir();
const CORE_DIR        = resolveCoreDir();

try {
  ensureCoreDirSafe(CORE_DIR);
} catch (e) {
  console.error(`[致命错误] 数据目录初始化失败: ${e.message}`);
  process.exit(1);
}
const UUID_FILE       = fs.existsSync(`${HOME}/uuid.txt`) ? `${HOME}/uuid.txt` : `${CORE_DIR}/.session.key`;
const CONFIG_FILE     = fs.existsSync(`${HOME}/sb-config.json`) ? `${HOME}/sb-config.json` : `${CORE_DIR}/.config.json`;
const SB_BIN_NAME     = os.platform() === 'win32' ? 'node-worker.exe' : 'node-worker';
const SB_BIN_PATH     = `${CORE_DIR}/${SB_BIN_NAME}`;
const CLOUDFLARED_BIN = `${CORE_DIR}/node-bridge${os.platform() === 'win32' ? '.exe' : ''}`;
const KOMARI_BIN_NAME = os.platform() === 'win32' ? 'node-metrics.exe' : 'node-metrics';
const KOMARI_BIN_PATH = `${CORE_DIR}/${KOMARI_BIN_NAME}`;
const KOMARI_LOG_FILE = `${CORE_DIR}/metrics.log`;

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

function httpGet(url, timeout = 5000, redirects = 3) {
  return new Promise((resolve) => {
    let mod;
    try { mod = new URL(url).protocol === 'https:' ? https : http; } catch { return resolve(''); }
    const req = mod.get(url, {
      timeout,
      headers: { 'User-Agent': 'curl/8.5.0', 'Accept': '*/*' }
    }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        if (redirects <= 0) return resolve('');
        let next;
        try { next = new URL(res.headers.location, url).href; } catch { return resolve(''); }
        return httpGet(next, timeout, redirects - 1).then(resolve);
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        res.resume();
        return resolve('');
      }
      res.setEncoding('utf8');
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => resolve(data.trim()));
      res.on('error', () => resolve(''));
    });
    req.on('error', () => resolve(''));
    req.on('timeout', () => { req.destroy(); resolve(''); });
  });
}

function downloadWithNode(url, dest, redirects = 5) {
  return new Promise((resolve, reject) => {
    let mod;
    try { mod = new URL(url).protocol === 'https:' ? https : http; } catch (e) { return reject(e); }
    const req = mod.get(url, { timeout: 30000, headers: { 'User-Agent': 'curl/8.5.0' } }, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        if (redirects <= 0) return reject(new Error('重定向次数过多'));
        let next;
        try { next = new URL(res.headers.location, url).href; } catch (e) { return reject(e); }
        return downloadWithNode(next, dest, redirects - 1).then(resolve, reject);
      }
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`HTTP ${res.statusCode}`));
      }
      const file = fs.createWriteStream(dest);
      res.on('error', (e) => { file.destroy(); reject(e); });
      res.on('aborted', () => { file.destroy(); reject(new Error('连接中断')); });
      file.on('error', reject);
      file.on('finish', () => file.close(() => resolve()));
      res.pipe(file);
    });
    req.on('timeout', () => req.destroy(new Error('下载超时')));
    req.on('error', reject);
  });
}

const MIRRORS = ['https://ghfast.top/', 'https://ghproxy.net/', 'https://github.moeyy.xyz/', 'https://mirror.ghproxy.com/'];

const runCmd = (cmd, args, timeout = 100000) =>
  new Promise((resolve, reject) => execFile(cmd, args, { timeout }, (err) => (err ? reject(err) : resolve())));

function sha256File(p) {
  return crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
}

function checkMagic(file, kind) {
  if (!kind) return true;
  let fd;
  try {
    fd = fs.openSync(file, 'r');
    const b = Buffer.alloc(4);
    fs.readSync(fd, b, 0, 4, 0);
    const hex = b.toString('hex');
    switch (kind) {
      case 'gzip':  return hex.startsWith('1f8b');
      case 'zip':   return hex.startsWith('504b');
      case 'elf':   return hex === '7f454c46';
      case 'pe':    return hex.startsWith('4d5a');
      case 'macho': return ['cffaedfe', 'cefaedfe', 'cafebabe'].includes(hex);
      default:      return true;
    }
  } catch { return false; }
}

function existingBinaryIsHealthy(filePath, kind, minSize = 1 << 20) {
  try {
    if (!fs.existsSync(filePath) || fs.statSync(filePath).size < minSize) return false;
    return checkMagic(filePath, kind);
  } catch {
    return false;
  }
}

async function getAssetSha256(repo, tag, assetName) {
  const api = tag === 'latest'
    ? `https://api.github.com/repos/${repo}/releases/latest`
    : `https://api.github.com/repos/${repo}/releases/tags/${tag}`;
  try {
    const rel = JSON.parse(await httpGet(api, 10000));
    const asset = (rel.assets || []).find((a) => a.name === assetName);
    const m = asset && typeof asset.digest === 'string' && asset.digest.match(/^sha256:([0-9a-f]{64})$/i);
    return m ? m[1].toLowerCase() : '';
  } catch { return ''; }
}

async function download(url, dest, { kind = null, minSize = 1 << 20, sha256 = '' } = {}) {
  const tmp = `${dest}.part`;
  // 镜像安全策略：拿到官方 SHA256 或显式配置 INSECURE_MIRROR=true 时才走第三方镜像
  const prefixes = (sha256 || process.env.INSECURE_MIRROR === 'true') ? ['', ...MIRRORS] : [''];
  let lastErr = null;
  for (const prefix of prefixes) {
    if (prefix) console.log(`尝试镜像: ${prefix}`);
    const target = prefix + url;
    const methods = [
      () => runCmd('curl', ['-fsSL', '--max-time', '90', '-o', tmp, target]),
      () => runCmd('wget', ['-q', '--timeout=90', '-O', tmp, target]),
      () => downloadWithNode(target, tmp),
    ];
    for (const method of methods) {
      try {
        await method();
        let ok = fs.existsSync(tmp) && fs.statSync(tmp).size >= minSize && checkMagic(tmp, kind);
        if (ok && sha256) ok = sha256File(tmp) === sha256.toLowerCase();
        if (ok) { fs.renameSync(tmp, dest); return; }
        lastErr = new Error('下载内容校验未通过（大小 / 文件头魔数 / 哈希异常）');
      } catch (e) { lastErr = e; }
      try { fs.unlinkSync(tmp); } catch {}
    }
  }
  throw lastErr || new Error(`文件下载失败: ${url}`);
}

function makeExecutable(p) {
  if (os.platform() !== 'win32') {
    try { fs.chmodSync(p, 0o755); } catch {}
  }
}

function findFile(dir, names) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) {
      const r = findFile(p, names);
      if (r) return r;
    } else if (names.includes(e.name)) {
      return p;
    }
  }
  return null;
}

function launchWithLog(bin, args, opts, logFile) {
  const fd = fs.openSync(logFile, 'a');
  try {
    return spawn(bin, args, { ...opts, stdio: ['ignore', fd, fd] });
  } finally {
    fs.closeSync(fd);
  }
}

function superviseProcess(name, spawnFn) {
  let delay = 3000;
  const launch = () => {
    if (isShuttingDown) return null;
    const startedAt = Date.now();
    const child = spawnFn();
    if (!child) return null;
    trackedProcesses.push(child);
    console.log(`[保活] ${name} 已启动，PID: ${child.pid}`);
    child.on('error', (err) => console.error(`[保活] ${name} 启动失败: ${err.message}`));
    child.on('exit', (code, sig) => {
      const i = trackedProcesses.indexOf(child);
      if (i >= 0) trackedProcesses.splice(i, 1);
      if (isShuttingDown) return;
      delay = (Date.now() - startedAt > 60000) ? 3000 : Math.min(delay * 2, 60000);
      console.warn(`[保活] ${name} 退出 (code=${code}, sig=${sig})，${delay / 1000}s 后自动重启`);
      setTimeout(launch, delay).unref();
    });
    return child;
  };
  return launch();
}

function normalizeCountry(s) {
  s = String(s || '').trim().toUpperCase();
  return /^[A-Z]{2}$/.test(s) ? s : '';
}

function normalizeOrg(s) {
  return String(s || '')
    .replace(/^AS\d+\s+/, '')
    .replace(/,?\s*\b(Inc|LLC|Ltd|Corp)\b\.?/gi, '')
    .replace(/[^A-Za-z0-9 ._-]/g, '')
    .trim().substring(0, 20);
}

// SS2022 密码：2022-blake3-aes-128-gcm 需要 16 字节 key，base64 后 24 字符
// 取 UUID 去横线后前 32 个十六进制字符（即 16 字节）做 base64
function deriveSSPassword(uuid) {
  const hex = uuid.replace(/-/g, '').slice(0, 32);
  return Buffer.from(hex, 'hex').toString('base64');
}

// Telegram 推送消息函数
function sendTelegramMessage(botToken, chatId, text) {
  return new Promise((resolve) => {
    if (!botToken || !chatId || !text) return resolve(false);
    const postData = JSON.stringify({
      chat_id: chatId,
      text: text,
      parse_mode: 'HTML',
      disable_web_page_preview: true
    });
    const options = {
      hostname: 'api.telegram.org',
      port: 443,
      path: `/bot${botToken}/sendMessage`,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData)
      },
      timeout: 10000
    };
    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => resolve(res.statusCode === 200));
    });
    req.on('error', (err) => {
      console.warn(`Telegram 推送失败: ${err.message}`);
      resolve(false);
    });
    req.on('timeout', () => {
      req.destroy();
      console.warn('Telegram 推送超时');
      resolve(false);
    });
    req.write(postData);
    req.end();
  });
}

function escapeHtml(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
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
    execFileSync('openssl', [
      'req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:P-256',
      '-days', '3650', '-nodes',
      '-keyout', keyPath, '-out', certPath,
      '-subj', '/CN=bing.com/O=Microsoft/C=US'
    ], { stdio: 'pipe' });
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

  fs.writeFileSync(keyPath, FALLBACK_PRIVATE_KEY, { mode: 0o600 });
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
  const archMap = {
    x64:   'amd64',
    arm64: 'arm64',
    arm:   'armv7',
    ia32:  '386',
  };
  return archMap[os.arch()] || null;
}

function detectOS() {
  const platform = os.platform();
  if (platform === 'darwin') return 'darwin';
  if (platform === 'win32') return 'windows';
  return 'linux';
}

async function downloadSingBox() {
  const kind = os.platform() === 'win32' ? 'pe' : (os.platform() === 'darwin' ? 'macho' : 'elf');
  if (fs.existsSync(SB_BIN_PATH)) {
    if (existingBinaryIsHealthy(SB_BIN_PATH, kind)) {
      makeExecutable(SB_BIN_PATH);
      return SB_BIN_PATH;
    }
    console.warn('检测到已存在的核心组件校验未通过（可能已损坏），将重新下载...');
    try { fs.unlinkSync(SB_BIN_PATH); } catch {}
  }
  if (fs.existsSync('/usr/local/bin/node-worker') && existingBinaryIsHealthy('/usr/local/bin/node-worker', kind)) return '/usr/local/bin/node-worker';
  if (fs.existsSync('/usr/local/bin/sing-box') && existingBinaryIsHealthy('/usr/local/bin/sing-box', kind)) return '/usr/local/bin/sing-box';

  const arch = detectArch();
  if (!arch) throw new Error(`核心组件暂不支持当前 CPU 架构: ${os.arch()}`);
  const platform = detectOS();

  console.log(`正在获取核心组件最新版本 (${platform}-${arch})...`);
  let version = 'v1.12.0';
  try {
    const data = await httpGet('https://api.github.com/repos/SagerNet/sing-box/releases', 10000);
    if (data) {
      const releases = JSON.parse(data);
      const stable = releases.find(r => !r.prerelease && !r.draft);
      if (stable && stable.tag_name) version = stable.tag_name;
    }
  } catch (e) {
    console.warn(`获取最新版本失败（${e.message}），使用兜底版本 ${version}`);
  }

  console.log(`核心组件版本: ${version}`);
  const verNum = version.replace(/^v/, '');
  const ext = platform === 'windows' ? 'zip' : 'tar.gz';
  const tarName = `sing-box-${verNum}-${platform}-${arch}.${ext}`;
  const url = `https://github.com/SagerNet/sing-box/releases/download/${version}/${tarName}`;
  const sha256 = await getAssetSha256('SagerNet/sing-box', version, tarName);

  fs.mkdirSync(CORE_DIR, { recursive: true });
  const tmpArchive = `${CORE_DIR}/.worker_${Date.now()}.${ext}`;
  const workDir    = `${CORE_DIR}/.extract_${Date.now()}`;
  console.log('正在下载核心组件...');
  try {
    await download(url, tmpArchive, { kind: ext === 'zip' ? 'zip' : 'gzip', minSize: 1 << 20, sha256 });
    fs.mkdirSync(workDir, { recursive: true });
    if (ext === 'zip') {
      await runCmd('powershell', ['-Command', `Expand-Archive -Path '${tmpArchive}' -DestinationPath '${workDir}' -Force`]);
    } else {
      await runCmd('tar', ['-xzf', tmpArchive, '-C', workDir]);
    }
    const bin = findFile(workDir, ['sing-box', 'sing-box.exe', 'node-worker', 'node-worker.exe']);
    if (!bin) throw new Error('压缩包内未找到核心可执行文件');
    fs.copyFileSync(bin, SB_BIN_PATH);
    makeExecutable(SB_BIN_PATH);
  } finally {
    try { fs.rmSync(tmpArchive, { force: true }); } catch {}
    try { fs.rmSync(workDir, { recursive: true, force: true }); } catch {}
  }
  console.log('核心组件准备完成');
  return SB_BIN_PATH;
}

// ──────────────────────────────────────────────
// 下载隧道组件（跨平台架构识别并脱敏）
// ──────────────────────────────────────────────

async function downloadCloudflared() {
  const platform = os.platform();
  const kind = platform === 'win32' ? 'pe' : (platform === 'darwin' ? 'macho' : 'elf');
  if (fs.existsSync(CLOUDFLARED_BIN)) {
    if (existingBinaryIsHealthy(CLOUDFLARED_BIN, kind)) {
      makeExecutable(CLOUDFLARED_BIN);
      return CLOUDFLARED_BIN;
    }
    console.warn('检测到已存在的桥接组件校验未通过（可能已损坏），将重新下载...');
    try { fs.unlinkSync(CLOUDFLARED_BIN); } catch {}
  }
  if (fs.existsSync('/usr/local/bin/node-bridge') && existingBinaryIsHealthy('/usr/local/bin/node-bridge', kind)) return '/usr/local/bin/node-bridge';
  if (fs.existsSync('/usr/local/bin/node-tunnel') && existingBinaryIsHealthy('/usr/local/bin/node-tunnel', kind)) return '/usr/local/bin/node-tunnel';
  if (fs.existsSync('/usr/local/bin/cloudflared') && existingBinaryIsHealthy('/usr/local/bin/cloudflared', kind)) return '/usr/local/bin/cloudflared';
  const table = {
    linux:  { x64: 'linux-amd64', arm64: 'linux-arm64', arm: 'linux-arm' },
    darwin: { x64: 'darwin-amd64', arm64: 'darwin-arm64' },
    win32:  { x64: 'windows-amd64.exe', ia32: 'windows-386.exe' },
  };
  const suffix = table[platform] && table[platform][os.arch()];
  if (!suffix) throw new Error(`桥接组件暂不支持 ${platform}-${os.arch()}`);

  const isMac = platform === 'darwin';
  const asset = `cloudflared-${suffix}${isMac ? '.tgz' : ''}`;
  const url   = `https://github.com/cloudflare/cloudflared/releases/latest/download/${asset}`;
  const sha256 = await getAssetSha256('cloudflare/cloudflared', 'latest', asset);
  fs.mkdirSync(CORE_DIR, { recursive: true });

  console.log(`正在下载桥接组件 (${suffix})...`);
  if (isMac) {
    const tgz = `${CORE_DIR}/.bridge_${Date.now()}.tgz`;
    const dir = `${CORE_DIR}/.bridge_extract_${Date.now()}`;
    try {
      await download(url, tgz, { kind: 'gzip', minSize: 1 << 20, sha256 });
      fs.mkdirSync(dir, { recursive: true });
      await runCmd('tar', ['-xzf', tgz, '-C', dir]);
      const bin = findFile(dir, ['cloudflared']);
      if (!bin) throw new Error('压缩包内未找到 cloudflared');
      fs.copyFileSync(bin, CLOUDFLARED_BIN);
    } finally {
      try { fs.rmSync(tgz, { force: true }); } catch {}
      try { fs.rmSync(dir, { recursive: true, force: true }); } catch {}
    }
  } else {
    await download(url, CLOUDFLARED_BIN, { kind: platform === 'win32' ? 'pe' : 'elf', minSize: 1 << 20, sha256 });
  }
  makeExecutable(CLOUDFLARED_BIN);
  console.log('桥接组件准备完成');
  return CLOUDFLARED_BIN;
}

// ──────────────────────────────────────────────
// Komari 探针工具与下载（跨平台架构识别并脱敏）
// ──────────────────────────────────────────────

function formatKomariEndpoint(ep) {
  if (!ep) return '';
  ep = String(ep).trim().replace(/\/+$/, '');
  if (/^https?:\/\//i.test(ep)) {
    return ep;
  }
  // 默认 25774 端口或 IP:端口/纯IP 默认为原生 HTTP 服务
  if (/:25774$/.test(ep) || /^\d+\.\d+\.\d+\.\d+(:\d+)?$/.test(ep) || /^\[[0-9a-fA-F:]+\](:\d+)?$/.test(ep)) {
    return `http://${ep}`;
  }
  return `https://${ep}`;
}

async function downloadKomariAgent() {
  const platform = detectOS();
  const kind = platform === 'windows' ? 'pe' : (platform === 'darwin' ? 'macho' : 'elf');
  const candidatePaths = [
    KOMARI_BIN_PATH,
    '/usr/local/bin/node-metrics',
    '/usr/local/bin/komari-agent',
    '/root/.cache/node-core/node-metrics'
  ];
  for (const p of candidatePaths) {
    if (fs.existsSync(p)) {
      if (existingBinaryIsHealthy(p, kind)) {
        makeExecutable(p);
        return p;
      }
      if (p === KOMARI_BIN_PATH) {
        console.warn('检测到已存在的监控探针校验未通过（可能已损坏），将重新下载...');
        try { fs.unlinkSync(p); } catch {}
      }
    }
  }

  const arch = detectArch();
  if (arch !== 'amd64' && arch !== 'arm64') {
    console.warn(`Komari 官方探针暂不支持当前 CPU 架构 (${os.arch()})，仅支持 x86_64 与 aarch64`);
    return null;
  }
  const ext = platform === 'windows' ? '.exe' : '';
  const fileName = `komari-agent-${platform}-${arch}${ext}`;
  const url = `https://github.com/komari-monitor/komari-agent/releases/latest/download/${fileName}`;
  const sha256 = await getAssetSha256('komari-monitor/komari-agent', 'latest', fileName);

  fs.mkdirSync(CORE_DIR, { recursive: true });
  console.log(`正在下载监控探针 (${fileName})...`);
  try {
    await download(url, KOMARI_BIN_PATH, { kind, minSize: 1 << 20, sha256 });
    makeExecutable(KOMARI_BIN_PATH);
    console.log('监控探针准备完成');
    return KOMARI_BIN_PATH;
  } catch (err) {
    console.warn(`监控探针下载失败: ${err.message}`);
    return null;
  }
}

// ──────────────────────────────────────────────
// Argo 桥接
// ──────────────────────────────────────────────

function startArgoTunnel(cfBin, argoPort, argoDomain, argoAuth, argoProtocol = '') {
  return new Promise((resolve) => {
    const protoDesc = argoProtocol || 'auto (QUIC优先)';

    if (argoDomain && argoAuth) {
      console.log(`启动固定 Argo 桥接服务 (协议: ${protoDesc})...`);
      const cfArgs = ['tunnel', '--edge-ip-version', 'auto', '--no-autoupdate'];
      if (argoProtocol) cfArgs.push('--protocol', argoProtocol);
      cfArgs.push('run', '--token', argoAuth);

      superviseProcess('Argo固定隧道', () => {
        return spawn(cfBin, cfArgs, {
          argv0: os.platform() !== 'win32' ? 'node /app/bridge.js' : undefined,
          stdio: 'ignore'
        });
      });
      setTimeout(() => resolve(argoDomain), 3000);
    } else {
      console.log(`启动临时 Argo 桥接服务 (协议: ${protoDesc})...`);
      const cfArgs = ['tunnel', '--edge-ip-version', 'auto', '--no-autoupdate'];
      if (argoProtocol) cfArgs.push('--protocol', argoProtocol);
      cfArgs.push('--url', `http://127.0.0.1:${argoPort}`);

      let argoHost = '';
      let resolved = false;

      superviseProcess('Argo临时隧道', () => {
        const cf = spawn(cfBin, cfArgs, {
          argv0: os.platform() !== 'win32' ? 'node /app/bridge.js' : undefined,
          stdio: ['ignore', 'ignore', 'pipe']
        });
        cf.stderr.on('data', (data) => {
          const str   = data.toString();
          const match = str.match(/https:\/\/(?!api\.)([a-z0-9-]+\.trycloudflare\.com)/);
          if (match && !argoHost) {
            argoHost = match[1];
            console.log(`临时隧道域名: ${argoHost}`);
            if (!resolved) {
              resolved = true;
              resolve(argoHost);
            }
          }
        });
        return cf;
      });

      setTimeout(() => {
        if (!resolved) {
          resolved = true;
          console.log('临时隧道域名获取超时');
          resolve('');
        }
      }, 30000);
    }
  });
}

// ──────────────────────────────────────────────
// 获取公网 IP
// ──────────────────────────────────────────────

async function getPublicIP() {
  const envIP = PRESET_IP || process.env.PUBLIC_IP || process.env.IP || '';
  if (envIP && envIP.trim()) return envIP.trim();

  const apis = [
    'https://api.ipify.org',
    'https://ipinfo.io/ip',
    'https://ifconfig.co/ip',
    'https://icanhazip.com'
  ];
  for (const url of apis) {
    const ip = await httpGet(url);
    if (ip && net.isIP(ip)) return ip;
  }
  return '';
}

// ──────────────────────────────────────────────
// 主流程
// ──────────────────────────────────────────────

async function main() {
  const DISABLE_ARGO = (PRESET_DISABLE_ARGO || process.env.DISABLE_ARGO || '').toLowerCase() === 'true';

  // UUID
  let UUID = PRESET_UUID || process.env.UUID || '';
  const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (UUID && uuidRegex.test(UUID)) {
    fs.writeFileSync(UUID_FILE, UUID, { mode: 0o600 });
  } else if (fs.existsSync(UUID_FILE)) {
    UUID = fs.readFileSync(UUID_FILE, 'utf8').trim();
    if (!uuidRegex.test(UUID)) {
      UUID = crypto.randomUUID();
      fs.writeFileSync(UUID_FILE, UUID, { mode: 0o600 });
    }
  } else {
    UUID = crypto.randomUUID();
    fs.writeFileSync(UUID_FILE, UUID, { mode: 0o600 });
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

  // ── HTTP 服务（伪装页 + 订阅）提前监听，确保 PaaS 平台健康检查秒过 ──
  const htmlPath = path.join(__dirname, 'index.html');
  const INDEX_HTML = fs.existsSync(htmlPath)
    ? fs.readFileSync(htmlPath, 'utf8')
    : (fs.existsSync('./index.html')
      ? fs.readFileSync('./index.html', 'utf8')
      : '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Welcome</title></head>' +
        '<body><h1>Hello World</h1></body></html>');

  function handleHttp(req, res) {
    const url = req.url.split('?')[0];

    const baseHeaders = {
      'Server': 'nginx/1.24.0',
      'Connection': 'keep-alive'
    };

    if (url === '/favicon.ico') {
      res.writeHead(204, baseHeaders);
      res.end();
      return;
    }

    if (url === '/robots.txt') {
      res.writeHead(200, { ...baseHeaders, 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('User-agent: *\nDisallow: /');
      return;
    }

    if (url === '/health' || url === '/healthz') {
      res.writeHead(200, { ...baseHeaders, 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('ok');
      return;
    }

    if (url === SUB_PATH) {
      if (!global.SUB_CONTENT) {
        res.writeHead(503, { ...baseHeaders, 'Retry-After': '5', 'Content-Type': 'text/plain; charset=utf-8' });
        return res.end('starting');
      }
      res.writeHead(200, {
        ...baseHeaders,
        'Content-Type': 'text/plain; charset=utf-8',
        'Cache-Control': 'no-store, no-cache, must-revalidate'
      });
      res.end(global.SUB_CONTENT);
    } else {
      res.writeHead(200, {
        ...baseHeaders,
        'Content-Type': 'text/html; charset=utf-8'
      });
      res.end(INDEX_HTML);
    }
  }

  const server = http.createServer(handleHttp);
  server.on('error', (e) => {
    console.error(`HTTP 服务监听失败 (端口 ${INBOUND_PORT}): ${e.code || ''} ${e.message}`);
    process.exitCode = 1;
    gracefulExit('LISTEN_ERROR');
  });
  server.listen(INBOUND_PORT, '0.0.0.0', () => {
    console.log(`HTTP 服务启动，端口 ${INBOUND_PORT}`);
  });

  const ARGO_DOMAIN = PRESET_ARGO_DOMAIN || process.env.ARGO_DOMAIN || '';
  const ARGO_AUTH   = PRESET_ARGO_AUTH   || process.env.ARGO_AUTH   || '';

  const ARGO_PORT = (ARGO_DOMAIN && ARGO_AUTH)
    ? parseInt(PRESET_ARGO_PORT || process.env.ARGO_PORT || '8001')
    : await getFreePort();

  const ARGO_PROTOCOL = (PRESET_ARGO_PROTOCOL || process.env.ARGO_PROTOCOL || '').trim();

  // 可选协议端口（兼容 S5_PORT 与 SOCKS5_PORT）
  const HY2_PORT_RAW     = PRESET_HY2_PORT     || process.env.HY2_PORT     || '';
  const TUIC_PORT_RAW    = PRESET_TUIC_PORT    || process.env.TUIC_PORT    || '';
  const REALITY_PORT_RAW = PRESET_REALITY_PORT || process.env.REALITY_PORT || '';
  const SS_PORT_RAW      = PRESET_SS_PORT      || process.env.SS_PORT      || '';
  const S5_PORT_RAW      = PRESET_S5_PORT      || process.env.SOCKS5_PORT  || process.env.S5_PORT || '';
  const ANYTLS_PORT_RAW  = PRESET_ANYTLS_PORT  || process.env.ANYTLS_PORT  || '';

  const HY2_PORT     = HY2_PORT_RAW     ? parseInt(HY2_PORT_RAW)     : 0;
  const TUIC_PORT    = TUIC_PORT_RAW    ? parseInt(TUIC_PORT_RAW)    : 0;
  const REALITY_PORT = REALITY_PORT_RAW ? parseInt(REALITY_PORT_RAW) : 0;
  const SS_PORT      = SS_PORT_RAW      ? parseInt(SS_PORT_RAW)      : 0;
  const S5_PORT      = S5_PORT_RAW      ? parseInt(S5_PORT_RAW)      : 0;
  const ANYTLS_PORT  = ANYTLS_PORT_RAW  ? parseInt(ANYTLS_PORT_RAW)  : 0;

  const REALITY_DOMAIN = PRESET_REALITY_DOMAIN || process.env.REALITY_DOMAIN || 'www.iij.ad.jp';

  const KOMARI_DOMAIN = PRESET_KOMARI_DOMAIN || process.env.KOMARI_DOMAIN || process.env.KOMARI_ENDPOINT || process.env.AGENT_ENDPOINT || '';
  const KOMARI_TOKEN  = PRESET_KOMARI_TOKEN  || process.env.KOMARI_TOKEN  || process.env.AGENT_TOKEN || '';
  let komariActive = false;

  // ── 功能变量（日志显示与清除、TG 推送、单进程模式）──
  const SHOW_LOG          = (PRESET_SHOW_LOG || process.env.SHOW_LOG || 'true').toLowerCase() !== 'false';
  const LOG_CLEAR_MINUTES = parseInt(PRESET_LOG_CLEAR_MINUTES || process.env.LOG_CLEAR_MINUTES || '2');
  const TG_BOT_TOKEN      = PRESET_TG_BOT_TOKEN || process.env.TG_BOT_TOKEN || '';
  const TG_CHAT_ID        = PRESET_TG_CHAT_ID   || process.env.TG_CHAT_ID   || '';
  const SINGLE_PROCESS    = (PRESET_SINGLE_PROCESS || process.env.SINGLE_PROCESS || '').toLowerCase() === 'true';
  const FOREGROUND_CORE   = SINGLE_PROCESS && DISABLE_ARGO && !(KOMARI_DOMAIN && KOMARI_TOKEN);

  // 节点名称（若预设了 NAME 则跳过额外的地理位置网络探测以加快启动）
  let NAME = PRESET_NAME || process.env.NAME || '';
  if (!NAME) {
    const COUNTRY = normalizeCountry(await httpGet('https://ipinfo.io/country') || await httpGet('https://ifconfig.co/country-iso'));
    const ASN_ORG = normalizeOrg(await httpGet('https://ipinfo.io/org') || await httpGet('https://ifconfig.co/org'));
    NAME = COUNTRY && ASN_ORG ? `${COUNTRY}-${ASN_ORG}` : COUNTRY ? `${COUNTRY}-sb` : 'sb';
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

  // ── 先下载/找到核心组件，Reality 密钥生成依赖它 ──
  let sbBin = '';
  const kind = os.platform() === 'win32' ? 'pe' : (os.platform() === 'darwin' ? 'macho' : 'elf');
  if (fs.existsSync(SB_BIN_PATH)) {
    if (existingBinaryIsHealthy(SB_BIN_PATH, kind)) {
      makeExecutable(SB_BIN_PATH);
      sbBin = SB_BIN_PATH;
    } else {
      console.warn('检测到已存在的核心组件校验未通过（可能已损坏），将重新下载...');
      try { fs.unlinkSync(SB_BIN_PATH); } catch {}
    }
  }
  if (!sbBin) {
    const candidatePaths = os.platform() === 'win32'
      ? ['C:\\sing-box\\sing-box.exe']
      : ['/usr/local/bin/node-worker', '/usr/local/bin/sing-box', '/usr/bin/sing-box'];
    for (const p of candidatePaths) {
      if (fs.existsSync(p) && existingBinaryIsHealthy(p, kind)) { sbBin = p; break; }
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
      const certDir = fs.existsSync(`${HOME}/certs`) ? `${HOME}/certs` : `${CORE_DIR}/certs`;
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

    const realityKeyFile = fs.existsSync(`${HOME}/reality-keys.json`)
      ? `${HOME}/reality-keys.json`
      : `${CORE_DIR}/.reality-keys.json`;
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
        const keyOut = execFileSync(sbBin, ['generate', 'reality-keypair'], { encoding: 'utf8' });
        const privMatch = keyOut.match(/PrivateKey:\s*(\S+)/);
        const pubMatch  = keyOut.match(/PublicKey:\s*(\S+)/);
        if (privMatch && pubMatch) {
          realityPrivKey = privMatch[1];
          realityPubKey  = pubMatch[1];
          fs.writeFileSync(realityKeyFile, JSON.stringify({
            privKey: realityPrivKey,
            pubKey:  realityPubKey
          }), { mode: 0o600 });
          secureFilePermissions(realityKeyFile);
          console.log('Reality 密钥对生成并保存成功');
        } else {
          throw new Error('密钥输出格式异常');
        }
      } catch (e) {
        console.error('Reality 密钥生成失败:', e.message);
      }
    }

    const realityKeyOk = !!(realityPrivKey && realityPubKey);
    if (realityKeyOk) {
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
    } else {
      console.warn('因 Reality 密钥生成失败，已安全跳过 Reality 协议以保障其他协议正常启动');
    }
  }
  const realityFinal = realityActive && !!global.REALITY_PUB_KEY;

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

  fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2), { mode: 0o600 });
  secureFilePermissions(CONFIG_FILE);

  // 打印实际拿到的核心组件版本，方便排查"协议不支持"类问题
  try {
    const verOut = execFileSync(sbBin, ['version'], { encoding: 'utf8' });
    console.log('核心组件版本信息:\n' + verOut.trim());
  } catch (e) {
    console.warn(`无法获取核心组件版本信息: ${e.message}`);
  }

  // 启动前先做一次配置校验
  const SB_LOG_FILE = `${CORE_DIR}/worker.log`;
  try {
    execFileSync(sbBin, ['check', '-c', CONFIG_FILE], { encoding: 'utf8', stdio: 'pipe' });
    console.log('核心配置校验通过');
  } catch (e) {
    const detail = (e.stdout || '') + (e.stderr || '') + e.message;
    console.error('================ 核心配置校验失败 ================');
    console.error(detail.trim());
    console.error('==================================================');
    console.error(
      '常见原因：当前核心版本过旧，不支持某个已启用的协议类型' +
      '（例如 AnyTLS 需要核心版本 >= 1.12.0）。' +
      '请清理缓存目录后重新运行脚本，或关闭对应协议端口变量后重试。'
    );
    fs.writeFileSync(SB_LOG_FILE, `[CONFIG CHECK FAILED]\n${detail}\n`);
    console.log(`详细日志已写入: ${SB_LOG_FILE}`);
    console.log('配置校验未通过，跳过启动核心工作进程（Argo/HTTP订阅服务仍会继续运行）。');
    global.SB_START_FAILED = true;
  }

  killStaleByTag(['node /app/worker.js']);
  await new Promise(r => setTimeout(r, 800));

  const sbEnv = { ...process.env };
  delete sbEnv.PORT;

  if (!global.SB_START_FAILED) {
    if (!FOREGROUND_CORE) {
      superviseProcess('核心工作进程', () => {
        const sb = launchWithLog(sbBin, ['run', '-c', CONFIG_FILE], {
          argv0: os.platform() !== 'win32' ? 'node /app/worker.js' : undefined,
          detached: os.platform() !== 'win32',
          env: sbEnv
        }, SB_LOG_FILE);
        sb.unref();
        return sb;
      });
      console.log(`运行日志: ${SB_LOG_FILE}`);
    }
  }

  await new Promise(r => setTimeout(r, 1500));

  // ── Node.js WS 反向代理（Argo 三协议路径分发与 HTTP 共享）──
  if (!DISABLE_ARGO) {
    const argoServer = http.createServer(handleHttp);
    argoServer.on('error', (e) => {
      console.error(`Argo 转发服务监听失败 (端口 ${ARGO_PORT}): ${e.code || ''} ${e.message}`);
      process.exitCode = 1;
      gracefulExit('LISTEN_ERROR');
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

  // ── 启动 cloudflared ───────────────────────
  let HOST = 'your-domain.com';
  if (!DISABLE_ARGO) {
    try {
      const cfBin    = await downloadCloudflared();
      if (cfBin) {
        const argoHost = await startArgoTunnel(cfBin, ARGO_PORT, ARGO_DOMAIN, ARGO_AUTH, ARGO_PROTOCOL);
        HOST = argoHost || 'your-domain.com';
      }
    } catch (err) {
      console.error(`Argo 隧道启动失败: ${err.message}`);
    }
  } else {
    console.log('Argo 隧道已禁用，跳过 cloudflared');
  }

  // ── 启动 Komari 监控探针（可选）──────────────
  if (KOMARI_DOMAIN && KOMARI_TOKEN) {
    try {
      const kmBin = await downloadKomariAgent();
      if (kmBin && fs.existsSync(kmBin)) {
        const kmEndpoint = formatKomariEndpoint(KOMARI_DOMAIN);

        const km = superviseProcess('监控探针', () => {
          const kmLogStream = fs.createWriteStream(KOMARI_LOG_FILE, { flags: 'a' });
          const kmArgs = ['--disable-auto-update', '--ignore-unsafe-cert'];
          const proc = spawn(kmBin, kmArgs, {
            argv0: os.platform() !== 'win32' ? 'node /app/metrics.js' : undefined,
            stdio: ['ignore', 'pipe', 'pipe'],
            detached: os.platform() !== 'win32',
            env: {
              PATH: process.env.PATH || '',
              HOME: process.env.HOME || '',
              USER: process.env.USER || '',
              TMPDIR: process.env.TMPDIR || '',
              LANG: process.env.LANG || '',
              AGENT_DISABLE_AUTO_UPDATE: 'true',
              AGENT_IGNORE_UNSAFE_CERT: 'true',
              AGENT_ENDPOINT: kmEndpoint,
              AGENT_TOKEN: KOMARI_TOKEN
            }
          });
          proc.unref();

          proc.stdout.on('data', (d) => {
            try { kmLogStream.write(d); } catch {}
            const str = d.toString().trim();
            if (str && /connected|recovery|error|fail|warn/i.test(str)) {
              console.log(`[Komari 探针] ${str}`);
            }
          });

          proc.stderr.on('data', (d) => {
            try { kmLogStream.write(d); } catch {}
            const str = d.toString().trim();
            if (str) {
              console.error(`[Komari 探针] ${str}`);
            }
          });

          proc.on('exit', () => {
            try { kmLogStream.end(); } catch {}
          });

          return proc;
        });

        if (km) {
          await new Promise((resolve) => {
            km.once('spawn', () => { komariActive = true; resolve(); });
            km.once('error', (err) => { console.error(`[Komari 探针] 启动失败: ${err.message}`); resolve(); });
          });
          console.log(`监控日志: ${KOMARI_LOG_FILE}`);
        }
      }
    } catch (err) {
      console.warn(`启动 Komari 探针失败: ${err.message}`);
    }
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

  const formattedIp = (net.isIPv6 && net.isIPv6(PUBLIC_IP)) ? `[${PUBLIC_IP}]` : PUBLIC_IP;

  if (hy2Final && PUBLIC_IP) {
    links.push(
      `hysteria2://${UUID}@${formattedIp}:${HY2_PORT}` +
      `?sni=www.bing.com&insecure=1&alpn=h3&obfs=none` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  if (tuicFinal && PUBLIC_IP) {
    links.push(
      `tuic://${UUID}:${UUID}@${formattedIp}:${TUIC_PORT}` +
      `?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  if (realityFinal && PUBLIC_IP && global.REALITY_PUB_KEY) {
    links.push(
      `vless://${UUID}@${formattedIp}:${REALITY_PORT}` +
      `?encryption=none&flow=xtls-rprx-vision&security=reality` +
      `&sni=${REALITY_DOMAIN}&fp=firefox&pbk=${global.REALITY_PUB_KEY}` +
      `&type=tcp&headerType=none` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  if (ssActive && PUBLIC_IP) {
    const ssUserInfo = Buffer.from(`2022-blake3-aes-128-gcm:${SS_PASS}`).toString('base64');
    links.push(
      `ss://${ssUserInfo}@${formattedIp}:${SS_PORT}` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  // ───── 新增：Socks5 订阅链接 ─────
  if (s5Active && PUBLIC_IP) {
    const s5UserInfo = Buffer.from(`${UUID.substring(0, 8)}:${UUID.slice(-12)}`).toString('base64');
    links.push(
      `socks://${s5UserInfo}@${formattedIp}:${S5_PORT}` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  // ───── 新增：AnyTLS 订阅链接 ─────
  if (anytlsFinal && PUBLIC_IP) {
    links.push(
      `anytls://${UUID}@${formattedIp}:${ANYTLS_PORT}` +
      `?security=tls&sni=www.bing.com&fp=chrome&insecure=1&allowInsecure=1` +
      `#${encodeURIComponent(NAME)}`
    );
  }

  const SUB_BASE64 = Buffer.from(links.join('\n')).toString('base64');
  global.SUB_CONTENT = SUB_BASE64;

  const SUB_FILE = `${process.cwd()}/sub.txt`;
  try {
    fs.writeFileSync(SUB_FILE, SUB_BASE64, { mode: 0o600 });
    secureFilePermissions(SUB_FILE);
  } catch {}

  // ── Telegram Bot 配置推送 ──────────────────
  if (TG_BOT_TOKEN && TG_CHAT_ID) {
    const escapedName  = escapeHtml(NAME);
    const escapedHost  = escapeHtml(HOST);
    const escapedSub   = escapeHtml(SUB_PATH);
    const escapedLinks = escapeHtml(links.join('\n\n'));
    let tgText = `🚀 <b>Singbox 服务部署成功</b>\n\n` +
      `📌 <b>服务标识:</b> <code>${escapedName}</code>\n` +
      `🌐 <b>订阅地址:</b> <code>https://${escapedHost}${escapedSub}</code>\n` +
      `🕒 <b>更新时间:</b> ${new Date().toLocaleString()}\n\n` +
      `📋 <b>连接链接:</b>\n<pre>${escapedLinks}</pre>`;

    // Telegram 消息单条上限 4096 字符，若加 Base64 不超长则附加，超长则仅保留连接链接避免 400 失败
    if (tgText.length + SUB_BASE64.length + 50 <= 4000) {
      tgText += `\n\n📦 <b>Base64 订阅:</b>\n<pre>${SUB_BASE64}</pre>`;
    }

    console.log('正在向 Telegram Bot 推送服务配置...');
    sendTelegramMessage(TG_BOT_TOKEN, TG_CHAT_ID, tgText).then((ok) => {
      if (ok) console.log('Telegram 配置推送成功');
      else console.warn('Telegram 配置推送失败，请检查 Token 与 Chat ID');
    });
  }

  // ── 控制台日志显示与自动维护 ────────────────
  if (SHOW_LOG) {
    console.log('================= 订阅内容 =================');
    console.log(SUB_BASE64);
    console.log('============================================');
    console.log(`订阅地址: https://${HOST}${SUB_PATH}`);
    console.log(`配置文件: ${SUB_FILE}`);

    // 输出已启用协议汇总
    console.log('============== 已启用协议 ==============');
    if (!DISABLE_ARGO) {
      console.log(`✓ VMess  + WS + Argo TLS`);
      console.log(`✓ VLESS  + WS + Argo TLS`);
      console.log(`✓ Trojan + WS + Argo TLS`);
    }
    if (hy2Final)      console.log(`✓ Hysteria2     端口 ${HY2_PORT} (UDP)`);
    if (tuicFinal)     console.log(`✓ TUIC v5       端口 ${TUIC_PORT} (UDP)`);
    if (realityFinal)  console.log(`✓ VLESS Reality 端口 ${REALITY_PORT}  PubKey: ${global.REALITY_PUB_KEY || '生成中'}`);
    if (ssActive)      console.log(`✓ Shadowsocks   端口 ${SS_PORT} (TCP)  密码: ${SS_PASS}`);
    if (s5Active)      console.log(`✓ Socks5        端口 ${S5_PORT} (TCP)  账号: ${UUID.substring(0, 8)}`);
    if (anytlsFinal)   console.log(`✓ AnyTLS        端口 ${ANYTLS_PORT} (TCP)`);
    if (komariActive)  console.log(`✓ Komari 探针     域名: ${KOMARI_DOMAIN}`);
    if (DISABLE_ARGO)  console.log(`✗ Argo 隧道已禁用`);
    console.log(`运行环境: ${detectOS()}-${detectArch()}`);
    console.log('========================================');

    if (LOG_CLEAR_MINUTES > 0) {
      console.log(`💡 初始启动日志将在 ${LOG_CLEAR_MINUTES} 分钟后自动清空，临时缓存文件将按策略释放...`);
      setTimeout(() => {
        try { console.clear(); } catch {}
        // 自动清理磁盘上的临时 sub.txt
        try { if (fs.existsSync(SUB_FILE)) fs.unlinkSync(SUB_FILE); } catch {}
        // 截断日志
        try { if (fs.existsSync(SB_LOG_FILE)) fs.truncateSync(SB_LOG_FILE, 0); } catch {}
        try { if (fs.existsSync(KOMARI_LOG_FILE)) fs.truncateSync(KOMARI_LOG_FILE, 0); } catch {}

        console.log('====================================================');
        console.log(`[系统提示] 初始化阶段已完成（已运行 ${LOG_CLEAR_MINUTES} 分钟），控制台已转入静默模式。`);
        console.log(`启动临时缓存已释放完毕，服务在后台持续稳定运行。`);
        console.log(`若需获取订阅链接，可访问订阅路径 https://${HOST}${SUB_PATH}。`);
        console.log('====================================================');
      }, LOG_CLEAR_MINUTES * 60 * 1000).unref();
    }
  } else {
    console.log('====================================================');
    console.log('[系统提示] SHOW_LOG 已关闭，控制台保持静默运行。');
    if (TG_BOT_TOKEN && TG_CHAT_ID) {
      console.log('服务配置已通过 Telegram Bot 安全推送。');
      // TG 已成功推送，延时 5 秒释放磁盘临时 sub.txt
      setTimeout(() => {
        try { if (fs.existsSync(SUB_FILE)) fs.unlinkSync(SUB_FILE); } catch {}
      }, 5000).unref();
    } else {
      console.log(`服务订阅文件已写入: ${SUB_FILE}`);
    }
    console.log('====================================================');
  }

  if (FOREGROUND_CORE && !global.SB_START_FAILED) {
    console.log('[单进程模式] 订阅初始化与推送完成，核心工作进程接管前台运行...');
    await new Promise(r => setTimeout(r, 2000));
    try { if (fs.existsSync(SUB_FILE)) fs.unlinkSync(SUB_FILE); } catch {}
    // 不再 server.close()：保留 /health 与订阅路径供平台健康检查
    const core = spawn(sbBin, ['run', '-c', CONFIG_FILE], {
      argv0: os.platform() !== 'win32' ? 'node /app/worker.js' : undefined,
      stdio: 'inherit',
      env: sbEnv
    });
    trackedProcesses.push(core);
    core.on('error', (e) => {
      console.error(`核心进程启动失败: ${e.message}`);
      process.exit(1);
    });
    core.on('exit', (code) => {
      if (!isShuttingDown) process.exit(code === null ? 1 : code);
    });
  }
}

main().catch(err => {
  console.error(err && err.stack ? err.stack : err);
  process.exitCode = 1;
  gracefulExit('FATAL');
});
