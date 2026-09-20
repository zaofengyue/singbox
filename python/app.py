"""app.py — py-sb 单文件服务端部署程序。
支持全自动跨平台多协议部署、Argo 隧道与直连协议、Komari 探针监控、Telegram 推送与隐私自愈保护。
"""

# ==================== 预留配置（留空则读取环境变量或自动识别） ====================
# ── 1. 基础配置 ──
CONF_UUID           = ""  # 节点 UUID（留空自动生成）
CONF_PORT           = ""  # HTTP 服务端口（默认自动寻找可用端口）
CONF_NAME           = ""  # 节点名称前缀（留空自动识别 IP 所在国家与组织）
CONF_IP             = ""  # 自定义公网 IP（留空自动探测）
CONF_SUB            = ""  # 订阅路径后缀（默认 "sub"，即 /sub）

# ── 2. Argo 隧道配置 ──
CONF_DISABLE_ARGO   = ""  # 填 "true" 禁用 Argo，留空则启用
CONF_ARGO_DOMAIN    = ""  # 固定隧道域名（留空使用临时隧道）
CONF_ARGO_AUTH      = ""  # 固定隧道 Token / 凭证
CONF_ARGO_PORT      = ""  # Argo 内部端口（固定隧道默认 8001，临时隧道自动分配）
CONF_ARGO_PROTOCOL  = ""  # Argo 隧道协议（默认 "http2"，可选 "quic"、"auto"）

# ── 3. 可选直连协议配置（填写端口则启动对应协议，留空不启动）──
CONF_HY2_PORT       = ""  # Hysteria2 端口 (UDP)
CONF_TUIC_PORT      = ""  # TUIC v5 端口 (UDP)
CONF_REALITY_PORT   = ""  # VLESS Reality 端口 (TCP)
CONF_REALITY_DOMAIN = ""  # Reality 伪装域名（默认 "www.iij.ad.jp"）
CONF_SS_PORT        = ""  # Shadowsocks 2022 端口 (TCP)
CONF_S5_PORT        = ""  # SOCKS5 端口 (TCP)
CONF_ANYTLS_PORT    = ""  # AnyTLS 端口 (TCP)

# ── 4. Komari 探针监控配置（可选，填写则上报监控，留空不启动）──
CONF_KOMARI_DOMAIN  = ""  # Komari 服务端域名或地址（如 komari.example.com 或 http://IP:25774）
CONF_KOMARI_TOKEN   = ""  # Komari 探针密钥 Token

# ── 5. 日志与推送功能配置 ──
CONF_SHOW_LOG          = ""  # 是否在控制台显示节点订阅日志（默认 "true"，填 "false" 关闭显示）
CONF_LOG_CLEAR_MINUTES = ""  # 控制台显示节点后自动清除的等待时间（默认 "2" 分钟，填 "0" 则不清除）
CONF_TG_BOT_TOKEN      = ""  # Telegram Bot Token（用于推送节点信息）
CONF_TG_CHAT_ID        = ""  # Telegram Chat ID
CONF_SINGLE_PROCESS    = ""  # 填 "true" 开启极致单进程（禁用 Argo 且无探针时由核心独占常驻前台）
# ==============================================================================

import base64
import hashlib
import json
import logging
import os
import platform
import re
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(levelname)s %(message)s")
log = logging.getLogger("py-sb")

# ──────────────────────────────────────────────
# 全局进程跟踪与优雅退出管理
# ──────────────────────────────────────────────
tracked_processes = []
is_shutting_down = False
_tracked_lock = threading.Lock()

# 与各处启动的伪装 argv0 保持一致
PROC_TAGS = ["python /app/worker.py", "python /app/bridge.py", "python /app/metrics.py"]


def kill_stale_by_tag(tags: list[str] = None):
    """在 Linux/Unix 环境下通过 pkill 清理带有伪装特征的历史遗留僵尸进程。"""
    if platform.system() == "Windows":
        return
    if tags is None:
        tags = PROC_TAGS
    for tag in tags:
        try:
            subprocess.run(["pkill", "-f", tag], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


def register_process(proc: subprocess.Popen):
    with _tracked_lock:
        if proc not in tracked_processes:
            tracked_processes.append(proc)


def unregister_process(proc: subprocess.Popen):
    with _tracked_lock:
        if proc in tracked_processes:
            tracked_processes.remove(proc)


def graceful_exit(signum=None, frame=None):
    global is_shutting_down
    if is_shutting_down:
        return
    is_shutting_down = True
    sig_name = signal.Signals(signum).name if signum is not None else "SHUTDOWN"
    log.info("[安全退出] 收到 %s 信号，正在平稳清理工作子进程...", sig_name)

    with _tracked_lock:
        procs = list(tracked_processes)

    for proc in procs:
        try:
            if proc.poll() is None:
                proc.terminate()
        except Exception:
            pass

    time.sleep(0.5)

    for proc in procs:
        try:
            if proc.poll() is None:
                proc.kill()
        except Exception:
            pass

    kill_stale_by_tag()
    log.info("[安全退出] 所有关联进程已安全终止，退出程序。")
    sys.exit(0)


# 注册系统终止信号
try:
    signal.signal(signal.SIGTERM, graceful_exit)
    signal.signal(signal.SIGINT, graceful_exit)
except Exception:
    pass

# ──────────────────────────────────────────────
# 目录与关键文件路径
# ──────────────────────────────────────────────
HOME            = Path(os.environ.get("HOME") or tempfile.gettempdir())
DATA_DIR        = HOME / "py-sb"
UUID_FILE       = DATA_DIR / "uuid.txt"
CONFIG_FILE     = DATA_DIR / "sb-config.json"
SB_DIR          = DATA_DIR / "sing-box"
SB_BIN_PATH     = SB_DIR / ("sing-box.exe" if platform.system() == "Windows" else "sing-box")
CLOUDFLARED_BIN = DATA_DIR / ("cloudflared.exe" if platform.system() == "Windows" else "cloudflared")
KOMARI_BIN_PATH = DATA_DIR / ("komari-agent.exe" if platform.system() == "Windows" else "komari-agent")
KOMARI_LOG_FILE = DATA_DIR / "metrics.log"
SB_LOG_FILE     = DATA_DIR / "worker.log"
CF_LOG_FILE     = DATA_DIR / "cloudflared.log"

# Argo 三协议 WS 路径
WS_PATH_VMESS  = "/fengyue-vm"
WS_PATH_VLESS  = "/fengyue-vl"
WS_PATH_TROJAN = "/fengyue-tr"

# Argo 三协议固定内部端口
V_VMESS_PORT  = 10000
V_VLESS_PORT  = 10001
V_TROJAN_PORT = 10002

PATH_TO_PORT = {
    WS_PATH_VMESS: V_VMESS_PORT,
    WS_PATH_VLESS: V_VLESS_PORT,
    WS_PATH_TROJAN: V_TROJAN_PORT,
}

CF_PREFER_HOST = "cdns.doon.eu.org"

ARCH_MAP = {
    "x86_64": "amd64", "amd64": "amd64",
    "aarch64": "arm64", "arm64": "arm64",
    "armv7l": "armv7",
    "i386": "386", "i686": "386",
}
CF_ARCH_MAP = {"amd64": "linux-amd64", "arm64": "linux-arm64", "armv7": "linux-arm"}
KM_ARCH_MAP = {"amd64": "linux-amd64", "arm64": "linux-arm64"}

# GitHub 下载加速镜像源列表
MIRRORS = [
    "https://ghfast.top/",
    "https://ghproxy.net/",
    "https://github.moeyy.xyz/",
    "https://mirror.ghproxy.com/",
]


# ──────────────────────────────────────────────
# 安全与工具函数
# ──────────────────────────────────────────────
def secure_file_permissions(path: Path):
    """限制敏感凭据文件权限为 0o600，仅当前用户可读写。"""
    if platform.system() == "Windows":
        return
    try:
        os.chmod(str(path), 0o600)
    except OSError as e:
        log.warning("设置文件权限失败 %s: %s", path, e)


def atomic_write_secure(path: Path, content: str, mode: int = 0o600):
    """敏感凭据原子落盘：通过低级系统调用在创建文件的第 1 微秒即锁定权限。"""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if platform.system() == "Windows":
        path.write_text(content, encoding="utf-8")
        return

    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(str(path), flags, mode)
    with open(fd, "w", encoding="utf-8", closefd=True) as f:
        f.write(content)


def is_valid_uuid(val: str) -> bool:
    """严格正则校验 UUIDv4 格式合法性。"""
    if not val or not isinstance(val, str):
        return False
    pattern = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", re.IGNORECASE)
    return bool(pattern.match(val.strip()))


def get_free_port() -> int:
    """获取本地可用随机空闲端口。"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _http_get_text(url: str, timeout: int = 5, redirects: int = 3) -> str:
    """安全轻量 HTTP GET 文本内容，支持重定向处理。"""
    if redirects < 0:
        return ""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "curl/8.5.0", "Accept": "*/*"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.getcode()
            if 300 <= status < 400:
                loc = resp.headers.get("Location")
                if loc:
                    next_url = urllib.parse.urljoin(url, loc)
                    return _http_get_text(next_url, timeout=timeout, redirects=redirects - 1)
            if 200 <= status < 300:
                return resp.read().decode("utf-8", errors="ignore").strip()
    except Exception:
        pass
    return ""


def sha256_file(path: Path) -> str:
    """计算本地文件的 sha256 哈希值。"""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536):
            h.update(chunk)
    return h.hexdigest().lower()


def check_magic(file_path: Path, kind: str = None) -> bool:
    """通过读取文件头魔数校验二进制/归档格式，杜绝下载到 HTML 拦截页。"""
    if not kind:
        return True
    try:
        with open(file_path, "rb") as f:
            header = f.read(4)
        hex_header = header.hex().lower()
        if kind == "gzip":
            return hex_header.startswith("1f8b")
        if kind == "zip":
            return hex_header.startswith("504b")
        if kind == "elf":
            return hex_header == "7f454c46"
        if kind == "pe":
            return hex_header.startswith("4d5a")
        if kind == "macho":
            return hex_header in ("cffaedfe", "cefaedfe", "cafebabe")
        return True
    except Exception:
        return False


def get_asset_sha256(repo: str, tag: str, asset_name: str) -> str:
    """从 GitHub API 获取对应 Release 资产的官方 SHA256 哈希。"""
    api = (
        f"https://api.github.com/repos/{repo}/releases/latest"
        if tag == "latest"
        else f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
    )
    raw = _http_get_text(api, timeout=10)
    if not raw:
        return ""
    try:
        data = json.loads(raw)
        assets = data.get("assets", [])
        for a in assets:
            if a.get("name") == asset_name:
                digest = a.get("digest")
                if isinstance(digest, str):
                    m = re.search(r"^sha256:([0-9a-f]{64})$", digest, re.IGNORECASE)
                    if m:
                        return m.group(1).lower()
    except Exception:
        pass
    return ""


def download(url: str, dest: Path, kind: str = None, min_size: int = 1024 * 1024, sha256: str = ""):
    """下载容灾体系：镜像加速容灾回退 + SHA256 比对 + 魔数校验 + .part 临时文件保护。"""
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    part_file = dest.with_suffix(dest.suffix + ".part")

    # 镜像安全策略：拿到官方 SHA256 或显式配置 INSECURE_MIRROR=true 时才使用第三方镜像
    insecure = os.environ.get("INSECURE_MIRROR", "").lower() == "true"
    prefixes = [""] + MIRRORS if (sha256 or insecure) else [""]

    last_err = None
    for prefix in prefixes:
        target_url = prefix + url
        if prefix:
            log.info("尝试加速镜像: %s", prefix)

        methods = [
            ["curl", "-fsSL", "--max-time", "90", "-o", str(part_file), target_url],
            ["wget", "-q", "--timeout=90", "-O", str(part_file), target_url],
        ]

        # 1. 尝试外部命令 curl / wget
        downloaded = False
        for cmd in methods:
            try:
                subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                downloaded = True
                break
            except (subprocess.CalledProcessError, FileNotFoundError):
                part_file.unlink(missing_ok=True)
                continue

        # 2. 外部命令不可用时使用 Python urllib 兜底（90 秒超时）
        if not downloaded:
            try:
                req = urllib.request.Request(target_url, headers={"User-Agent": "curl/8.5.0"})
                with urllib.request.urlopen(req, timeout=90) as resp, open(part_file, "wb") as out_f:
                    if resp.getcode() != 200:
                        raise RuntimeError(f"HTTP 响应状态码异常: {resp.getcode()}")
                    while chunk := resp.read(65536):
                        out_f.write(chunk)
                downloaded = True
            except Exception as e:
                last_err = e
                part_file.unlink(missing_ok=True)
                continue

        # 3. 校验下载完整性：大小、魔数、SHA256
        if part_file.exists():
            size_ok = part_file.stat().st_size >= min_size
            magic_ok = check_magic(part_file, kind)
            hash_ok = True
            if sha256:
                hash_ok = (sha256_file(part_file) == sha256.lower())

            if size_ok and magic_ok and hash_ok:
                if dest.exists():
                    dest.unlink()
                part_file.rename(dest)
                return
            else:
                last_err = RuntimeError(
                    f"文件校验未通过 (size_ok={size_ok}, magic_ok={magic_ok}, hash_ok={hash_ok})"
                )
                part_file.unlink(missing_ok=True)

    raise last_err or RuntimeError(f"文件下载失败: {url}")


def _extract_tar_stripped(tar_path: Path, dest_dir: Path):
    """安全解压 tar 包并剥除首层目录（Tar Slip 路径穿越防御 CVE-2007-4559）。"""
    dest_resolved = dest_dir.resolve()
    with tarfile.open(tar_path) as tar:
        members = []
        for m in tar.getmembers():
            parts = m.name.split("/", 1)
            if len(parts) == 2 and parts[1]:
                m.name = parts[1]
            target = (dest_dir / m.name).resolve()
            if not target.is_relative_to(dest_resolved):
                raise RuntimeError(f"[安全拦截] 检测到非法解压路径逃逸: {m.name}")
            members.append(m)
        tar.extractall(dest_dir, members=members)


def format_ip(ip: str) -> str:
    """完善 IPv6 格式化，直连链接自动包裹方括号。"""
    if not ip:
        return ""
    ip = ip.strip()
    if ":" in ip and not ip.startswith("["):
        return f"[{ip}]"
    return ip


def format_komari_endpoint(ep: str) -> str:
    """格式化 Komari 服务端端点地址。"""
    ep = ep.strip().rstrip("/")
    if ep.startswith("http://") or ep.startswith("https://"):
        return ep
    if ep.endswith(":25774") or re.match(r"^\d+\.\d+\.\d+\.\d+(:\d+)?$", ep):
        return f"http://{ep}"
    return f"https://{ep}"


def escape_html(text: str) -> str:
    """对 Telegram 消息进行严格 HTML 实体转义。"""
    if not text:
        return ""
    return (
        str(text)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def send_telegram_message(bot_token: str, chat_id: str, text: str) -> bool:
    """向 Telegram Bot 推送节点配置信息。"""
    if not bot_token or not chat_id or not text:
        return False
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    payload = {
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
        "disable_web_page_preview": True,
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json", "User-Agent": "curl/8.5.0"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.getcode() == 200
    except Exception as e:
        log.warning("Telegram 推送失败: %s", e)
        return False


def derive_ss_password(uuid_str: str) -> str:
    """SS2022 密码派生：取 UUID 去横线后前 32 个十六进制字符做 base64。"""
    hex_str = uuid_str.replace("-", "")[:32]
    return base64.b64encode(bytes.fromhex(hex_str)).decode()


def detect_arch() -> str:
    """检测当前机器架构。"""
    return ARCH_MAP.get(platform.machine().lower(), "amd64")


# ──────────────────────────────────────────────
# 自愈守护状态机与进程脱敏
# ──────────────────────────────────────────────
def supervise_process(name: str, launch_fn):
    """多进程自愈守护状态机：异常退出时采用指数退避重试（3s -> 6s -> ... -> 60s），平稳运行重置。"""
    def _supervisor():
        delay = 3
        while not is_shutting_down:
            started_at = time.time()
            proc = None
            try:
                proc = launch_fn()
            except Exception as e:
                log.error("[保活] %s 启动异常: %s", name, e)

            if proc is None:
                if is_shutting_down:
                    break
                time.sleep(delay)
                delay = min(delay * 2, 60)
                continue

            register_process(proc)
            log.info("[保活] %s 已启动，PID: %s", name, proc.pid)

            exit_code = proc.wait()
            unregister_process(proc)

            if is_shutting_down:
                break

            uptime = time.time() - started_at
            delay = 3 if uptime > 60 else min(delay * 2, 60)
            log.warning("[保活] %s 异常退出 (code=%s)，将在 %ss 后自动拉起重启", name, exit_code, delay)
            time.sleep(delay)

    t = threading.Thread(target=_supervisor, daemon=True, name=f"Supervisor-{name}")
    t.start()
    return t


def launch_process_cloaked(bin_path: Path, args: list[str], cloaked_tag: str, log_file: Path = None, env: dict = None) -> subprocess.Popen:
    """在 Linux/Unix 下通过 argv0 对工作进程进行伪装脱敏，避免进程列表暴露真实二进制名称。"""
    is_win = (platform.system() == "Windows")
    full_args = [str(bin_path)] + args

    kwargs = {
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "env": env or os.environ.copy(),
    }

    if log_file:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        fd = open(log_file, "a", encoding="utf-8")
        kwargs["stdout"] = fd
        kwargs["stderr"] = fd

    if not is_win:
        kwargs["start_new_session"] = True
        # 在 Unix 下通过 executable 指定真实二进制，第一参数作为进程展示名
        return subprocess.Popen([cloaked_tag] + args, executable=str(bin_path), **kwargs)
    else:
        return subprocess.Popen(full_args, **kwargs)


# ──────────────────────────────────────────────
# 自签证书现场生成
# ──────────────────────────────────────────────
FALLBACK_PRIVATE_KEY = """-----BEGIN EC PARAMETERS-----
BggqhkjOPQMBBw==
-----END EC PARAMETERS-----
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIM4792SEtPqIt1ywqTd/0bYidBqpYV/++siNnfBYsdUYoAoGCCqGSM49
AwEHoUQDQgAE1kHafPj07rJG+HboH2ekAI4r+e6TL38GWASANnngZreoQDF16ARa
/TsyLyFoPkhLxSbehH/NBEjHtSZGaDhMqQ==
-----END EC PRIVATE KEY-----"""

FALLBACK_CERT = """-----BEGIN CERTIFICATE-----
MIIBejCCASGgAwIBAgIUfWeQL3556PNJLp/veCFxGNj9crkwCgYIKoZIzj0EAwIw
EzERMA8GA1UEAwwIYmluZy5jb20wHhcNMjUwOTE4MTgyMDIyWhcNMzUwOTE2MTgy
MDIyWjATMREwDwYDVQQDDAhiaW5nLmNvbTBZMBMGByqGSM49AgEGCCqGSM49AwEH
A0IABNZB2nz49O6yRvh26B9npACOK/nuky9/BlgEgDZ54Ga3qEAxdegEWv07Mi8h
aD5IS8Um3oR/zQRIx7UmRmg4TKmjUzBRMB0GA1UdDgQWBBTV1cFID7UISE7PLTBR
BfGbgkrMNzAfBgNVHSMEGDAWgBTV1cFID7UISE7PLTBRBfGbgkrMNzAPBgNVHRMB
Af8EBTADAQH/MAoGCCqGSM49BAMCA0cAMEQCIAIDAJvg0vd/ytrQVvEcSm6XTlB+
eQ6OFb9LbLYL9f+sAiAffoMbi4y/0YUSlTtz7as9S8/lciBF5VCUoVIKS+vX2g==
-----END CERTIFICATE-----"""


def generate_self_signed_cert(cert_dir: Path) -> tuple[str, str]:
    """生成独一无二的自签 ECC 证书。优先 openssl，缺失时使用内置共享证书兜底。"""
    key_path = cert_dir / "key.pem"
    cert_path = cert_dir / "cert.pem"
    if key_path.exists() and cert_path.exists():
        return str(key_path), str(cert_path)
    cert_dir.mkdir(parents=True, exist_ok=True)

    try:
        subprocess.run(
            [
                "openssl", "req", "-x509", "-newkey", "ec",
                "-pkeyopt", "ec_paramgen_curve:P-256", "-days", "3650", "-nodes",
                "-keyout", str(key_path), "-out", str(cert_path),
                "-subj", "/CN=bing.com/O=Microsoft/C=US",
            ],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        secure_file_permissions(key_path)
        return str(key_path), str(cert_path)
    except (subprocess.CalledProcessError, FileNotFoundError):
        log.info("系统未检测到 openssl，使用内置证书现场生成...")

    log.warning("[警告] 系统缺少 openssl，使用内置共享证书（私钥已公开，仅供个人测试）")
    atomic_write_secure(key_path, FALLBACK_PRIVATE_KEY)
    atomic_write_secure(cert_path, FALLBACK_CERT)
    return str(key_path), str(cert_path)


# ──────────────────────────────────────────────
# 核心组件与探针自动下载
# ──────────────────────────────────────────────
def download_singbox() -> str:
    """下载 sing-box 核心，支持加速镜像与 SHA256 校验。"""
    if SB_BIN_PATH.exists():
        if platform.system() != "Windows":
            os.chmod(str(SB_BIN_PATH), SB_BIN_PATH.stat().st_mode | stat.S_IEXEC)
        return str(SB_BIN_PATH)

    arch = detect_arch()
    log.info("正在获取 sing-box 最新版本信息 (linux-%s)...", arch)
    version = "v1.12.0"
    try:
        data = _http_get_text("https://api.github.com/repos/SagerNet/sing-box/releases")
        if data:
            releases = json.loads(data)
            stable = next((r for r in releases if not r.get("prerelease") and not r.get("draft")), None)
            if stable and stable.get("tag_name"):
                version = stable["tag_name"]
    except Exception:
        pass

    log.info("sing-box 版本: %s", version)
    ver_num = version.lstrip("v")
    tar_name = f"sing-box-{ver_num}-linux-{arch}.tar.gz"
    url = f"https://github.com/SagerNet/sing-box/releases/download/{version}/{tar_name}"
    sha256 = get_asset_sha256("SagerNet/sing-box", version, tar_name)

    SB_DIR.mkdir(parents=True, exist_ok=True)
    tar_path = HOME / "sb.tar.gz"
    log.info("正在下载 sing-box 核心组件...")
    download(url, tar_path, kind="gzip", sha256=sha256)

    _extract_tar_stripped(tar_path, SB_DIR)
    if platform.system() != "Windows":
        os.chmod(str(SB_BIN_PATH), SB_BIN_PATH.stat().st_mode | stat.S_IEXEC)
    tar_path.unlink(missing_ok=True)
    log.info("sing-box 下载解压完成")
    return str(SB_BIN_PATH)


def download_cloudflared() -> str:
    """下载 cloudflared 二进制。"""
    if CLOUDFLARED_BIN.exists():
        if platform.system() != "Windows":
            os.chmod(str(CLOUDFLARED_BIN), CLOUDFLARED_BIN.stat().st_mode | stat.S_IEXEC)
        return str(CLOUDFLARED_BIN)

    suffix = CF_ARCH_MAP.get(detect_arch(), "linux-amd64")
    log.info("正在下载 cloudflared (%s)...", suffix)
    url = f"https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-{suffix}"
    kind = "pe" if platform.system() == "Windows" else "elf"
    download(url, CLOUDFLARED_BIN, kind=kind)
    if platform.system() != "Windows":
        os.chmod(str(CLOUDFLARED_BIN), CLOUDFLARED_BIN.stat().st_mode | stat.S_IEXEC)
    log.info("cloudflared 下载完成")
    return str(CLOUDFLARED_BIN)


def download_komari_agent() -> str:
    """下载 Komari 监控探针。"""
    if KOMARI_BIN_PATH.exists():
        if platform.system() != "Windows":
            os.chmod(str(KOMARI_BIN_PATH), KOMARI_BIN_PATH.stat().st_mode | stat.S_IEXEC)
        return str(KOMARI_BIN_PATH)

    arch = detect_arch()
    km_arch = KM_ARCH_MAP.get(arch)
    if not km_arch:
        log.warning("Komari 探针官方暂不支持当前 CPU 架构 (%s)，仅支持 amd64 与 arm64", arch)
        return ""

    log.info("正在下载 Komari 监控探针 (%s)...", km_arch)
    url = f"https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-{km_arch}"
    kind = "pe" if platform.system() == "Windows" else "elf"
    try:
        download(url, KOMARI_BIN_PATH, kind=kind)
        if platform.system() != "Windows":
            os.chmod(str(KOMARI_BIN_PATH), KOMARI_BIN_PATH.stat().st_mode | stat.S_IEXEC)
        log.info("Komari 探针下载完成")
        return str(KOMARI_BIN_PATH)
    except Exception as e:
        log.warning("Komari 探针下载失败: %s", e)
        return ""


# ──────────────────────────────────────────────
# Argo 隧道管理
# ──────────────────────────────────────────────
def start_argo_tunnel(cf_bin: str, argo_port: int, argo_domain: str, argo_auth: str, argo_protocol: str = "http2") -> str:
    """启动 Cloudflare Argo 隧道（固定隧道或临时隧道）。"""
    cf_proto = argo_protocol or "http2"

    if argo_domain and argo_auth:
        log.info("启动固定 Argo 隧道 (协议: %s)...", cf_proto)
        CF_LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        log_fd = open(CF_LOG_FILE, "a", encoding="utf-8")

        args = [
            "tunnel", "--edge-ip-version", "auto",
            "--protocol", cf_proto,
            "--no-autoupdate", "run", "--token", argo_auth,
        ]

        proc = launch_process_cloaked(
            Path(cf_bin), args, "python /app/bridge.py", log_file=CF_LOG_FILE
        )
        register_process(proc)

        # 检查是否秒崩
        waited = 0.0
        check_interval = 0.5
        while waited < 3.0:
            if proc.poll() is not None:
                log_fd.close()
                log.error("================ 固定 Argo 隧道启动失败 ================")
                log.error("cloudflared 进程已退出（退出码 %s），详细日志见 %s", proc.returncode, CF_LOG_FILE)
                try:
                    tail = CF_LOG_FILE.read_text(encoding="utf-8", errors="ignore")[-2000:]
                    log.error(tail.strip())
                except OSError:
                    pass
                log.error("==========================================================")
                log.error("常见原因：ARGO_AUTH token 无效/过期，或 ARGO_DOMAIN 未在 Cloudflare 面板绑定成功")
                return ""
            time.sleep(check_interval)
            waited += check_interval

        log.info("固定 Argo 隧道进程存活，日志见 %s", CF_LOG_FILE)
        return argo_domain

    log.info("启动临时 Argo 隧道 (协议: %s)...", cf_proto)
    args = [
        "tunnel", "--edge-ip-version", "auto",
        "--protocol", cf_proto,
        "--no-autoupdate", "--url", f"http://127.0.0.1:{argo_port}",
    ]

    is_win = (platform.system() == "Windows")
    kwargs = {
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.PIPE,
        "text": True,
        "bufsize": 1,
    }
    if not is_win:
        kwargs["start_new_session"] = True
        proc = subprocess.Popen(["python /app/bridge.py"] + args, executable=str(cf_bin), **kwargs)
    else:
        proc = subprocess.Popen([str(cf_bin)] + args, **kwargs)

    register_process(proc)

    result = {"host": ""}
    done = threading.Event()
    pattern = re.compile(r"https://([a-z0-9-]+\.trycloudflare\.com)")

    def _read_stderr():
        for line in iter(proc.stderr.readline, ""):
            m = pattern.search(line)
            if m and not result["host"]:
                result["host"] = m.group(1)
                log.info("临时隧道域名: %s", result["host"])
                done.set()
        proc.stderr.close()

    threading.Thread(target=_read_stderr, daemon=True).start()
    if not done.wait(timeout=30):
        log.warning("临时隧道域名获取超时")
    return result["host"]


# ──────────────────────────────────────────────
# HTTP / WebSocket 代理管道与 TCP KeepAlive
# ──────────────────────────────────────────────
def _set_keepalive(sock: socket.socket):
    """开启 TCP KeepAlive 与超时保护，防止弱网拔线挂死。"""
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        if hasattr(socket, "TCP_KEEPIDLE"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 30)
        if hasattr(socket, "TCP_KEEPINTVL"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 10)
        if hasattr(socket, "TCP_KEEPCNT"):
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
    except Exception:
        pass


def _pipe(src: socket.socket, dst: socket.socket):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def _recv_headers(sock: socket.socket, max_size: int = 65536) -> bytes:
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
        if len(buf) > max_size:
            break
    return buf


def _parse_headers(header_part: bytes) -> dict:
    headers = {}
    for line in header_part.split(b"\r\n")[1:]:
        if b":" not in line:
            continue
        k, _, v = line.partition(b":")
        try:
            headers[k.strip().lower().decode()] = v.strip().decode()
        except UnicodeDecodeError:
            continue
    return headers


def _is_websocket_upgrade(headers: dict) -> bool:
    connection_tokens = {t.strip().lower() for t in headers.get("connection", "").split(",")}
    return "upgrade" in connection_tokens and headers.get("upgrade", "").strip().lower() == "websocket"


def _forward_raw(client_sock: socket.socket, header_part: bytes, rest: bytes, target_port: int):
    client_sock.settimeout(None)
    _set_keepalive(client_sock)
    try:
        upstream = socket.create_connection(("127.0.0.1", target_port), timeout=5)
        _set_keepalive(upstream)
    except OSError as e:
        log.debug("连接内部 sing-box 端口 %s 失败: %s", target_port, e)
        client_sock.close()
        return

    upstream.sendall(header_part + b"\r\n\r\n" + rest)
    t1 = threading.Thread(target=_pipe, args=(client_sock, upstream), daemon=True)
    t2 = threading.Thread(target=_pipe, args=(upstream, client_sock), daemon=True)
    t1.start()
    t2.start()
    t1.join()
    t2.join()
    client_sock.close()
    upstream.close()


def _send_bad_request(client_sock: socket.socket):
    body = b"Bad Request"
    resp = (
        "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain; charset=utf-8\r\n"
        f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n"
    ).encode() + body
    try:
        client_sock.sendall(resp)
    except OSError:
        pass
    client_sock.close()


def run_argo_forward_server(port: int):
    """Argo 转发服务：专供 WebSocket 升级请求转发至内部 sing-box 协议端口。"""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(128)
    log.info("Argo 转发服务启动，端口 %s", port)

    def handle(client_sock: socket.socket):
        try:
            client_sock.settimeout(10)
            buf = _recv_headers(client_sock)
            if b"\r\n\r\n" not in buf:
                client_sock.close()
                return
            header_part, _, rest = buf.partition(b"\r\n\r\n")
            request_line = header_part.split(b"\r\n", 1)[0].decode(errors="ignore")
            try:
                _, path, _ = request_line.split(" ", 2)
            except ValueError:
                client_sock.close()
                return
            path = path.split("?")[0]
            target_port = PATH_TO_PORT.get(path)
            headers = _parse_headers(header_part)
            if target_port is None or not _is_websocket_upgrade(headers):
                _send_bad_request(client_sock)
                return
            _forward_raw(client_sock, header_part, rest, target_port)
        except Exception as e:
            log.debug("argo forward error: %s", e)
            client_sock.close()

    while not is_shutting_down:
        try:
            client, _ = srv.accept()
            threading.Thread(target=handle, args=(client,), daemon=True).start()
        except OSError:
            break


def _load_index_html() -> str:
    candidates = [
        Path.cwd() / "index.html",
        Path(__file__).parent / "index.html",
        Path(__file__).parent.parent / "index.html",
    ]
    for p in candidates:
        if p.exists():
            try:
                return p.read_text(encoding="utf-8")
            except Exception:
                pass
    return (
        '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Welcome</title></head>'
        "<body><h1>Hello World</h1></body></html>"
    )


# ──────────────────────────────────────────────
# HTTP 早期监听生命周期与 503 状态码保护
# ──────────────────────────────────────────────
def run_public_server(port: int, sub_path: str, index_html: str, sub_holder: dict):
    """前置 HTTP 监听服务：主流程开始即监听，支持 /health 秒级探测及 /sub 未就绪 503 保护。"""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(128)
    log.info("HTTP 服务启动，端口 %s", port)

    def handle(client_sock: socket.socket):
        try:
            client_sock.settimeout(10)
            buf = _recv_headers(client_sock)
            if b"\r\n\r\n" not in buf:
                client_sock.close()
                return
            header_part, _, _ = buf.partition(b"\r\n\r\n")
            request_line = header_part.split(b"\r\n", 1)[0].decode(errors="ignore")
            try:
                _, path, _ = request_line.split(" ", 2)
            except ValueError:
                client_sock.close()
                return
            path = path.split("?")[0]

            base_headers = "Connection: close\r\nAccess-Control-Allow-Origin: *\r\n"

            if path == "/robots.txt":
                body = b"User-agent: *\nDisallow: /"
                resp = (
                    f"HTTP/1.1 200 OK\r\n{base_headers}Content-Type: text/plain; charset=utf-8\r\n"
                    f"Content-Length: {len(body)}\r\n\r\n"
                ).encode() + body
            elif path in ("/health", "/healthz"):
                body = b"ok"
                resp = (
                    f"HTTP/1.1 200 OK\r\n{base_headers}Content-Type: text/plain; charset=utf-8\r\n"
                    f"Content-Length: {len(body)}\r\n\r\n"
                ).encode() + body
            elif path == sub_path:
                content = sub_holder.get("content", "")
                if not content:
                    # 订阅尚未生成完毕，响应 503 Service Unavailable 并带 Retry-After: 5
                    body = b"starting"
                    resp = (
                        f"HTTP/1.1 503 Service Unavailable\r\n{base_headers}"
                        f"Retry-After: 5\r\nContent-Type: text/plain; charset=utf-8\r\n"
                        f"Content-Length: {len(body)}\r\n\r\n"
                    ).encode() + body
                else:
                    body = content.encode("utf-8")
                    resp = (
                        f"HTTP/1.1 200 OK\r\n{base_headers}"
                        f"Cache-Control: no-store, no-cache, must-revalidate\r\n"
                        f"Content-Type: text/plain; charset=utf-8\r\n"
                        f"Content-Length: {len(body)}\r\n\r\n"
                    ).encode() + body
            else:
                body = index_html.encode("utf-8")
                resp = (
                    f"HTTP/1.1 200 OK\r\n{base_headers}Content-Type: text/html; charset=utf-8\r\n"
                    f"Content-Length: {len(body)}\r\n\r\n"
                ).encode() + body

            client_sock.sendall(resp)
            client_sock.close()
        except Exception as e:
            log.debug("public server error: %s", e)
            client_sock.close()

    while not is_shutting_down:
        try:
            client, _ = srv.accept()
            threading.Thread(target=handle, args=(client,), daemon=True).start()
        except OSError:
            break


# ──────────────────────────────────────────────
# 主入口流程
# ──────────────────────────────────────────────
def main():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    kill_stale_by_tag()

    # 1. 基础端口与前置 HTTP 监听（阶段二：早期生命周期保障健康检查秒过）
    port_env = CONF_PORT or os.environ.get("PORT", "")
    inbound_port = int(port_env) if port_env else get_free_port()

    sub_raw = CONF_SUB or os.environ.get("SUB", "sub")
    sub_path = "/" + sub_raw.lstrip("/")

    index_html = _load_index_html()
    sub_holder = {"content": ""}

    # 立即前置启动公网 HTTP 监听服务
    http_thread = threading.Thread(
        target=run_public_server,
        args=(inbound_port, sub_path, index_html, sub_holder),
        daemon=True,
        name="PublicHttpServer",
    )
    http_thread.start()

    # 2. UUID 正则校验与安全自愈（阶段一）
    env_uuid = CONF_UUID or os.environ.get("UUID", "")
    node_uuid = ""
    if is_valid_uuid(env_uuid):
        node_uuid = env_uuid.strip().lower()
    elif UUID_FILE.exists():
        file_uuid = UUID_FILE.read_text(encoding="utf-8").strip()
        if is_valid_uuid(file_uuid):
            node_uuid = file_uuid.lower()

    if not node_uuid:
        node_uuid = str(uuid.uuid4()).lower()
        log.info("生成新节点 UUID: %s", node_uuid)

    atomic_write_secure(UUID_FILE, node_uuid)

    trojan_pass = node_uuid
    ss_pass = derive_ss_password(node_uuid)

    # 3. Argo 配置解析
    disable_argo = (CONF_DISABLE_ARGO or os.environ.get("DISABLE_ARGO", "")).lower() == "true"
    argo_domain = CONF_ARGO_DOMAIN or os.environ.get("ARGO_DOMAIN", "")
    argo_auth = CONF_ARGO_AUTH or os.environ.get("ARGO_AUTH", "")
    argo_protocol = CONF_ARGO_PROTOCOL or os.environ.get("ARGO_PROTOCOL", "http2")

    if argo_domain and argo_auth:
        argo_port = int(CONF_ARGO_PORT or os.environ.get("ARGO_PORT", "8001"))
    else:
        argo_port = get_free_port()

    # 4. 可选直连协议端口解析（兼容 SOCKS5_PORT 与 S5_PORT）
    hy2_port = int(CONF_HY2_PORT or os.environ.get("HY2_PORT", 0) or 0)
    tuic_port = int(CONF_TUIC_PORT or os.environ.get("TUIC_PORT", 0) or 0)
    reality_port = int(CONF_REALITY_PORT or os.environ.get("REALITY_PORT", 0) or 0)
    ss_port = int(CONF_SS_PORT or os.environ.get("SS_PORT", 0) or 0)
    s5_raw = CONF_S5_PORT or os.environ.get("SOCKS5_PORT", "") or os.environ.get("S5_PORT", "") or 0
    s5_port = int(s5_raw) if s5_raw else 0
    anytls_port = int(CONF_ANYTLS_PORT or os.environ.get("ANYTLS_PORT", 0) or 0)

    reality_domain = CONF_REALITY_DOMAIN or os.environ.get("REALITY_DOMAIN", "www.iij.ad.jp")

    # 5. Komari 探针参数与业务功能参数
    komari_domain = (
        CONF_KOMARI_DOMAIN
        or os.environ.get("KOMARI_DOMAIN", "")
        or os.environ.get("KOMARI_ENDPOINT", "")
        or os.environ.get("AGENT_ENDPOINT", "")
    )
    komari_token = (
        CONF_KOMARI_TOKEN
        or os.environ.get("KOMARI_TOKEN", "")
        or os.environ.get("AGENT_TOKEN", "")
    )
    komari_active = False

    show_log = (CONF_SHOW_LOG or os.environ.get("SHOW_LOG", "true")).lower() != "false"
    try:
        log_clear_minutes = int(CONF_LOG_CLEAR_MINUTES or os.environ.get("LOG_CLEAR_MINUTES", "2"))
    except ValueError:
        log_clear_minutes = 2

    tg_bot_token = CONF_TG_BOT_TOKEN or os.environ.get("TG_BOT_TOKEN", "")
    tg_chat_id = CONF_TG_CHAT_ID or os.environ.get("TG_CHAT_ID", "")
    single_process = (CONF_SINGLE_PROCESS or os.environ.get("SINGLE_PROCESS", "")).lower() == "true"
    foreground_core = single_process and disable_argo and not (komari_domain and komari_token)

    # 6. 节点名称与公网 IP 识别
    name = CONF_NAME or os.environ.get("NAME", "")
    if not name:
        country = _http_get_text("https://ipinfo.io/country") or _http_get_text("https://ifconfig.co/country-iso")
        asn_org = _http_get_text("https://ipinfo.io/org") or _http_get_text("https://ifconfig.co/org")
        if asn_org:
            asn_org = re.sub(r"^AS\d+\s+", "", asn_org)
            asn_org = re.sub(r",?\s*(Inc|LLC|Ltd|Corp)\b\.?", "", asn_org, flags=re.IGNORECASE)
            asn_org = re.sub(r"[^A-Za-z0-9 ._-]", "", asn_org).strip()[:20]
        name = f"{country}-{asn_org}" if country and asn_org else (f"{country}-sb" if country else "sb")

    # 公网 IP
    public_ip = CONF_IP or os.environ.get("PUBLIC_IP", "") or os.environ.get("IP", "")
    if not public_ip and (hy2_port or tuic_port or reality_port or ss_port or s5_port or anytls_port or disable_argo):
        public_ip = _http_get_text("https://ipinfo.io/ip") or _http_get_text("https://ifconfig.co/ip") or ""

    # 7. 端口唯一性与冲突检测
    used_ports = set()
    used_ports.add(f"tcp:{inbound_port}")
    used_ports.add(f"tcp:{argo_port}")
    if not disable_argo:
        used_ports.add(f"tcp:{V_VMESS_PORT}")
        used_ports.add(f"tcp:{V_VLESS_PORT}")
        used_ports.add(f"tcp:{V_TROJAN_PORT}")

    def port_ok(p: int, proto: str) -> bool:
        if not p or p < 1 or p > 65535:
            return False
        key = f"{proto}:{p}"
        if key in used_ports:
            return False
        used_ports.add(key)
        return True

    hy2_active     = port_ok(hy2_port, "udp")
    tuic_active    = port_ok(tuic_port, "udp")
    reality_active = port_ok(reality_port, "tcp")
    ss_active      = port_ok(ss_port, "tcp")
    s5_active      = port_ok(s5_port, "tcp")
    anytls_active  = port_ok(anytls_port, "tcp")

    if hy2_port     and not hy2_active:     log.warning("HY2_PORT(%s) 端口冲突或无效，Hysteria2 已跳过", hy2_port)
    if tuic_port    and not tuic_active:    log.warning("TUIC_PORT(%s) 端口冲突或无效，TUIC 已跳过", tuic_port)
    if reality_port and not reality_active: log.warning("REALITY_PORT(%s) 端口冲突或无效，Reality 已跳过", reality_port)
    if ss_port      and not ss_active:      log.warning("SS_PORT(%s) 端口冲突或无效，Shadowsocks 已跳过", ss_port)
    if s5_port      and not s5_active:      log.warning("S5_PORT(%s) 端口冲突或无效，Socks5 已跳过", s5_port)
    if anytls_port  and not anytls_active:  log.warning("ANYTLS_PORT(%s) 端口冲突或无效，AnyTLS 已跳过", anytls_port)

    # 8. 下载或定位 sing-box 核心
    sb_bin = ""
    if SB_BIN_PATH.exists():
        if platform.system() != "Windows":
            os.chmod(str(SB_BIN_PATH), SB_BIN_PATH.stat().st_mode | stat.S_IEXEC)
        sb_bin = str(SB_BIN_PATH)
    else:
        candidates = ["/usr/local/bin/sing-box", "/usr/bin/sing-box"]
        for c in candidates:
            if Path(c).exists():
                sb_bin = c
                break
    if not sb_bin:
        sb_bin = download_singbox()

    # 9. 证书现场准备（Hysteria2 / TUIC / AnyTLS 需要）
    cert_path = key_path = ""
    cert_ready = False
    if hy2_active or tuic_active or anytls_active:
        try:
            key_path, cert_path = generate_self_signed_cert(DATA_DIR / "certs")
            cert_ready = True
        except Exception as e:
            log.error("证书生成失败，Hysteria2/TUIC/AnyTLS 将被跳过: %s", e)
            cert_ready = False

    if not cert_ready:
        if hy2_active:    log.warning("因证书不可用，Hysteria2 已跳过")
        if tuic_active:   log.warning("因证书不可用，TUIC 已跳过")
        if anytls_active: log.warning("因证书不可用，AnyTLS 已跳过")

    hy2_final    = hy2_active and cert_ready
    tuic_final   = tuic_active and cert_ready
    anytls_final = anytls_active and cert_ready

    # 10. 组装 sing-box 配置文件
    inbounds = [] if disable_argo else [
        {
            "type": "vmess", "tag": "vmess-in", "listen": "127.0.0.1", "listen_port": V_VMESS_PORT,
            "users": [{"uuid": node_uuid, "alterId": 0}],
            "transport": {"type": "ws", "path": WS_PATH_VMESS},
        },
        {
            "type": "vless", "tag": "vless-in", "listen": "127.0.0.1", "listen_port": V_VLESS_PORT,
            "users": [{"uuid": node_uuid, "flow": ""}],
            "transport": {"type": "ws", "path": WS_PATH_VLESS},
        },
        {
            "type": "trojan", "tag": "trojan-in", "listen": "127.0.0.1", "listen_port": V_TROJAN_PORT,
            "users": [{"password": trojan_pass}],
            "transport": {"type": "ws", "path": WS_PATH_TROJAN},
        },
    ]

    if hy2_final:
        log.info("启用 Hysteria2，端口 %s", hy2_port)
        inbounds.append({
            "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": hy2_port,
            "users": [{"password": node_uuid}], "masquerade": "https://bing.com",
            "tls": {"enabled": True, "alpn": ["h3"], "certificate_path": cert_path, "key_path": key_path},
        })

    if tuic_final:
        log.info("启用 TUIC v5，端口 %s", tuic_port)
        inbounds.append({
            "type": "tuic", "tag": "tuic-in", "listen": "::", "listen_port": tuic_port,
            "users": [{"uuid": node_uuid, "password": node_uuid}], "congestion_control": "bbr",
            "tls": {"enabled": True, "alpn": ["h3"], "certificate_path": cert_path, "key_path": key_path},
        })

    reality_pub_key = ""
    if reality_active:
        log.info("启用 VLESS Reality，端口 %s", reality_port)
        reality_key_file = DATA_DIR / "reality-keys.json"
        reality_priv_key = ""

        if reality_key_file.exists():
            try:
                saved = json.loads(reality_key_file.read_text(encoding="utf-8"))
                if saved.get("privKey") and saved.get("pubKey"):
                    reality_priv_key = saved["privKey"]
                    reality_pub_key = saved["pubKey"]
                    log.info("已从文件读取 Reality 密钥对")
                else:
                    raise ValueError("密钥字段不完整")
            except Exception as e:
                log.warning("reality-keys.json 读取失败（%s），重新生成...", e)
                try:
                    reality_key_file.unlink()
                except OSError:
                    pass

        if not reality_priv_key or not reality_pub_key:
            try:
                key_out = subprocess.run(
                    [sb_bin, "generate", "reality-keypair"],
                    check=True, capture_output=True, text=True,
                ).stdout
                priv_m = re.search(r"PrivateKey:\s*(\S+)", key_out)
                pub_m  = re.search(r"PublicKey:\s*(\S+)", key_out)
                if priv_m and pub_m:
                    reality_priv_key = priv_m.group(1)
                    reality_pub_key  = pub_m.group(1)
                    atomic_write_secure(reality_key_file, json.dumps({
                        "privKey": reality_priv_key, "pubKey": reality_pub_key,
                    }))
                    log.info("Reality 密钥对生成并原子保存成功")
                else:
                    raise ValueError("密钥输出格式异常")
            except Exception as e:
                log.error("Reality 密钥生成失败: %s", e)

        if not reality_priv_key or not reality_pub_key:
            log.warning("因密钥不可用，VLESS Reality 已跳过")
            reality_active = False
        else:
            inbounds.append({
                "type": "vless", "tag": "reality-in", "listen": "::", "listen_port": reality_port,
                "users": [{"uuid": node_uuid, "flow": "xtls-rprx-vision"}],
                "tls": {
                    "enabled": True, "server_name": reality_domain,
                    "reality": {
                        "enabled": True,
                        "handshake": {"server": reality_domain, "server_port": 443},
                        "private_key": reality_priv_key, "short_id": [""],
                    },
                },
            })

    reality_final = reality_active and bool(reality_pub_key)

    if ss_active:
        log.info("启用 Shadowsocks 2022，端口 %s", ss_port)
        inbounds.append({
            "type": "shadowsocks", "tag": "ss-in", "listen": "::", "listen_port": ss_port,
            "network": "tcp", "method": "2022-blake3-aes-128-gcm", "password": ss_pass,
        })

    if s5_active:
        log.info("启用 Socks5，端口 %s", s5_port)
        inbounds.append({
            "type": "socks", "tag": "s5-in", "listen": "::", "listen_port": s5_port,
            "users": [{"username": node_uuid[:8], "password": node_uuid[-12:]}],
        })

    if anytls_final:
        log.info("启用 AnyTLS，端口 %s", anytls_port)
        inbounds.append({
            "type": "anytls", "tag": "anytls-in", "listen": "::", "listen_port": anytls_port,
            "users": [{"password": node_uuid}],
            "tls": {"enabled": True, "certificate_path": cert_path, "key_path": key_path},
        })

    config = {
        "log": {"level": "warn", "timestamp": False},
        "inbounds": inbounds,
        "outbounds": [{"type": "direct", "tag": "direct"}],
    }
    atomic_write_secure(CONFIG_FILE, json.dumps(config, indent=2))

    # 11. 核心版本校验与配置整体检测
    try:
        ver_out = subprocess.run([sb_bin, "version"], capture_output=True, text=True, check=True).stdout
        log.info("sing-box 版本信息:\n%s", ver_out.strip())
    except Exception as e:
        log.warning("无法获取 sing-box 版本信息: %s", e)

    sb_start_failed = False
    try:
        subprocess.run(
            [sb_bin, "check", "-c", str(CONFIG_FILE)],
            check=True, capture_output=True, text=True,
        )
        log.info("sing-box 核心配置校验通过")
    except subprocess.CalledProcessError as e:
        detail = (e.stdout or "") + (e.stderr or "")
        log.error("================ sing-box 配置校验失败 ================")
        log.error(detail.strip())
        log.error("========================================================")
        log.error("常见原因：当前 sing-box 版本过旧，不支持某个已启用的协议类型（如 AnyTLS 需要 >= 1.12.0）。")
        atomic_write_secure(SB_LOG_FILE, f"[CONFIG CHECK FAILED]\n{detail}\n")
        log.info("详细日志已写入: %s", SB_LOG_FILE)
        log.info("配置校验未通过，跳过启动核心工作进程（HTTP订阅服务仍会继续运行）。")
        sb_start_failed = True

    # 12. 启动核心工作进程（支持守护状态机与脱敏伪装）
    sb_env = os.environ.copy()
    sb_env.pop("PORT", None)

    if not sb_start_failed and not foreground_core:
        def _launch_sb():
            return launch_process_cloaked(
                Path(sb_bin), ["run", "-c", str(CONFIG_FILE)],
                "python /app/worker.py", log_file=SB_LOG_FILE, env=sb_env
            )
        supervise_process("核心工作进程", _launch_sb)

    # 13. Argo 转发服务与 Cloudflared 启动
    host = "your-domain.com"
    if not disable_argo:
        threading.Thread(target=run_argo_forward_server, args=(argo_port,), daemon=True).start()
        try:
            cf_bin = download_cloudflared()
            argo_host = start_argo_tunnel(cf_bin, argo_port, argo_domain, argo_auth, argo_protocol)
            host = argo_host or "your-domain.com"
        except Exception as err:
            log.error("Argo 隧道启动失败: %s", err)
    else:
        log.info("Argo 隧道已禁用，跳过 cloudflared")

    # 14. 启动 Komari 监控探针（可选，阶段三）
    if komari_domain and komari_token:
        try:
            km_bin = download_komari_agent()
            if km_bin and Path(km_bin).exists():
                km_endpoint = format_komari_endpoint(komari_domain)
                km_env = {
                    "PATH": os.environ.get("PATH", ""),
                    "HOME": os.environ.get("HOME", ""),
                    "USER": os.environ.get("USER", ""),
                    "TMPDIR": os.environ.get("TMPDIR", ""),
                    "LANG": os.environ.get("LANG", ""),
                    "AGENT_DISABLE_AUTO_UPDATE": "true",
                    "AGENT_IGNORE_UNSAFE_CERT": "true",
                    "AGENT_ENDPOINT": km_endpoint,
                    "AGENT_TOKEN": komari_token,
                }
                km_args = ["--disable-auto-update", "--ignore-unsafe-cert"]

                def _launch_km():
                    return launch_process_cloaked(
                        Path(km_bin), km_args,
                        "python /app/metrics.py", log_file=KOMARI_LOG_FILE, env=km_env
                    )
                supervise_process("监控探针", _launch_km)
                komari_active = True
                log.info("Komari 探针已启动，监控日志: %s", KOMARI_LOG_FILE)
        except Exception as e:
            log.warning("启动 Komari 探针失败: %s", e)

    # 15. 生成订阅链接与格式化（阶段二 IPv6 适配）
    links = []
    formatted_ip = format_ip(public_ip)

    if not disable_argo:
        vmess_obj = {
            "v": "2", "ps": name, "add": CF_PREFER_HOST, "port": "443",
            "id": node_uuid, "aid": "0", "scy": "auto", "net": "ws", "type": "none",
            "host": host, "path": WS_PATH_VMESS, "tls": "tls", "sni": host,
        }
        links.append("vmess://" + base64.b64encode(json.dumps(vmess_obj).encode()).decode())

        links.append(
            f"vless://{node_uuid}@{CF_PREFER_HOST}:443"
            f"?encryption=none&security=tls&sni={host}&type=ws&host={host}"
            f"&path={urllib.parse.quote(WS_PATH_VLESS)}#{urllib.parse.quote(name)}"
        )

        links.append(
            f"trojan://{trojan_pass}@{CF_PREFER_HOST}:443"
            f"?security=tls&sni={host}&type=ws&host={host}"
            f"&path={urllib.parse.quote(WS_PATH_TROJAN)}#{urllib.parse.quote(name)}"
        )

    if hy2_final and public_ip:
        links.append(
            f"hysteria2://{node_uuid}@{formatted_ip}:{hy2_port}"
            f"?sni=www.bing.com&insecure=1&alpn=h3&obfs=none#{urllib.parse.quote(name)}"
        )

    if tuic_final and public_ip:
        links.append(
            f"tuic://{node_uuid}:{node_uuid}@{formatted_ip}:{tuic_port}"
            f"?sni=www.bing.com&congestion_control=bbr&udp_relay_mode=native&alpn=h3&allow_insecure=1"
            f"#{urllib.parse.quote(name)}"
        )

    if reality_final and public_ip and reality_pub_key:
        links.append(
            f"vless://{node_uuid}@{formatted_ip}:{reality_port}"
            f"?encryption=none&flow=xtls-rprx-vision&security=reality"
            f"&sni={reality_domain}&fp=firefox&pbk={reality_pub_key}"
            f"&type=tcp&headerType=none#{urllib.parse.quote(name)}"
        )

    if ss_active and public_ip:
        ss_user_info = base64.b64encode(f"2022-blake3-aes-128-gcm:{ss_pass}".encode()).decode()
        links.append(f"ss://{ss_user_info}@{formatted_ip}:{ss_port}#{urllib.parse.quote(name)}")

    if s5_active and public_ip:
        s5_user_info = base64.b64encode(f"{node_uuid[:8]}:{node_uuid[-12:]}".encode()).decode()
        links.append(f"socks://{s5_user_info}@{formatted_ip}:{s5_port}#{urllib.parse.quote(name)}")

    if anytls_final and public_ip:
        links.append(
            f"anytls://{node_uuid}@{formatted_ip}:{anytls_port}"
            f"?security=tls&sni=www.bing.com&fp=chrome&insecure=1&allowInsecure=1#{urllib.parse.quote(name)}"
        )

    sub_b64 = base64.b64encode("\n".join(links).encode()).decode()
    sub_holder["content"] = sub_b64

    sub_file = Path.cwd() / "sub.txt"
    try:
        atomic_write_secure(sub_file, sub_b64)
    except Exception:
        pass

    # 计算订阅展示地址
    if disable_argo and public_ip:
        sub_display_url = f"http://{formatted_ip}:{inbound_port}{sub_path}"
    else:
        sub_display_url = f"https://{host}{sub_path}"

    # 16. Telegram Bot 节点推送（阶段三）
    if tg_bot_token and tg_chat_id:
        escaped_name  = escape_html(name)
        escaped_sub   = escape_html(sub_display_url)
        escaped_links = escape_html("\n\n".join(links))
        current_time  = time.strftime("%Y-%m-%d %H:%M:%S")

        tg_text = (
            f"🚀 <b>Singbox 节点部署成功</b>\n\n"
            f"📌 <b>节点名称:</b> <code>{escaped_name}</code>\n"
            f"🌐 <b>订阅地址:</b> <code>{escaped_sub}</code>\n"
            f"🕒 <b>更新时间:</b> {current_time}\n\n"
            f"📋 <b>节点链接:</b>\n<pre>{escaped_links}</pre>"
        )

        # Telegram 单条上限 4096 字符，若加 Base64 不超长则附加
        if len(tg_text) + len(sub_b64) + 50 <= 4000:
            tg_text += f"\n\n📦 <b>Base64 订阅:</b>\n<pre>{sub_b64}</pre>"

        log.info("正在向 Telegram Bot 推送节点配置...")
        if send_telegram_message(tg_bot_token, tg_chat_id, tg_text):
            log.info("Telegram 节点推送成功")
        else:
            log.warning("Telegram 节点推送失败，请检查 Token 与 Chat ID")

    # 17. 控制台输出与日志隐私保护（阶段三）
    if show_log:
        print("================= 订阅内容 =================")
        print(sub_b64)
        print("============================================")
        print(f"订阅地址: {sub_display_url}")
        print(f"节点文件: {sub_file}")

        print("============== 已启用协议 ==============")
        if not disable_argo:
            print("✓ VMess  + WS + Argo TLS")
            print("✓ VLESS  + WS + Argo TLS")
            print("✓ Trojan + WS + Argo TLS")
        if hy2_final:
            print(f"✓ Hysteria2     端口 {hy2_port} (UDP)")
        if tuic_final:
            print(f"✓ TUIC v5       端口 {tuic_port} (UDP)")
        if reality_final:
            print(f"✓ VLESS Reality 端口 {reality_port}  PubKey: {reality_pub_key or '生成中'}")
        if ss_active:
            print(f"✓ Shadowsocks   端口 {ss_port} (TCP)  密码: {ss_pass}")
        if s5_active:
            print(f"✓ Socks5        端口 {s5_port} (TCP)  账号: {node_uuid[:8]}")
        if anytls_final:
            print(f"✓ AnyTLS        端口 {anytls_port} (TCP)")
        if komari_active:
            print(f"✓ Komari 探针   域名: {komari_domain}")
        if disable_argo:
            print("✗ Argo 隧道已禁用")
        print(f"运行环境: {platform.system()}-{detect_arch()}")
        print("========================================")

        if log_clear_minutes > 0:
            print(f"💡 节点敏感日志将在 {log_clear_minutes} 分钟后自动清除控制台显示并粉碎磁盘临时文件...")

            def _auto_clear():
                time.sleep(log_clear_minutes * 60)
                if is_shutting_down:
                    return
                # 清屏
                try:
                    os.system("cls" if platform.system() == "Windows" else "clear")
                except Exception:
                    pass
                # 粉碎磁盘上的 sub.txt
                try:
                    sub_file.unlink(missing_ok=True)
                except Exception:
                    pass
                # 截断运行日志
                for lf in (SB_LOG_FILE, KOMARI_LOG_FILE, CF_LOG_FILE):
                    try:
                        if lf.exists():
                            with open(lf, "w") as f:
                                f.truncate(0)
                    except Exception:
                        pass

                print("====================================================")
                print(f"[安全提示] 控制台节点日志已达到 {log_clear_minutes} 分钟，已自动清理完毕（隐私保护）。")
                print("磁盘临时节点文件已安全粉碎抹除，服务保持在内存中正常运行。")
                print(f"若需获取订阅链接，可访问订阅路径 {sub_display_url}。")
                print("====================================================")

            threading.Thread(target=_auto_clear, daemon=True, name="LogClearThread").start()
    else:
        print("====================================================")
        print("[隐私保护] SHOW_LOG 已关闭，控制台不输出节点及订阅敏感信息。")
        if tg_bot_token and tg_chat_id:
            print("节点信息已通过 Telegram Bot 安全推送。")
            def _shred_fast():
                time.sleep(5)
                try:
                    sub_file.unlink(missing_ok=True)
                except Exception:
                    pass
            threading.Thread(target=_shred_fast, daemon=True).start()
        else:
            print(f"节点订阅文件已安全写入: {sub_file}")
        print("====================================================")

    # 18. 单进程前台独占模式（阶段四）或主循环常驻
    if foreground_core and not sb_start_failed:
        log.info("[单进程模式] 核心工作进程接管前台常驻运行...")
        time.sleep(1.5)
        try:
            sub_file.unlink(missing_ok=True)
        except Exception:
            pass

        # 前台独占运行核心工作进程
        is_win = (platform.system() == "Windows")
        cloaked_tag = "python /app/worker.py"
        args = ["run", "-c", str(CONFIG_FILE)]
        if not is_win:
            core_proc = subprocess.Popen([cloaked_tag] + args, executable=str(sb_bin), env=sb_env)
        else:
            core_proc = subprocess.Popen([str(sb_bin)] + args, env=sb_env)

        register_process(core_proc)
        exit_code = core_proc.wait()
        unregister_process(core_proc)
        if not is_shutting_down:
            sys.exit(exit_code)
    else:
        # 主线程保持存活等待退出信号
        try:
            while not is_shutting_down:
                time.sleep(3600)
        except KeyboardInterrupt:
            graceful_exit()


if __name__ == "__main__":
    main()
