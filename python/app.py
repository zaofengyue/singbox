"""app.py — py-sb 单文件服务端部署程序。
支持全自动跨平台（Linux / Windows / macOS）多协议部署、Argo 隧道与直连协议、
Komari 探针监控、Telegram 推送、隐蔽脱敏防杀与自愈守护体系。
"""

# ==================== 预留配置（留空则读取环境变量或自动识别） ====================
# ── 1. 基础配置 ──
CONF_UUID           = ""  # 服务 UUID（留空自动生成）
CONF_PORT           = ""  # HTTP 服务端口（默认自动寻找可用端口）
CONF_NAME           = ""  # 服务名称前缀（留空自动识别 IP 所在国家与组织）
CONF_IP             = ""  # 自定义公网 IP（留空自动探测）
CONF_SUB            = ""  # 订阅路径后缀（默认 "sub"，即 /sub）

# ── 2. Argo 隧道配置 ──
CONF_DISABLE_ARGO   = ""  # 填 "true" 禁用 Argo，留空则启用
CONF_ARGO_DOMAIN    = ""  # 固定隧道域名（留空使用临时隧道）
CONF_ARGO_AUTH      = ""  # 固定隧道 Token / 凭证
CONF_ARGO_PORT      = ""  # Argo 内部端口（固定隧道默认 8001，临时隧道自动分配）
CONF_ARGO_PROTOCOL  = ""  # Argo 隧道协议（默认留空走高速 QUIC 链路，可选 "http2"、"quic"）

# ── 3. 可选直连协议配置（填写端口则启动对应协议，留空不启动）──
CONF_HY2_PORT       = ""  # Hysteria2 端口 (UDP)
CONF_TUIC_PORT      = ""  # TUIC v5 端口 (UDP)
CONF_REALITY_PORT   = ""  # VLESS Reality 端口 (TCP)
CONF_REALITY_DOMAIN = ""  # Reality 伪装域名（默认 "www.iij.ad.jp"）
CONF_SS_PORT        = ""  # Shadowsocks 2022 端口 (TCP)
CONF_S5_PORT        = ""  # SOCKS5 端口 (TCP)
CONF_ANYTLS_PORT    = ""  # AnyTLS 端口 (TCP)

# ── 4. Komari 探针监控配置（可选，填写则上报监控，留空不启动）──
CONF_KOMARI_DOMAIN  = ""  # Komari 服务端地址（如 https://komari.example.com 或 http://IP:25774）
CONF_KOMARI_TOKEN   = ""  # Komari 探针密钥 Token

# ── 5. 日志与推送功能配置 ──
CONF_SHOW_LOG          = ""  # 是否在控制台显示订阅配置信息（默认 "true"，填 "false" 关闭显示）
CONF_LOG_CLEAR_MINUTES = ""  # 控制台显示配置后自动清理的等待时间（默认 "2" 分钟，填 "0" 则不清理）
CONF_TG_BOT_TOKEN      = ""  # Telegram Bot Token（用于推送服务配置）
CONF_TG_CHAT_ID        = ""  # Telegram Chat ID
CONF_SINGLE_PROCESS    = ""  # 填 "true" 开启极致单进程（禁用 Argo 且无探针时由核心独占常驻前台）
# ==============================================================================

import base64
import hashlib
import ipaddress
import json
import logging
import os
import platform
import re
import shlex
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
import zipfile
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(levelname)s %(message)s")
log = logging.getLogger("py-sb")

# ──────────────────────────────────────────────
# 操作系统与架构探测
# ──────────────────────────────────────────────
def detect_os() -> str:
    s = platform.system().lower()
    if "windows" in s:
        return "windows"
    if "darwin" in s or "mac" in s:
        return "darwin"
    return "linux"


ARCH_MAP = {
    "x86_64": "amd64", "amd64": "amd64", "x64": "amd64",
    "aarch64": "arm64", "arm64": "arm64",
    "armv7l": "armv7", "armv7": "armv7",
    "i386": "386", "i686": "386",
}


def detect_arch() -> str:
    return ARCH_MAP.get(platform.machine().lower(), "amd64")


# ──────────────────────────────────────────────
# 全局进程管理与优雅退出系统
# ──────────────────────────────────────────────
tracked_processes = []
is_shutting_down = False
_tracked_lock = threading.Lock()

# 进程伪装标签（对标 Node 版）
PROC_TAGS = ["python /app/worker.py", "python /app/bridge.py", "python /app/metrics.py"]


def kill_stale_by_tag(tags: list = None):
    """在非 Windows 环境下清理历史遗留僵尸进程。"""
    if detect_os() == "windows":
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
    log.info("[安全退出] 所有子进程已安全终止，退出。")
    sys.exit(0)


# 注册系统终止信号与未捕获异常守卫
try:
    signal.signal(signal.SIGTERM, graceful_exit)
    signal.signal(signal.SIGINT, graceful_exit)
except Exception:
    pass


def _uncaught_exception_handler(exctype, value, tb):
    if issubclass(exctype, (KeyboardInterrupt, SystemExit)):
        sys.__excepthook__(exctype, value, tb)
        return
    log.error("[系统防崩溃] 捕获未处理顶级异常: %s", value, exc_info=(exctype, value, tb))


sys.excepthook = _uncaught_exception_handler

# ──────────────────────────────────────────────
# 目录解析与安全防护（消除 /tmp 固定路径提权风险）
# ──────────────────────────────────────────────
def _resolve_data_dir() -> Path:
    home_env = os.environ.get("HOME")
    if home_env:
        base = Path(home_env)
        # 对标 Node 版隐蔽目录
        return base / ".cache" / "py-core"

    # HOME 缺失时退化到临时目录，按 UID 区分，杜绝共享路径提权风险
    base = Path(tempfile.gettempdir())
    uid = os.getuid() if hasattr(os, "getuid") else 0
    dirname = f"py-core-{uid}"
    log.warning("未检测到 HOME 环境变量，数据目录退化至隔离目录 %s", base / dirname)
    return base / dirname


DATA_DIR = _resolve_data_dir()


def _ensure_data_dir_safe(path: Path) -> None:
    """确保数据目录安全创建：权限受限且属主正确。"""
    path.mkdir(parents=True, exist_ok=True)
    if detect_os() == "windows":
        return
    try:
        cur_uid = os.getuid()
        st = path.stat()
        if st.st_uid != cur_uid:
            raise RuntimeError(
                f"数据目录 {path} 属主异常（UID={st.st_uid}，当前={cur_uid}），可能已被恶意占位！"
            )
        os.chmod(str(path), 0o700)
    except OSError as e:
        log.warning("收紧数据目录权限失败 %s: %s", path, e)


_ensure_data_dir_safe(DATA_DIR)

# 对标 Node 版脱敏文件名
UUID_FILE       = DATA_DIR / ".session.key"
CONFIG_FILE     = DATA_DIR / ".config.json"
REALITY_KEY_FILE = DATA_DIR / ".reality-keys.json"

is_win = (detect_os() == "windows")
SB_BIN_PATH     = DATA_DIR / ("py-worker.exe" if is_win else "py-worker")
CLOUDFLARED_BIN = DATA_DIR / ("py-bridge.exe" if is_win else "py-bridge")
KOMARI_BIN_PATH = DATA_DIR / ("py-metrics.exe" if is_win else "py-metrics")
SB_LOG_FILE     = DATA_DIR / "worker.log"
CF_LOG_FILE     = DATA_DIR / "bridge.log"
KOMARI_LOG_FILE = DATA_DIR / "metrics.log"

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

# ──────────────────────────────────────────────
# 安全与工具函数
# ──────────────────────────────────────────────
def secure_file_permissions(path: Path):
    """限制敏感凭据文件权限为 0o600。"""
    if detect_os() == "windows":
        return
    try:
        os.chmod(str(path), 0o600)
    except OSError as e:
        log.warning("设置文件权限失败 %s: %s", path, e)


def atomic_write_secure(path: Path, content: str, mode: int = 0o600):
    """敏感凭据原子落盘，创建第 1 微秒即锁定权限。"""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if detect_os() == "windows":
        path.write_text(content, encoding="utf-8")
        return

    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(str(path), flags, mode)
    with open(fd, "w", encoding="utf-8", closefd=True) as f:
        f.write(content)


def is_valid_uuid(val: str) -> bool:
    """标准 UUID 格式校验（8-4-4-4-12 格式）。"""
    if not val or not isinstance(val, str):
        return False
    return bool(re.match(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", val.strip()))


def safe_int(val, default=0, min_val=1, max_val=65535) -> int:
    """安全解析端口与数值，防呆防崩溃。"""
    try:
        if val is None or str(val).strip() == "":
            return default
        n = int(str(val).strip())
        return n if min_val <= n <= max_val else default
    except (ValueError, TypeError):
        return default


def _create_server_socket() -> socket.socket:
    """创建监听套接字，Windows 使用 SO_EXCLUSIVEADDRUSE 防端口劫持，Linux 走 SO_REUSEADDR。"""
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    if detect_os() == "windows":
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            srv.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    else:
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    return srv


def get_free_port() -> int:
    """获取本地可用随机空闲端口。"""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _http_get_text(url: str, timeout: int = 5, redirects: int = 3) -> str:
    """轻量 HTTP GET 文本，带重定向与超时控制。"""
    if redirects < 0:
        return ""
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "curl/8.5.0", "Accept": "*/*"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.getcode()
            if 300 <= status < 400:
                loc = resp.headers.get("Location")
                if loc:
                    return _http_get_text(urllib.parse.urljoin(url, loc), timeout, redirects - 1)
            if 200 <= status < 300:
                return resp.read().decode("utf-8", errors="ignore").strip()
    except Exception:
        pass
    return ""


def get_valid_public_ip() -> str:
    """多源探测公网 IP，经 ipaddress 严格验证，杜绝限流 HTML 错误污染。"""
    apis = [
        "https://api.ipify.org",
        "https://ipinfo.io/ip",
        "https://ifconfig.co/ip",
        "https://icanhazip.com",
    ]
    for url in apis:
        raw = _http_get_text(url, timeout=4)
        if raw:
            candidate = raw.strip()
            try:
                ipaddress.ip_address(candidate)
                return candidate
            except ValueError:
                continue
    return ""


def check_magic(file_path: Path, kind: str = None) -> bool:
    """文件头魔数校验，防范下载到 HTML 拦截页。"""
    if not kind:
        return True
    try:
        with open(file_path, "rb") as f:
            header = f.read(4)
        hex_h = header.hex().lower()
        if kind == "gzip":
            return hex_h.startswith("1f8b")
        if kind == "zip":
            return hex_h.startswith("504b")
        if kind == "elf":
            return hex_h == "7f454c46"
        if kind == "pe":
            return hex_h.startswith("4d5a")
        if kind == "macho":
            return hex_h in ("cffaedfe", "cefaedfe", "cafebabe")
        return True
    except Exception:
        return False


def _is_safe_path(base_dir: Path, target_path: Path) -> bool:
    """向下兼容 Python 3.8 的路径安全判定，防范 CVE-2007-4559 Tar Slip 穿越。"""
    try:
        base_res = base_dir.resolve()
        target_res = target_path.resolve()
        if hasattr(target_res, "is_relative_to"):
            return target_res.is_relative_to(base_res)
        common = os.path.commonpath([str(base_res), str(target_res)])
        return common == str(base_res)
    except Exception:
        return False


def _extract_archive_stripped(archive_path: Path, dest_dir: Path, is_zip: bool = False):
    """安全解压归档并剥离顶级首层目录，过滤空目录与根项。"""
    dest_dir.mkdir(parents=True, exist_ok=True)
    if is_zip:
        with zipfile.ZipFile(archive_path, "r") as zf:
            for info in zf.infolist():
                name = info.filename
                parts = name.split("/", 1)
                if len(parts) == 2 and parts[1]:
                    sub_name = parts[1]
                    target = (dest_dir / sub_name).resolve()
                    if not _is_safe_path(dest_dir, target):
                        raise RuntimeError(f"[安全拦截] 非法 zip 解压路径逃逸: {name}")
                    if info.is_dir():
                        target.mkdir(parents=True, exist_ok=True)
                    else:
                        target.parent.mkdir(parents=True, exist_ok=True)
                        with zf.open(info) as src, open(target, "wb") as dst:
                            while chunk := src.read(65536):
                                dst.write(chunk)
    else:
        with tarfile.open(archive_path, "r:*") as tar:
            members = []
            for m in tar.getmembers():
                parts = m.name.split("/", 1)
                if len(parts) == 2 and parts[1]:
                    m.name = parts[1]
                    target = (dest_dir / m.name).resolve()
                    if not _is_safe_path(dest_dir, target):
                        raise RuntimeError(f"[安全拦截] 非法 tar 解压路径逃逸: {m.name}")
                    members.append(m)
            tar.extractall(dest_dir, members=members)


def format_ip(ip: str) -> str:
    """IPv6 格式化，自动包裹方括号。"""
    if not ip:
        return ""
    ip = ip.strip()
    if ":" in ip and not ip.startswith("["):
        return f"[{ip}]"
    return ip


def format_komari_endpoint(ep: str) -> str:
    """格式化 Komari 服务端端点，支持 IPv6 及原生 HTTP 端点识别。"""
    ep = ep.strip().rstrip("/")
    if re.match(r"^https?://", ep, re.IGNORECASE):
        return ep
    if (ep.endswith(":25774") or
        re.match(r"^\d+\.\d+\.\d+\.\d+(:\d+)?$", ep) or
        re.match(r"^\[[0-9a-fA-F:]+\](:\d+)?$", ep)):
        return f"http://{ep}"
    return f"https://{ep}"


def escape_html(text: str) -> str:
    """Telegram HTML 实体转义。"""
    if not text:
        return ""
    return str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def send_telegram_message(bot_token: str, chat_id: str, text: str) -> bool:
    """向 Telegram Bot 发送通知。"""
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
        url, data=data, headers={"Content-Type": "application/json", "User-Agent": "curl/8.5.0"}, method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.getcode() == 200
    except Exception as e:
        log.warning("Telegram 推送失败: %s", e)
        return False


def derive_ss_password(uuid_str: str) -> str:
    """SS2022 密码派生。"""
    hex_str = uuid_str.replace("-", "")[:32]
    return base64.b64encode(bytes.fromhex(hex_str)).decode()


# ──────────────────────────────────────────────
# 标准下载引擎（curl -> wget -> urllib）
# ──────────────────────────────────────────────
def download(url: str, dest: Path, kind: str = None, min_size: int = 1024 * 1024):
    """跨平台标准下载，采用 .part 临时文件保障原子性。"""
    dest = Path(dest)
    dest.parent.mkdir(parents=True, exist_ok=True)
    part_file = dest.with_suffix(dest.suffix + ".part")

    methods = [
        ["curl", "-fsSL", "--max-time", "90", "-o", str(part_file), url],
        ["wget", "-q", "--timeout=90", "-O", str(part_file), url],
    ]

    downloaded = False
    for cmd in methods:
        try:
            subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            downloaded = True
            break
        except (subprocess.CalledProcessError, FileNotFoundError):
            part_file.unlink(missing_ok=True)
            continue

    if not downloaded:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "curl/8.5.0"})
            with urllib.request.urlopen(req, timeout=90) as resp, open(part_file, "wb") as out_f:
                if resp.getcode() != 200:
                    raise RuntimeError(f"HTTP 状态码异常: {resp.getcode()}")
                while chunk := resp.read(65536):
                    out_f.write(chunk)
            downloaded = True
        except Exception as e:
            part_file.unlink(missing_ok=True)
            raise e

    if part_file.exists():
        if part_file.stat().st_size >= min_size and check_magic(part_file, kind):
            if dest.exists():
                dest.unlink()
            part_file.rename(dest)
            return
        part_file.unlink(missing_ok=True)
        raise RuntimeError("文件校验失败（尺寸或文件头魔数不符）")

    raise RuntimeError(f"文件下载失败: {url}")


# ──────────────────────────────────────────────
# 自愈守护状态机与进程启动（修复 FD 句柄泄漏）
# ──────────────────────────────────────────────
def launch_process_cloaked(bin_path: Path, args: list, cloaked_tag: str, log_file: Path = None, env: dict = None) -> subprocess.Popen:
    """启动子进程并脱敏。在 Popen 完成后立即在父进程中关闭 log_fd，消除句柄泄漏。"""
    is_w = (detect_os() == "windows")
    full_args = [str(bin_path)] + args

    kwargs = {
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "env": env or os.environ.copy(),
    }

    log_fd = None
    if log_file:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        log_fd = open(log_file, "a", encoding="utf-8")
        kwargs["stdout"] = log_fd
        kwargs["stderr"] = log_fd

    try:
        if not is_w:
            kwargs["start_new_session"] = True
        proc = subprocess.Popen(full_args, **kwargs)
        return proc
    finally:
        # 父进程立即关闭 fd（子进程已继承底层内核句柄）
        if log_fd:
            try:
                log_fd.close()
            except Exception:
                pass


def supervise_process(name: str, launch_fn, early_exit_threshold: float = 3.0, diagnostic_fn=None):
    """指数退避自愈守护状态机（3s -> 6s -> ... -> 60s），支持首次早期退出即时诊断。"""
    def _supervisor():
        delay = 3
        first_attempt = True
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

            # 首次启动就提前退出，大概率是配置错误（如 Token/密钥错误），输出详细诊断
            if first_attempt and uptime < early_exit_threshold and diagnostic_fn:
                try:
                    diagnostic_fn(exit_code)
                except Exception:
                    pass

            first_attempt = False
            delay = 3 if uptime > 60 else min(delay * 2, 60)
            log.warning("[保活] %s 异常退出 (code=%s)，将在 %ss 后自动重启", name, exit_code, delay)
            time.sleep(delay)

    t = threading.Thread(target=_supervisor, daemon=True, name=f"Supervisor-{name}")
    t.start()
    return t


# ──────────────────────────────────────────────
# 自签 ECC 证书现场生成
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


def generate_self_signed_cert(cert_dir: Path) -> tuple:
    """生成独一无二的自签 ECC 证书。"""
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

    atomic_write_secure(key_path, FALLBACK_PRIVATE_KEY)
    atomic_write_secure(cert_path, FALLBACK_CERT)
    return str(key_path), str(cert_path)


# ──────────────────────────────────────────────
# 核心组件下载（优先检测容器与系统预装路径）
# ──────────────────────────────────────────────
def download_singbox() -> str:
    """跨平台下载并解压 sing-box。"""
    if SB_BIN_PATH.exists():
        if detect_os() != "windows":
            os.chmod(str(SB_BIN_PATH), SB_BIN_PATH.stat().st_mode | stat.S_IEXEC)
        return str(SB_BIN_PATH)

    # 优先检测系统/容器预装路径
    candidates = (
        ["C:\\sing-box\\sing-box.exe"] if detect_os() == "windows"
        else ["/usr/local/bin/node-worker", "/usr/local/bin/sing-box", "/usr/bin/sing-box"]
    )
    for c in candidates:
        if Path(c).exists():
            return str(c)

    os_type = detect_os()
    arch = detect_arch()
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

    ver_num = version.lstrip("v")
    is_zip = (os_type == "windows")
    pkg_ext = "zip" if is_zip else "tar.gz"
    asset_name = f"sing-box-{ver_num}-{os_type}-{arch}.{pkg_ext}"
    url = f"https://github.com/SagerNet/sing-box/releases/download/{version}/{asset_name}"

    archive_tmp = DATA_DIR / f"sb_archive.{pkg_ext}"
    log.info("正在下载 sing-box (%s)...", asset_name)
    kind = "zip" if is_zip else "gzip"
    download(url, archive_tmp, kind=kind)

    # 安全解压并剥离首层
    _extract_archive_stripped(archive_tmp, DATA_DIR, is_zip=is_zip)

    # 在解压后的目录中寻找二进制并标准化重命名为 py-worker
    extracted_bin_name = "sing-box.exe" if is_zip else "sing-box"
    found_bin = None
    for p in DATA_DIR.rglob(extracted_bin_name):
        found_bin = p
        break

    if found_bin and found_bin != SB_BIN_PATH:
        if SB_BIN_PATH.exists():
            SB_BIN_PATH.unlink()
        found_bin.rename(SB_BIN_PATH)

    if detect_os() != "windows" and SB_BIN_PATH.exists():
        os.chmod(str(SB_BIN_PATH), SB_BIN_PATH.stat().st_mode | stat.S_IEXEC)

    archive_tmp.unlink(missing_ok=True)
    log.info("sing-box 部署完成: %s", SB_BIN_PATH)
    return str(SB_BIN_PATH)


def download_cloudflared() -> str:
    """跨平台下载 cloudflared 二进制。"""
    if CLOUDFLARED_BIN.exists():
        if detect_os() != "windows":
            os.chmod(str(CLOUDFLARED_BIN), CLOUDFLARED_BIN.stat().st_mode | stat.S_IEXEC)
        return str(CLOUDFLARED_BIN)

    candidates = (
        ["C:\\cloudflared\\cloudflared.exe"] if detect_os() == "windows"
        else ["/usr/local/bin/cloudflared", "/usr/bin/cloudflared"]
    )
    for c in candidates:
        if Path(c).exists():
            return str(c)

    os_type = detect_os()
    arch = detect_arch()
    if os_type == "windows":
        suffix = "windows-amd64.exe" if arch == "amd64" else "windows-386.exe"
        kind = "pe"
    elif os_type == "darwin":
        suffix = "darwin-amd64.tgz"
        kind = "gzip"
    else:
        cf_arch = {"amd64": "linux-amd64", "arm64": "linux-arm64", "armv7": "linux-arm"}.get(arch, "linux-amd64")
        suffix = cf_arch
        kind = "elf"

    log.info("正在下载 cloudflared (%s)...", suffix)
    url = f"https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-{suffix}"
    download(url, CLOUDFLARED_BIN, kind=kind)

    if detect_os() != "windows":
        os.chmod(str(CLOUDFLARED_BIN), CLOUDFLARED_BIN.stat().st_mode | stat.S_IEXEC)
    log.info("cloudflared 部署完成")
    return str(CLOUDFLARED_BIN)


def download_komari_agent() -> str:
    """下载 Komari 监控探针。"""
    if KOMARI_BIN_PATH.exists():
        if detect_os() != "windows":
            os.chmod(str(KOMARI_BIN_PATH), KOMARI_BIN_PATH.stat().st_mode | stat.S_IEXEC)
        return str(KOMARI_BIN_PATH)

    candidates = ["/usr/local/bin/komari-agent", "/usr/local/bin/node-metrics"]
    for c in candidates:
        if Path(c).exists():
            return str(c)

    arch = detect_arch()
    km_arch = "linux-amd64" if arch == "amd64" else ("linux-arm64" if arch == "arm64" else "")
    if not km_arch or detect_os() != "linux":
        log.warning("Komari 探针官方暂未提供当前系统架构 (%s-%s) 的预编译版本", detect_os(), arch)
        return ""

    log.info("正在下载 Komari 监控探针 (%s)...", km_arch)
    url = f"https://github.com/komari-monitor/komari-agent/releases/latest/download/komari-agent-{km_arch}"
    try:
        download(url, KOMARI_BIN_PATH, kind="elf")
        if detect_os() != "windows":
            os.chmod(str(KOMARI_BIN_PATH), KOMARI_BIN_PATH.stat().st_mode | stat.S_IEXEC)
        log.info("Komari 探针部署完成")
        return str(KOMARI_BIN_PATH)
    except Exception as e:
        log.warning("Komari 探针下载失败: %s", e)
        return ""


# ──────────────────────────────────────────────
# Argo 隧道管理与自愈保活状态机（排除 api. 误匹配）
# ──────────────────────────────────────────────
def start_argo_tunnel_service(cf_bin: str, argo_port: int, argo_domain: str, argo_auth: str, argo_protocol: str = "") -> str:
    """启动 Cloudflare Argo 隧道，未显式指定协议时走默认高速链路（QUIC优先）。"""
    proto_desc = argo_protocol or "auto (QUIC优先)"

    if argo_domain and argo_auth:
        log.info("配置固定 Argo 隧道 (协议: %s)...", proto_desc)
        args = [
            "tunnel", "--edge-ip-version", "auto",
            "--no-autoupdate", "run", "--token", argo_auth,
        ]
        if argo_protocol:
            args.extend(["--protocol", argo_protocol])

        def _argo_fixed_diagnostic(exit_code):
            log.error("================ 固定 Argo 隧道启动异常 ================")
            log.error("cloudflared 进程提前退出（退出码 %s），详细日志见 %s", exit_code, CF_LOG_FILE)
            try:
                tail = CF_LOG_FILE.read_text(encoding="utf-8", errors="ignore")[-2000:]
                log.error(tail.strip())
            except OSError:
                pass
            log.error("==========================================================")
            log.error("常见原因：ARGO_AUTH token 无效/过期，或 ARGO_DOMAIN 未在 Cloudflare 面板绑定成功")

        def _launch_fixed():
            return launch_process_cloaked(
                Path(cf_bin), args, "python /app/bridge.py", log_file=CF_LOG_FILE
            )

        # 启动自愈保活，配置秒退诊断
        supervise_process("Argo固定隧道", _launch_fixed, diagnostic_fn=_argo_fixed_diagnostic)
        log.info("固定 Argo 隧道已接入守护状态机，日志见 %s", CF_LOG_FILE)
        return argo_domain

    log.info("配置临时 Argo 隧道 (协议: %s)...", proto_desc)
    args = [
        "tunnel", "--edge-ip-version", "auto",
        "--no-autoupdate", "--url", f"http://127.0.0.1:{argo_port}",
    ]
    if argo_protocol:
        args.extend(["--protocol", argo_protocol])

    # 正则严密排除 api.trycloudflare.com
    pattern = re.compile(r"https://(?!api\.)([a-z0-9-]+\.trycloudflare\.com)", re.IGNORECASE)
    captured_host = {"host": ""}
    domain_ready = threading.Event()

    def _launch_temp():
        is_w = (detect_os() == "windows")
        kwargs = {
            "stdout": subprocess.DEVNULL,
            "stderr": subprocess.PIPE,
            "text": True,
            "bufsize": 1,
        }
        if not is_w:
            kwargs["start_new_session"] = True
        proc = subprocess.Popen([str(cf_bin)] + args, **kwargs)

        def _reader(p=proc):
            for line in iter(p.stderr.readline, ""):
                m = pattern.search(line)
                if m and not captured_host["host"]:
                    captured_host["host"] = m.group(1).lower()
                    log.info("临时隧道域名成功分配: %s", captured_host["host"])
                    domain_ready.set()
            try:
                p.stderr.close()
            except Exception:
                pass

        threading.Thread(target=_reader, daemon=True).start()
        return proc

    # 启动自愈守护
    supervise_process("Argo临时隧道", _launch_temp)

    # 等待初次域名获取
    if not domain_ready.wait(timeout=35):
        log.warning("临时隧道域名获取超时，继续保持后台自愈拉取")

    return captured_host["host"]


# ──────────────────────────────────────────────
# HTTP / WebSocket 管道双向联动关闭与并发限流
# ──────────────────────────────────────────────
_MAX_CONCURRENT_CONNECTIONS = 200


def _set_keepalive(sock: socket.socket):
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
    """双向独立传输管道，对标原版纯粹全双工转发。"""
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


def _forward_raw(client_sock: socket.socket, header_part: bytes, rest: bytes, target_port: int):
    """原版全双工数据转发核心：彻底移除单向断开即强杀全局的 done_event，并消除 upstream 5秒超时。"""
    client_sock.settimeout(None)
    try:
        client_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        _set_keepalive(client_sock)
    except Exception:
        pass
    try:
        upstream = socket.create_connection(("127.0.0.1", target_port), timeout=5)
        upstream.settimeout(None)
        upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
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

    # 保持原版 join 机制，等待两端数据完整互传完毕再释放套接字
    t1.join()
    t2.join()
    try:
        client_sock.close()
    except Exception:
        pass
    try:
        upstream.close()
    except Exception:
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


def _send_bad_request(client_sock: socket.socket):
    body = b"Bad Request"
    resp = (
        "HTTP/1.1 400 Bad Request\r\nServer: nginx/1.24.0\r\n"
        "Content-Type: text/plain; charset=utf-8\r\n"
        f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n"
    ).encode() + body
    try:
        client_sock.sendall(resp)
    except OSError:
        pass
    client_sock.close()


def run_argo_forward_server(port: int):
    """Argo WebSocket 升级转发网关，对标原版原生并发监听。"""
    srv = _create_server_socket()
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
        except OSError:
            break
        threading.Thread(target=handle, args=(client,), daemon=True).start()


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


def run_public_server(srv: socket.socket, sub_path: str, index_html: str, sub_holder: dict):
    """前置 HTTP 监听服务（Server: nginx 伪装、/health 秒回、/favicon.ico 204、503 未就绪保护）。"""
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

            base_headers = "Server: nginx/1.24.0\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n"

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
            elif path == "/favicon.ico":
                # 响应 204 No Content，杜绝返回完整 HTML 首页特征
                resp = f"HTTP/1.1 204 No Content\r\n{base_headers}\r\n".encode()
            elif path == sub_path:
                content = sub_holder.get("content", "")
                if not content:
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
        except OSError:
            break
        threading.Thread(target=handle, args=(client,), daemon=True).start()


# ──────────────────────────────────────────────
# 主入口流程
# ──────────────────────────────────────────────
def main():
    kill_stale_by_tag()

    # 1. 基础端口与主线程前置同步绑定（端口冲突主线程秒感知）
    port_env = CONF_PORT or os.environ.get("PORT", "")
    inbound_port = safe_int(port_env, default=0) or get_free_port()

    public_srv = _create_server_socket()
    try:
        public_srv.bind(("0.0.0.0", inbound_port))
        public_srv.listen(128)
        log.info("HTTP 服务前置监听启动，端口 %s", inbound_port)
    except Exception as e:
        log.error("HTTP 端口 %s 绑定失败，端口可能已被占用: %s", inbound_port, e)
        sys.exit(1)

    sub_raw = CONF_SUB or os.environ.get("SUB", "sub")
    sub_path = "/" + sub_raw.lstrip("/")

    index_html = _load_index_html()
    sub_holder = {"content": ""}

    threading.Thread(
        target=run_public_server,
        args=(public_srv, sub_path, index_html, sub_holder),
        daemon=True,
        name="PublicHttpServer",
    ).start()

    # 2. UUID 校验与自愈
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
        log.info("生成新服务 UUID: %s", node_uuid)

    atomic_write_secure(UUID_FILE, node_uuid)
    trojan_pass = node_uuid
    ss_pass = derive_ss_password(node_uuid)

    # 3. Argo 配置解析
    disable_argo = (CONF_DISABLE_ARGO or os.environ.get("DISABLE_ARGO", "")).lower() == "true"
    argo_domain = (CONF_ARGO_DOMAIN or os.environ.get("ARGO_DOMAIN", "")).strip()
    argo_auth = (CONF_ARGO_AUTH or os.environ.get("ARGO_AUTH", "")).strip()
    argo_protocol = (CONF_ARGO_PROTOCOL or os.environ.get("ARGO_PROTOCOL", "")).strip()

    if argo_domain and argo_auth:
        argo_port = safe_int(CONF_ARGO_PORT or os.environ.get("ARGO_PORT", 8001), default=8001)
    else:
        argo_port = get_free_port()

    # 4. 可选直连协议端口解析（防呆清洗）
    hy2_port = safe_int(CONF_HY2_PORT or os.environ.get("HY2_PORT", 0))
    tuic_port = safe_int(CONF_TUIC_PORT or os.environ.get("TUIC_PORT", 0))
    reality_port = safe_int(CONF_REALITY_PORT or os.environ.get("REALITY_PORT", 0))
    ss_port = safe_int(CONF_SS_PORT or os.environ.get("SS_PORT", 0))
    s5_raw = CONF_S5_PORT or os.environ.get("SOCKS5_PORT", "") or os.environ.get("S5_PORT", "")
    s5_port = safe_int(s5_raw)
    anytls_port = safe_int(CONF_ANYTLS_PORT or os.environ.get("ANYTLS_PORT", 0))

    reality_domain = (CONF_REALITY_DOMAIN or os.environ.get("REALITY_DOMAIN", "www.iij.ad.jp")).strip()

    # 5. Komari 探针与业务参数
    komari_domain = (
        CONF_KOMARI_DOMAIN
        or os.environ.get("KOMARI_DOMAIN", "")
        or os.environ.get("KOMARI_ENDPOINT", "")
        or os.environ.get("AGENT_ENDPOINT", "")
    ).strip()
    komari_token = (
        CONF_KOMARI_TOKEN
        or os.environ.get("KOMARI_TOKEN", "")
        or os.environ.get("AGENT_TOKEN", "")
    ).strip()
    komari_active = False

    show_log = (CONF_SHOW_LOG or os.environ.get("SHOW_LOG", "true")).lower() != "false"
    log_clear_minutes = safe_int(CONF_LOG_CLEAR_MINUTES or os.environ.get("LOG_CLEAR_MINUTES", 2), default=2, min_val=0, max_val=1440)

    tg_bot_token = (CONF_TG_BOT_TOKEN or os.environ.get("TG_BOT_TOKEN", "")).strip()
    tg_chat_id = (CONF_TG_CHAT_ID or os.environ.get("TG_CHAT_ID", "")).strip()
    single_process = (CONF_SINGLE_PROCESS or os.environ.get("SINGLE_PROCESS", "")).lower() == "true"
    foreground_core = single_process and disable_argo and not (komari_domain and komari_token)

    # 6. 服务名称与公网 IP 格式校验
    name = (CONF_NAME or os.environ.get("NAME", "")).strip()
    if not name:
        country = _http_get_text("https://ipinfo.io/country") or _http_get_text("https://ifconfig.co/country-iso")
        asn_org = _http_get_text("https://ipinfo.io/org") or _http_get_text("https://ifconfig.co/org")
        if asn_org:
            asn_org = re.sub(r"^AS\d+\s+", "", asn_org)
            asn_org = re.sub(r",?\s*(Inc|LLC|Ltd|Corp)\b\.?", "", asn_org, flags=re.IGNORECASE)
            asn_org = re.sub(r"[^A-Za-z0-9 ._-]", "", asn_org).strip()[:20]
        name = f"{country}-{asn_org}" if country and asn_org else (f"{country}-sb" if country else "sb")

    custom_ip = (CONF_IP or os.environ.get("PUBLIC_IP", "") or os.environ.get("IP", "")).strip()
    public_ip = ""
    if custom_ip:
        try:
            ipaddress.ip_address(custom_ip)
            public_ip = custom_ip
        except ValueError:
            log.warning("自定义公网 IP (%s) 格式非法，自动探测替代", custom_ip)

    if not public_ip and (hy2_port or tuic_port or reality_port or ss_port or s5_port or anytls_port or disable_argo):
        public_ip = get_valid_public_ip()

    # 7. 端口冲突自查
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

    if hy2_port     and not hy2_active:     log.warning("HY2_PORT(%s) 端口冲突或无效，已跳过", hy2_port)
    if tuic_port    and not tuic_active:    log.warning("TUIC_PORT(%s) 端口冲突或无效，已跳过", tuic_port)
    if reality_port and not reality_active: log.warning("REALITY_PORT(%s) 端口冲突或无效，已跳过", reality_port)
    if ss_port      and not ss_active:      log.warning("SS_PORT(%s) 端口冲突或无效，已跳过", ss_port)
    if s5_port      and not s5_active:      log.warning("S5_PORT(%s) 端口冲突或无效，已跳过", s5_port)
    if anytls_port  and not anytls_active:  log.warning("ANYTLS_PORT(%s) 端口冲突或无效，已跳过", anytls_port)

    # 8. 下载并部署核心组件
    sb_bin = download_singbox()

    # 9. 证书准备
    cert_path = key_path = ""
    cert_ready = False
    if hy2_active or tuic_active or anytls_active:
        try:
            key_path, cert_path = generate_self_signed_cert(DATA_DIR / "certs")
            cert_ready = True
        except Exception as e:
            log.error("自签证书生成失败: %s", e)

    hy2_final    = hy2_active and cert_ready
    tuic_final   = tuic_active and cert_ready
    anytls_final = anytls_active and cert_ready

    # 10. 组装配置文件
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
        reality_priv_key = ""

        if REALITY_KEY_FILE.exists():
            try:
                saved = json.loads(REALITY_KEY_FILE.read_text(encoding="utf-8"))
                if saved.get("privKey") and saved.get("pubKey"):
                    reality_priv_key = saved["privKey"]
                    reality_pub_key = saved["pubKey"]
                    log.info("已从文件读取 Reality 密钥对")
                else:
                    raise ValueError("密钥字段不完整")
            except Exception as e:
                log.warning("reality-keys.json 读取失败: %s", e)
                try:
                    REALITY_KEY_FILE.unlink()
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
                    atomic_write_secure(REALITY_KEY_FILE, json.dumps({
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

    # 11. 配置校验
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
        atomic_write_secure(SB_LOG_FILE, f"[CONFIG CHECK FAILED]\n{detail}\n")
        sb_start_failed = True

    # 12. 启动核心工作进程（自愈守护）
    sb_env = os.environ.copy()
    sb_env.pop("PORT", None)

    if not sb_start_failed and not foreground_core:
        def _launch_sb():
            return launch_process_cloaked(
                Path(sb_bin), ["run", "-c", str(CONFIG_FILE)],
                "python /app/worker.py", log_file=SB_LOG_FILE, env=sb_env
            )
        supervise_process("核心工作进程", _launch_sb)

    # 13. Argo 转发服务与 Cloudflared（全面接入保活）
    host = "your-domain.com"
    if not disable_argo:
        threading.Thread(target=run_argo_forward_server, args=(argo_port,), daemon=True).start()
        try:
            cf_bin = download_cloudflared()
            argo_host = start_argo_tunnel_service(cf_bin, argo_port, argo_domain, argo_auth, argo_protocol)
            host = argo_host or "your-domain.com"
        except Exception as err:
            log.error("Argo 隧道启动失败: %s", err)
    else:
        log.info("Argo 隧道已禁用，跳过 cloudflared")

    # 14. 启动 Komari 探针（保活与脱敏环境）
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
                supervise_process("Komari探针", _launch_km)
                komari_active = True
                log.info("Komari 探针已启动，日志: %s", KOMARI_LOG_FILE)
        except Exception as e:
            log.warning("启动 Komari 探针失败: %s", e)

    # 15. 生成订阅链接
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

    sub_display_url = (
        f"http://{formatted_ip}:{inbound_port}{sub_path}"
        if disable_argo and public_ip
        else f"https://{host}{sub_path}"
    )

    # 16. Telegram 推送（带防截断保护）
    if tg_bot_token and tg_chat_id:
        escaped_name  = escape_html(name)
        escaped_sub   = escape_html(sub_display_url)
        escaped_links = escape_html("\n\n".join(links))
        current_time  = time.strftime("%Y-%m-%d %H:%M:%S")

        # Telegram 单条上限 4096，超出安全截断
        if len(escaped_links) > 2800:
            escaped_links = escaped_links[:2800] + "\n...(配置项较多，请直接使用订阅链接)..."

        tg_text = (
            f"🚀 <b>Singbox 服务部署成功</b>\n\n"
            f"📌 <b>服务标识:</b> <code>{escaped_name}</code>\n"
            f"🌐 <b>订阅地址:</b> <code>{escaped_sub}</code>\n"
            f"🕒 <b>更新时间:</b> {current_time}\n\n"
            f"📋 <b>连接链接:</b>\n<pre>{escaped_links}</pre>"
        )

        if len(tg_text) + len(sub_b64) + 50 <= 4000:
            tg_text += f"\n\n📦 <b>Base64 订阅:</b>\n<pre>{sub_b64}</pre>"

        log.info("正在向 Telegram Bot 推送服务配置...")
        if send_telegram_message(tg_bot_token, tg_chat_id, tg_text):
            log.info("Telegram 配置推送成功")
        else:
            log.warning("Telegram 配置推送失败，请检查 Token 与 Chat ID")

    _sub_clean_scheduled = False

    def schedule_sub_file_cleanup(delay_sec: int):
        """在后台调度 sub.txt 延迟清理，支持完全脱离主进程（兼容 os.execve 原地镜像替换）。"""
        nonlocal _sub_clean_scheduled
        if _sub_clean_scheduled or not sub_file.exists():
            return
        _sub_clean_scheduled = True

        if detect_os() != "windows":
            try:
                # Linux 环境：派生完全脱离 Python 会话的后台 shell 定时清理任务，对路径进行严格安全转义
                quoted_sub = shlex.quote(str(sub_file))
                subprocess.Popen(
                    f"sleep {delay_sec} && rm -f {quoted_sub}",
                    shell=True,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    close_fds=True,
                    start_new_session=True,
                )
                return
            except Exception:
                pass
        # Windows 或降级模式：使用后台守护线程
        def _delayed_rm():
            time.sleep(delay_sec)
            try:
                sub_file.unlink(missing_ok=True)
            except Exception:
                pass
        threading.Thread(target=_delayed_rm, daemon=True, name="SubFileCleaner").start()

    if show_log:
        print("================= 订阅内容 =================")
        print(sub_b64)
        print("============================================")
        print(f"订阅地址: {sub_display_url}")
        print(f"配置文件: {sub_file}")

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
        print(f"运行环境: {detect_os()}-{detect_arch()}")
        print("========================================")

        if log_clear_minutes > 0:
            print(f"💡 初始启动日志将在 {log_clear_minutes} 分钟后自动清空，临时缓存文件将按策略释放...")
            # 独立后台调度清理，确保在单进程 os.execve 镜像替换后依然准时销毁文件
            schedule_sub_file_cleanup(log_clear_minutes * 60)

            def _auto_clear():
                time.sleep(log_clear_minutes * 60)
                if is_shutting_down:
                    return
                try:
                    os.system("cls" if detect_os() == "windows" else "clear")
                except Exception:
                    pass
                try:
                    sub_file.unlink(missing_ok=True)
                except Exception:
                    pass
                for lf in (SB_LOG_FILE, KOMARI_LOG_FILE, CF_LOG_FILE):
                    try:
                        if lf.exists():
                            with open(lf, "w") as f:
                                f.truncate(0)
                    except Exception:
                        pass

                print("====================================================")
                print(f"[系统提示] 初始化阶段已完成（已运行 {log_clear_minutes} 分钟），控制台已转入静默模式。")
                print("启动临时缓存已释放完毕，服务在后台持续稳定运行。")
                print(f"若需获取订阅链接，可访问订阅路径 {sub_display_url}。")
                print("====================================================")

            threading.Thread(target=_auto_clear, daemon=True, name="LogClearThread").start()
    else:
        print("====================================================")
        print("[系统提示] SHOW_LOG 已关闭，控制台保持静默运行。")
        if tg_bot_token and tg_chat_id:
            print("服务配置已通过 Telegram Bot 安全推送。")
            schedule_sub_file_cleanup(5)
        else:
            print(f"服务订阅文件已写入: {sub_file}")
            print("💡 系统提示：sub.txt 将在运行 2 分钟（120秒）后自动释放清理，请妥善保存！")
            schedule_sub_file_cleanup(120)
        print("====================================================")

    # 18. 单进程独占模式（翼龙面板等小内存环境极致常驻优化）或主循环常驻
    if foreground_core and not sb_start_failed:
        log.info("[单进程模式] 订阅初始化与推送完成，核心工作进程原地接管前台（释放 Python 解释器内存）...")
        time.sleep(1.5)

        # ── 痕迹安全大清扫（提升隐蔽性，消灭磁盘特征与无用文件） ──
        # 1. 订阅文件清理调度兜底
        if tg_bot_token and tg_chat_id:
            schedule_sub_file_cleanup(5)
        elif not show_log:
            schedule_sub_file_cleanup(120)
        elif log_clear_minutes > 0:
            schedule_sub_file_cleanup(log_clear_minutes * 60)

        # 2. 彻底递归清除 Python 自动生成的字节码缓存目录 __pycache__
        for pycache in [Path.cwd() / "__pycache__", Path(__file__).parent / "__pycache__"]:
            try:
                if pycache.exists():
                    import shutil
                    shutil.rmtree(pycache, ignore_errors=True)
            except Exception:
                pass

        # 3. 清除未启用的多余空日志文件，减少磁盘扫描特征
        for unused_lf in [CF_LOG_FILE, KOMARI_LOG_FILE]:
            try:
                unused_lf.unlink(missing_ok=True)
            except Exception:
                pass

        # 4. 彻底显式关闭前置 HTTP 监听，防止套接字句柄泄漏继承给 sing-box 导致端口锁死
        try:
            public_srv.close()
        except Exception:
            pass

        # 5. 刷新所有标准流输出缓冲区，确保控制台信息完整落盘
        sys.stdout.flush()
        sys.stderr.flush()

        cloaked_tag = "python /app/worker.py"
        args = [cloaked_tag, "run", "-c", str(CONFIG_FILE)]
        resolved_sb_bin = str(Path(sb_bin).resolve())

        if detect_os() != "windows":
            # 7. 确保二进制具有绝对执行权限
            try:
                os.chmod(resolved_sb_bin, os.stat(resolved_sb_bin).st_mode | stat.S_IEXEC)
            except Exception:
                pass

            # 8. Linux / 翼龙面板环境：通过系统级 os.execve 原地替换进程内存镜像并注入纯净环境变量
            # 彻底释放 Python 解释器全部内存，PID 保持不变，面板监控不报退出，常驻仅 ~18MB！
            try:
                os.execve(resolved_sb_bin, args, sb_env)
            except OSError as e:
                log.warning("os.execve 原地接管失败 (%s)，回退至常规单进程等待", e)

        # Windows 或 execve 异常回退场景
        core_proc = subprocess.Popen([resolved_sb_bin] + args[1:], env=sb_env)
        register_process(core_proc)
        exit_code = core_proc.wait()
        unregister_process(core_proc)
        if not is_shutting_down:
            sys.exit(exit_code)
    else:
        try:
            while not is_shutting_down:
                time.sleep(3600)
        except KeyboardInterrupt:
            graceful_exit()


if __name__ == "__main__":
    main()
