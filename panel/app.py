#!/usr/bin/env python3
"""pisec web paneli.

pisec komutunun üstünde ince bir katman: taramaları başlatır ve canlı izletir,
sonuçları gösterir, zamanlanmış görevleri, Docker konteynerlerini ve Cloudflare
yayınlarını yönetir. İşin kendisi pisec ve docker komutlarında; panel sadece
onları argüman listesiyle (kabuk olmadan) çağırıyor. Panelde serbest komut
satırı bilerek yok.

Kullanım:
    python3 app.py passwd      parola belirle (ilk kurulumda bir kez)
    python3 app.py serve       paneli başlat (systemd servisi bunu çalıştırıyor)
"""
import argparse
import getpass
import html
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime
from pathlib import Path

from flask import (Blueprint, Flask, abort, current_app, flash, jsonify, redirect,
                   render_template, request, send_file, session, url_for)
from markupsafe import Markup
from werkzeug.security import check_password_hash, generate_password_hash

VERSION = "0.2.0"
HOME = Path.home()
CONF_DIR = Path(os.environ.get("PISEC_CONF_DIR", HOME / ".config/pisec"))
PANEL_CONF = CONF_DIR / "panel.json"
OUT_ROOT = Path(os.environ.get("PISEC_OUT", HOME / "pisec-sonuclar"))
STATE_DIR = Path(os.environ.get("PISEC_STATE", HOME / ".local/state/pisec"))
JOBS_DIR = STATE_DIR / "jobs"
APPS_DIR = Path(os.environ.get("PISEC_APPS", HOME / "pisec-apps"))
TEMPLATES_DIR = HOME / "nuclei-templates"
UFW_CONF = Path(os.environ.get("PISEC_UFW_CONF", "/etc/ufw/ufw.conf"))
PISEC = os.environ.get("PISEC_BIN") or shutil.which("pisec") or "/usr/local/bin/pisec"
DEMO = os.environ.get("PISEC_PANEL_DEMO") == "1"
HOSTNAME = os.environ.get("PISEC_HOSTNAME") or socket.gethostname()

MAX_RUNNING_JOBS = 2
LOGIN_WINDOW = 600
LOGIN_MAX_FAILURES = 5

# Hedef pisec'e argüman olarak gidiyor; pisec ayrıca kendi doğrulamasını yapıyor.
# İlk karakterin harf/rakam olması "-" ile başlayan seçenek enjeksiyonunu kapatıyor.
TARGET_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.:/_-]{0,252}$")
PORTS_RE = re.compile(r"^[0-9][0-9,-]{0,100}$")
SEVERITY_RE = re.compile(r"^(info|low|medium|high|critical)(,(info|low|medium|high|critical))*$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
JOB_ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}-[a-f0-9]{4}$")
JOB_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9.-]{0,62}$")
APP_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,30}$")
CONTAINER_RE = re.compile(r"^[a-f0-9]{12,64}$")
WHEN_RE = re.compile(r"^[A-Za-z0-9*:/,.~ -]{1,64}$")
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")

SCHEDULE_PRESETS = [
    ("*-*-* 03:00:00", "Her gün 03:00"),
    ("Mon *-*-* 03:00:00", "Her pazartesi 03:00"),
    ("*-*-01 03:00:00", "Her ayın 1'i 03:00"),
    ("hourly", "Saatte bir"),
]

COMPOSE_TEMPLATE = """services:
  web:
    image: nginx:alpine
    restart: unless-stopped
    ports:
      # Sadece 127.0.0.1: Docker'ın açtığı portlar ufw'yi atlıyor.
      # Dışarıya açmak için Yayınla sayfasını kullan.
      - "127.0.0.1:8081:80"
    volumes:
      - ./site:/usr/share/nginx/html:ro
"""

bp = Blueprint("panel", __name__)
_failed_logins = {}
_procs = {}
_job_lock = threading.Lock()
_cache = {}


# --- Yardımcılar ----------------------------------------------------------------

def load_conf():
    try:
        return json.loads(PANEL_CONF.read_text())
    except FileNotFoundError:
        return {}


def save_conf(conf):
    CONF_DIR.mkdir(parents=True, exist_ok=True)
    tmp = PANEL_CONF.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(conf, f, indent=2)
    os.replace(tmp, PANEL_CONF)


def tool_env():
    env = dict(os.environ)
    env["PATH"] = f"{HOME}/.pdtm/go/bin:" + env.get("PATH", "/usr/local/bin:/usr/bin:/bin")
    return env


def sh(args, timeout=30, input_text=None):
    """Komutu kabuk olmadan çalıştırır, (çıkış kodu, stdout+stderr) döner."""
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env=tool_env(),
                           input=input_text, stdin=None if input_text is not None else subprocess.DEVNULL)
        return p.returncode, ANSI_RE.sub("", p.stdout + p.stderr)
    except FileNotFoundError:
        return 127, f"{args[0]} bulunamadı."
    except subprocess.TimeoutExpired:
        return 124, f"{args[0]} {timeout} saniyede bitmedi."


def pisec(*args, timeout=30, input_text=None):
    return sh([PISEC, *args], timeout=timeout, input_text=input_text)


def cached(key, seconds, fn):
    now = time.time()
    hit = _cache.get(key)
    if hit and now - hit[0] < seconds:
        return hit[1]
    value = fn()
    _cache[key] = (now, value)
    return value


def now_str():
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def fmt_bytes(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024
    return str(n)


def fmt_duration(seconds):
    seconds = int(seconds)
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    minutes = rest // 60
    if days:
        return f"{days} gün {hours} sa"
    if hours:
        return f"{hours} sa {minutes} dk"
    return f"{minutes} dk"


def message(ok, text):
    flash(text.strip() or ("Tamam." if ok else "Hata."), "ok" if ok else "error")


def client_ip():
    ip = request.remote_addr or "?"
    # cloudflared ile gelen istekler 127.0.0.1'den görünüyor; asıl adres bu başlıkta.
    if ip in ("127.0.0.1", "::1"):
        ip = request.headers.get("CF-Connecting-IP", ip)
    return ip


# --- Özet dosyası -------------------------------------------------------------------

def inline_md(text):
    text = html.escape(text)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", text)


def render_summary(text):
    """pisec'in yazdığı ozet.md'yi HTML'e çevirir.

    Genel bir Markdown kütüphanesi kullanılmıyor: özet, taranan sitelerden gelen
    başlık gibi metinler içeriyor ve ham HTML ya da javascript: bağlantısı panele
    sızmamalı. Burada sadece pisec'in ürettiği başlık, liste, tablo ve `kod`
    destekleniyor, geri kalan her şey kaçışlanıyor.
    """
    out, table, in_list = [], None, False

    def flush_table():
        nonlocal table
        if table:
            head, *rows = table
            out.append('<div class="table-wrap"><table><thead><tr>'
                       + "".join(f"<th>{inline_md(c)}</th>" for c in head) + "</tr></thead><tbody>")
            for row in rows:
                out.append("<tr>" + "".join(f"<td>{inline_md(c)}</td>" for c in row) + "</tr>")
            out.append("</tbody></table></div>")
        table = None

    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("|") and stripped.endswith("|") and len(stripped) > 1:
            if in_list:
                out.append("</ul>")
                in_list = False
            cells = [c.strip() for c in stripped[1:-1].split("|")]
            if all(c and set(c) <= set("-:") for c in cells):
                continue
            table = (table or []) + [cells]
            continue
        flush_table()
        if line.startswith("- "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline_md(line[2:])}</li>")
            continue
        if in_list:
            out.append("</ul>")
            in_list = False
        if line.startswith("### "):
            out.append(f"<h4>{inline_md(line[4:])}</h4>")
        elif line.startswith("## "):
            out.append(f"<h3>{inline_md(line[3:])}</h3>")
        elif line.startswith("# "):
            out.append(f"<h2>{inline_md(line[2:])}</h2>")
        elif stripped:
            out.append(f"<p>{inline_md(line)}</p>")
    flush_table()
    if in_list:
        out.append("</ul>")
    return Markup("\n".join(out))


# --- Sonuçlar -------------------------------------------------------------------

def parse_run(target_dir, run_dir):
    m = re.match(r"^(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})-([a-z]+)", run_dir.name)
    head = ""
    try:
        with open(run_dir / "ozet.md", encoding="utf-8", errors="replace") as f:
            head = f.read(600)
    except OSError:
        pass
    label = target_dir.name
    if re.fullmatch(r"\d+\.\d+\.\d+\.\d+_\d+", label):
        label = label.replace("_", "/")
    return {
        "target": target_dir.name,
        "label": label,
        "run": run_dir.name,
        "cmd": m.group(7) if m else "?",
        "date": f"{m.group(1)}-{m.group(2)}-{m.group(3)} {m.group(4)}:{m.group(5)}" if m else run_dir.name,
        "tor": "Tor: evet" in head,
    }


def list_runs(target=None, limit=None):
    runs = []
    if not OUT_ROOT.is_dir():
        return runs
    targets = [OUT_ROOT / target] if target else sorted(OUT_ROOT.iterdir())
    for t in targets:
        if not t.is_dir():
            continue
        for r in t.iterdir():
            if r.is_dir() and (r / "ozet.md").is_file():
                runs.append(parse_run(t, r))
    runs.sort(key=lambda x: x["run"], reverse=True)
    return runs[:limit] if limit else runs


def run_dir_or_404(target, run):
    if not NAME_RE.fullmatch(target) or not NAME_RE.fullmatch(run):
        abort(404)
    d = (OUT_ROOT / target / run).resolve()
    if not d.is_dir() or OUT_ROOT.resolve() not in d.parents:
        abort(404)
    return d


# --- İşler (arka planda çalışan pisec komutları) ------------------------------------

def job_file(jid, ext):
    return JOBS_DIR / f"{jid}.{ext}"


def write_job(job):
    JOBS_DIR.mkdir(parents=True, exist_ok=True)
    tmp = job_file(job["id"], "tmp")
    tmp.write_text(json.dumps(job))
    os.replace(tmp, job_file(job["id"], "json"))


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except PermissionError:
        return True
    except (OSError, TypeError):
        return False
    return True


def read_job(jid):
    if not JOB_ID_RE.fullmatch(jid):
        abort(404)
    try:
        job = json.loads(job_file(jid, "json").read_text())
    except FileNotFoundError:
        abort(404)
    if job["status"] == "running" and jid not in _procs and not pid_alive(job.get("pid")):
        # Panel yeniden başlamış ve iş o sırada bitmiş ya da durmuş.
        job.update(status="unknown", finished=job.get("finished") or now_str())
        write_job(job)
    return job


def list_jobs(limit=50):
    if not JOBS_DIR.is_dir():
        return []
    ids = sorted((p.stem for p in JOBS_DIR.glob("*.json")), reverse=True)[:limit]
    return [read_job(i) for i in ids if JOB_ID_RE.fullmatch(i)]


class JobError(Exception):
    pass


def start_job(label, argv):
    with _job_lock:
        if sum(1 for j in list_jobs() if j["status"] == "running") >= MAX_RUNNING_JOBS:
            raise JobError(f"Aynı anda en fazla {MAX_RUNNING_JOBS} iş çalışabiliyor; birinin bitmesini bekle.")
        jid = datetime.now().strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(2)
        JOBS_DIR.mkdir(parents=True, exist_ok=True)
        log = open(job_file(jid, "log"), "wb")
        try:
            proc = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                    env=tool_env(), cwd=HOME, start_new_session=True)
        except OSError as e:
            log.close()
            raise JobError(f"Başlatılamadı: {e}") from e
        job = {"id": jid, "label": label, "argv": argv, "pid": proc.pid, "status": "running",
               "started": now_str(), "finished": None, "rc": None, "run": None}
        write_job(job)
        _procs[jid] = proc
    threading.Thread(target=_wait_job, args=(jid, proc, log), daemon=True).start()
    return jid


def _wait_job(jid, proc, log):
    rc = proc.wait()
    log.close()
    job = json.loads(job_file(jid, "json").read_text())
    if job["status"] != "stopped":
        job["status"] = "done" if rc == 0 else "failed"
    job.update(rc=rc, finished=now_str())
    text = job_file(jid, "log").read_text(errors="replace")
    m = re.search(r"^\[\+\] Sonuçlar: (.+)$", text, re.M)
    if m:
        p = Path(m.group(1).strip())
        if p.parent.parent == OUT_ROOT:
            job["run"] = {"target": p.parent.name, "run": p.name}
    write_job(job)
    _procs.pop(jid, None)


def stop_job(jid):
    job = read_job(jid)
    if job["status"] != "running":
        return
    job["status"] = "stopped"
    write_job(job)
    try:
        os.killpg(job["pid"], signal.SIGTERM)
    except OSError:
        pass


def read_log(jid, offset, limit=65536):
    path = job_file(jid, "log")
    try:
        with open(path, "rb") as f:
            f.seek(offset)
            chunk = f.read(limit)
    except FileNotFoundError:
        return "", offset
    # Parça bir UTF-8 karakterinin ortasında bitmesin: tam satırda kes.
    if len(chunk) == limit and b"\n" in chunk:
        chunk = chunk[:chunk.rindex(b"\n") + 1]
    text = ANSI_RE.sub("", chunk.decode("utf-8", "replace"))
    if DEMO:
        text = text.replace(str(OUT_ROOT), "~/pisec-sonuclar")
    return text.replace(f"{HOME}/", "~/"), offset + len(chunk)


# --- Sistem durumu --------------------------------------------------------------

def system_info():
    if DEMO:
        # Demo başka bir makinede (ör. geliştirici bilgisayarı) çalışıyor; Pi değerleri gösterilsin.
        return {"host": HOSTNAME, "uptime": "6 gün 4 sa", "load": "0.42  0.37  0.31", "temp": "47.2 °C",
                "mem": "612.4 MB / 1.8 GB", "mem_pct": 33, "disk": "7.9 GB / 29.1 GB", "disk_pct": 27}
    info = {"host": HOSTNAME, "uptime": "-", "load": "-", "temp": "-", "mem": "-", "mem_pct": 0}
    try:
        info["uptime"] = fmt_duration(float(Path("/proc/uptime").read_text().split()[0]))
    except (OSError, ValueError):
        pass
    try:
        info["load"] = "%.2f  %.2f  %.2f" % os.getloadavg()
    except OSError:
        pass
    try:
        info["temp"] = f"{int(Path('/sys/class/thermal/thermal_zone0/temp').read_text()) / 1000:.1f} °C"
    except (OSError, ValueError):
        pass
    try:
        mem = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            key, value = line.split(":", 1)
            mem[key] = int(value.split()[0]) * 1024
        used = mem["MemTotal"] - mem["MemAvailable"]
        info["mem"] = f"{fmt_bytes(used)} / {fmt_bytes(mem['MemTotal'])}"
        info["mem_pct"] = round(100 * used / mem["MemTotal"])
    except (OSError, KeyError, ValueError):
        pass
    disk = shutil.disk_usage("/")
    info["disk"] = f"{fmt_bytes(disk.used)} / {fmt_bytes(disk.total)}"
    info["disk_pct"] = round(100 * disk.used / disk.total)
    return info


def service_states():
    names = ["tor@default", "fail2ban", "docker"]
    rc, out = sh(["systemctl", "is-active", *names], timeout=5)
    states = dict(zip(names, (out.split() + ["?"] * len(names))[:len(names)]))
    try:
        ufw = UFW_CONF.read_text()
        states["ufw"] = "active" if re.search(r"^ENABLED=yes", ufw, re.M) else "inactive"
    except OSError:
        states["ufw"] = "not-found"
    rc, out = sh(["systemctl", "--user", "is-active", "pisec-tunnel.service"], timeout=5)
    states["cloudflare-tunnel"] = out.strip() or "inactive"
    return states


def tor_exit():
    rc, out = sh(["curl", "-fsS", "--max-time", "20", "--socks5-hostname", "127.0.0.1:9050",
                  "https://check.torproject.org/api/ip"], timeout=25)
    try:
        data = json.loads(out)
        return {"ok": bool(data.get("IsTor")), "ip": data.get("IP", "?")}
    except ValueError:
        return {"ok": False, "ip": None}


def tool_versions():
    tools = [
        ("nmap", ["nmap", "--version"]),
        ("nuclei", ["nuclei", "-version"]),
        ("subfinder", ["subfinder", "-version"]),
        ("httpx", ["httpx", "-version"]),
        ("dnsx", ["dnsx", "-version"]),
        ("naabu", ["naabu", "-version"]),
        ("tor", ["tor", "--version"]),
        ("testssl", ["testssl", "--version"]),
        ("cloudflared", ["cloudflared", "--version"]),
        ("docker", ["docker", "--version"]),
    ]
    result = []
    for name, cmd in tools:
        rc, out = sh(cmd, timeout=15)
        m = re.search(r"v?(\d+\.\d+(?:\.\d+)?[\w.-]*)", out) if rc != 127 else None
        result.append((name, m.group(1) if m else ("yok" if rc == 127 else "?")))
    return result


def schedules():
    rc, out = pisec("schedule", "list", "--json", timeout=20)
    try:
        return json.loads(out) if rc == 0 else []
    except ValueError:
        return []


def scope_entries():
    rc, out = pisec("scope", timeout=10)
    if rc != 0 or out.startswith("Kapsam listesi boş"):
        return []
    return [line.strip() for line in out.splitlines() if line.strip()]


# --- Docker ---------------------------------------------------------------------

def docker_state():
    if not shutil.which("docker"):
        return False, "Docker kurulu değil. Kurmak için: ./setup.sh --with-docker"
    rc, out = sh(["docker", "info", "--format", "{{.ServerVersion}}"], timeout=10)
    if rc != 0:
        return False, ("Docker'a erişilemiyor. Kullanıcın docker grubunda mı? Gruba yeni eklendiysen "
                       "paneli yeniden başlatman gerekir.\n" + out.strip()[:300])
    return True, out.strip()


def compose_cmd():
    if sh(["docker", "compose", "version"], timeout=10)[0] == 0:
        return ["docker", "compose"]
    if shutil.which("docker-compose"):
        return ["docker-compose"]
    return None


def containers():
    rc, out = sh(["docker", "ps", "-a", "--no-trunc", "--format", "{{json .}}"], timeout=15)
    items = []
    for line in out.splitlines():
        try:
            c = json.loads(line)
        except ValueError:
            continue
        c["host_ports"] = sorted(set(re.findall(r"(?:\d+\.\d+\.\d+\.\d+|\[?::\]?):(\d+)->", c.get("Ports", ""))))
        c["exposed"] = bool(re.search(r"(?:0\.0\.0\.0|\[?::\]?):\d+->", c.get("Ports", "")))
        items.append(c)
    return items


def apps():
    result = []
    if not APPS_DIR.is_dir():
        return result
    for d in sorted(APPS_DIR.iterdir()):
        f = d / "compose.yaml"
        if d.is_dir() and APP_NAME_RE.fullmatch(d.name) and f.is_file():
            ports = re.findall(r"127\.0\.0\.1:(\d+):\d+", f.read_text(errors="replace"))
            result.append({"name": d.name, "ports": ports})
    return result


def unsafe_port_lines(compose_text):
    """127.0.0.1'e bağlanmamış port eşlemelerini bulur ("8080:80", "0.0.0.0:8080:80")."""
    bad = []
    for line in compose_text.splitlines():
        m = re.match(r'^\s*-\s*["\']?([0-9.:\[\]]+:)?\d+:\d+(/\w+)?["\']?\s*(#.*)?$', line)
        if m and not (m.group(1) or "").startswith("127.0.0.1:"):
            bad.append(line.strip())
    return bad


# --- Kimlik doğrulama ve güvenlik başlıkları ---------------------------------------

@bp.before_app_request
def protect():
    if request.endpoint == "static":
        return None
    if request.method == "POST":
        token = request.form.get("csrf") or request.headers.get("X-CSRF-Token") or ""
        if not session.get("csrf") or not secrets.compare_digest(token, session["csrf"]):
            abort(400, "Form süresi dolmuş ya da geçersiz (CSRF). Sayfayı yenileyip tekrar dene.")
    if request.endpoint == "panel.login" or current_app.config["DEMO"]:
        return None
    if not session.get("auth"):
        if request.path.startswith("/api/"):
            return jsonify(error="giriş gerekli"), 401
        return redirect(url_for("panel.login", next=request.path))
    return None


@bp.after_app_request
def security_headers(resp):
    resp.headers["Content-Security-Policy"] = (
        "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; "
        "frame-ancestors 'none'; form-action 'self'; base-uri 'none'")
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Referrer-Policy"] = "no-referrer"
    resp.headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()"
    resp.headers.setdefault("Cache-Control", "no-store")
    return resp


@bp.app_context_processor
def template_globals():
    if "csrf" not in session:
        session["csrf"] = secrets.token_hex(16)
    return {"csrf": session["csrf"], "host": HOSTNAME, "version": VERSION,
            "demo": current_app.config["DEMO"],
            "demo_banner": current_app.config["DEMO"] and os.environ.get("PISEC_DEMO_BANNER", "1") == "1"}


@bp.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        ip, now = client_ip(), time.time()
        recent = [t for t in _failed_logins.get(ip, []) if now - t < LOGIN_WINDOW]
        if len(recent) >= LOGIN_MAX_FAILURES:
            return render_template("login.html", error="Çok fazla hatalı deneme. 10 dakika sonra tekrar dene."), 429
        pw_hash = current_app.config["PASSWORD_HASH"]
        if pw_hash and check_password_hash(pw_hash, request.form.get("password", "")):
            _failed_logins.pop(ip, None)
            session.clear()
            session.permanent = True
            session["auth"] = True
            session["csrf"] = secrets.token_hex(16)
            nxt = request.args.get("next", "/")
            if not nxt.startswith("/") or nxt.startswith("//"):
                nxt = "/"
            return redirect(nxt)
        recent.append(now)
        _failed_logins[ip] = recent
        time.sleep(1)
        error = "Parola yanlış."
        return render_template("login.html", error=error), 401
    return render_template("login.html", error=error)


@bp.post("/logout")
def logout():
    session.clear()
    return redirect(url_for("panel.login"))


# --- Sayfalar -------------------------------------------------------------------

@bp.get("/")
def dashboard():
    jobs = list_jobs(limit=8)
    return render_template("dashboard.html", info=system_info(), services=service_states(),
                           runs=list_runs(limit=8), jobs=jobs,
                           running=[j for j in jobs if j["status"] == "running"],
                           schedules=schedules()[:5])


@bp.get("/api/tor")
def api_tor():
    return jsonify(cached("tor", 120, tor_exit))


@bp.get("/api/status")
def api_status():
    return jsonify(system_info())


@bp.route("/jobs", methods=["GET", "POST"])
def jobs_page():
    form = request.form if request.method == "POST" else request.args
    if request.method == "POST":
        cmd = form.get("cmd", "")
        target = form.get("target", "").strip()
        try:
            if cmd not in ("scan", "recon", "web", "lan"):
                raise JobError("Geçersiz komut.")
            if cmd != "lan" and not target:
                raise JobError("Hedef gerekli.")
            if target and not TARGET_RE.fullmatch(target):
                raise JobError("Geçersiz hedef.")
            argv = [PISEC, cmd] + ([target] if target else [])
            if form.get("tor") and cmd != "lan":
                argv.append("--tor")
            ports = form.get("ports", "").strip()
            if ports and cmd == "scan":
                if not PORTS_RE.fullmatch(ports):
                    raise JobError("Geçersiz port listesi.")
                argv += ["-p", ports]
            severity = form.get("severity", "").strip()
            if severity and cmd == "web":
                if not SEVERITY_RE.fullmatch(severity):
                    raise JobError("Geçersiz önem listesi.")
                argv += ["-s", severity]
            if target:
                rc, out = pisec("scope", "check", target, timeout=10)
                if rc != 0:
                    return render_template("jobs.html", jobs=list_jobs(), form=form, scope_missing=target,
                                           error=out.strip()), 409
            jid = start_job(f"{cmd} {target}".strip() + (" (Tor)" if "--tor" in argv else ""), argv)
            return redirect(url_for("panel.job_page", jid=jid))
        except JobError as e:
            return render_template("jobs.html", jobs=list_jobs(), form=form, error=str(e)), 400
    return render_template("jobs.html", jobs=list_jobs(), form=form, error=None)


@bp.get("/jobs/<jid>")
def job_page(jid):
    return render_template("job.html", job=read_job(jid))


@bp.post("/jobs/<jid>/stop")
def job_stop(jid):
    stop_job(jid)
    return redirect(url_for("panel.job_page", jid=jid))


@bp.get("/api/jobs/<jid>")
def api_job(jid):
    job = read_job(jid)
    try:
        offset = max(0, int(request.args.get("offset", 0)))
    except ValueError:
        offset = 0
    text, offset = read_log(jid, offset)
    run_url = url_for("panel.run_page", target=job["run"]["target"], run=job["run"]["run"]) if job.get("run") else None
    return jsonify(status=job["status"], rc=job["rc"], offset=offset, text=text, run_url=run_url)


@bp.get("/results")
def results_page():
    target = request.args.get("target")
    if target and not NAME_RE.fullmatch(target):
        abort(404)
    runs = list_runs(target=target)
    targets = sorted({(r["target"], r["label"]) for r in list_runs()})
    return render_template("results.html", runs=runs, targets=targets, target=target)


@bp.get("/results/<target>/<run>")
def run_page(target, run):
    d = run_dir_or_404(target, run)
    summary = (d / "ozet.md").read_text(errors="replace") if (d / "ozet.md").is_file() else ""
    files = [{"name": f.name, "size": fmt_bytes(f.stat().st_size)}
             for f in sorted(d.iterdir()) if f.is_file() and NAME_RE.fullmatch(f.name)]
    return render_template("run.html", target=target, run=run, info=parse_run(d.parent, d),
                           summary=render_summary(summary), files=files)


@bp.get("/results/<target>/<run>/<name>")
def run_file(target, run, name):
    d = run_dir_or_404(target, run)
    if not NAME_RE.fullmatch(name):
        abort(404)
    f = d / name
    if not f.is_file():
        abort(404)
    # Araç çıktıları taranan sitelerden gelen içerik barındırıyor; tarayıcı HTML
    # olarak yorumlamasın diye her şey düz metin ya da indirme olarak gidiyor.
    if request.args.get("download"):
        return send_file(f, as_attachment=True, download_name=f"{target}-{run}-{name}")
    return send_file(f, mimetype="text/plain; charset=utf-8")


@bp.route("/scope", methods=["GET", "POST"])
def scope_page():
    if request.method == "POST":
        target = request.form.get("target", "").strip()
        if not TARGET_RE.fullmatch(target):
            message(False, "Geçersiz hedef.")
        elif request.form.get("action") == "rm":
            message(*_ok(pisec("scope", "rm", target)))
        elif not request.form.get("permission"):
            message(False, "Hedefi eklemek için test izni olduğunu onaylaman gerekiyor.")
        else:
            message(*_ok(pisec("scope", "add", target)))
        back = request.form.get("back", "")
        return redirect(back if back.startswith("/") and not back.startswith("//") else url_for("panel.scope_page"))
    return render_template("scope.html", entries=scope_entries())


def _ok(result):
    rc, out = result
    return rc == 0, out


@bp.route("/schedules", methods=["GET", "POST"])
def schedules_page():
    if request.method == "POST":
        action = request.form.get("action")
        name = request.form.get("name", "").strip()
        if action in ("rm", "run"):
            if JOB_NAME_RE.fullmatch(name):
                message(*_ok(pisec("schedule", action, name)))
            else:
                message(False, "Geçersiz görev adı.")
        elif action == "add":
            when = request.form.get("when", "")
            if when == "custom":
                when = request.form.get("when_custom", "").strip()
            cmd = request.form.get("cmd", "")
            target = request.form.get("target", "").strip()
            args = ["schedule", "add", when, cmd, target]
            if not WHEN_RE.fullmatch(when) or cmd not in ("scan", "recon", "web", "lan") \
                    or not TARGET_RE.fullmatch(target):
                message(False, "Zaman, komut ya da hedef geçersiz.")
            else:
                if request.form.get("tor") and cmd != "lan":
                    args.append("--tor")
                if name:
                    if not JOB_NAME_RE.fullmatch(name):
                        message(False, "Görev adı küçük harf, rakam, nokta ve tire içerebilir.")
                        return redirect(url_for("panel.schedules_page"))
                    args += ["--name", name]
                message(*_ok(pisec(*args, timeout=30)))
        return redirect(url_for("panel.schedules_page"))
    return render_template("schedules.html", schedules=schedules(), presets=SCHEDULE_PRESETS,
                           scope=scope_entries())


@bp.route("/docker", methods=["GET", "POST"])
def docker_page():
    ok, info = docker_state()
    if request.method == "POST" and ok:
        action = request.form.get("action", "")
        cid = request.form.get("id", "")
        app_name = request.form.get("app", "")
        compose = compose_cmd()
        if action in ("start", "stop", "restart"):
            if CONTAINER_RE.fullmatch(cid) and cid in {c["ID"] for c in containers()}:
                message(*_ok(sh(["docker", action, cid], timeout=60)))
            else:
                message(False, "Konteyner bulunamadı.")
        elif action in ("up", "down"):
            if not compose:
                message(False, "docker compose bulunamadı.")
            elif APP_NAME_RE.fullmatch(app_name) and (APPS_DIR / app_name / "compose.yaml").is_file():
                f = APPS_DIR / app_name / "compose.yaml"
                extra = ["up", "-d"] if action == "up" else ["down"]
                message(*_ok(sh([*compose, "-p", f"pisec-{app_name}", "-f", str(f), *extra], timeout=300)))
            else:
                message(False, "Uygulama bulunamadı.")
        elif action == "create":
            message(*create_app(app_name, request.form.get("compose", ""), compose))
        return redirect(url_for("panel.docker_page"))
    return render_template("docker.html", ok=ok, info=info,
                           containers=containers() if ok else [], apps=apps(),
                           template=COMPOSE_TEMPLATE, compose=bool(ok and compose_cmd()))


def create_app(name, text, compose):
    if not APP_NAME_RE.fullmatch(name):
        return False, "Uygulama adı küçük harf, rakam ve tire içerebilir (en fazla 31 karakter)."
    if not compose:
        return False, "docker compose bulunamadı."
    d = APPS_DIR / name
    if d.exists():
        return False, f"{name} zaten var."
    bad = unsafe_port_lines(text)
    if bad:
        return False, ("Bu portlar tüm ağ arayüzlerine açılıyor ve Docker ufw kurallarını atlıyor: "
                       + ", ".join(bad) + ". Başına 127.0.0.1: ekle, dışarıya Yayınla sayfasından aç.")
    d.mkdir(parents=True)
    (d / "compose.yaml").write_text(text.replace("\r\n", "\n"))
    rc, out = sh([*compose, "-f", str(d / "compose.yaml"), "config", "-q"], timeout=30)
    if rc != 0:
        shutil.rmtree(d)
        return False, "compose dosyası geçersiz:\n" + out
    if "./site:" in text:
        (d / "site").mkdir(exist_ok=True)
        (d / "site" / "index.html").write_text(
            f"<!doctype html><meta charset=utf-8><title>{html.escape(name)}</title>"
            f"<h1>{html.escape(name)}</h1><p>pi-secbox üzerinde çalışıyor.</p>\n")
    return True, f"{name} oluşturuldu. Başlatmak için 'Başlat'a bas."


@bp.get("/docker/logs")
def docker_logs():
    ok, info = docker_state()
    if not ok:
        abort(404)
    cid, app_name = request.args.get("id", ""), request.args.get("app", "")
    if CONTAINER_RE.fullmatch(cid) and cid in {c["ID"] for c in containers()}:
        title, (rc, out) = cid[:12], sh(["docker", "logs", "--tail", "300", cid], timeout=20)
    elif APP_NAME_RE.fullmatch(app_name) and (APPS_DIR / app_name / "compose.yaml").is_file() and compose_cmd():
        f = APPS_DIR / app_name / "compose.yaml"
        title, (rc, out) = app_name, sh([*compose_cmd(), "-p", f"pisec-{app_name}", "-f", str(f),
                                         "logs", "--tail", "300", "--no-color"], timeout=20)
    else:
        abort(404)
    return render_template("text.html", title=f"Günlük: {title}", text=out, back=url_for("panel.docker_page"))


@bp.route("/publish", methods=["GET", "POST"])
def publish_page():
    if request.method == "POST":
        action = request.form.get("action")
        port = request.form.get("port", "").strip()
        if action == "publish":
            if not port.isdigit() or not 1 <= int(port) <= 65535:
                message(False, "Geçersiz port.")
            elif not request.form.get("confirm"):
                message(False, "Adresin herkese açık olacağını onaylaman gerekiyor.")
            else:
                message(*_ok(pisec("publish", port, "-y", timeout=70)))
        elif action == "stop" and port.isdigit():
            message(*_ok(pisec("publish", "stop", port)))
        elif action == "token":
            token = request.form.get("token", "").strip()
            message(*_ok(pisec("tunnel", "token", input_text=token + "\n")))
        elif action in ("tunnel-start", "tunnel-stop"):
            message(*_ok(pisec("tunnel", action.split("-")[1], timeout=30)))
        return redirect(url_for("panel.publish_page"))
    rc, out = pisec("publish", "list", "--json", timeout=15)
    try:
        published = json.loads(out) if rc == 0 else []
    except ValueError:
        published = []
    rc, tunnel = pisec("tunnel", "status", timeout=10)
    return render_template("publish.html", published=published, tunnel=tunnel,
                           cloudflared=bool(shutil.which("cloudflared")),
                           port=request.args.get("port", ""), apps=apps())


SYSTEM_ACTIONS = {
    "tor-new": "Tor'dan yeni devre iste",
    "update-tools": "ProjectDiscovery araçlarını güncelle",
    "update-templates": "nuclei şablonlarını güncelle",
    "notify-test": "Deneme bildirimi gönder",
}


@bp.route("/system", methods=["GET", "POST"])
def system_page():
    if request.method == "POST":
        action = request.form.get("action")
        try:
            if action == "tor-new":
                message(*_ok(pisec("tor", "new")))
                _cache.pop("tor", None)
            elif action == "update-tools":
                return redirect(url_for("panel.job_page", jid=start_job(
                    "ProjectDiscovery araçlarını güncelle", ["pdtm", "-duc", "-ua"])))
            elif action == "update-templates":
                argv = (["git", "-C", str(TEMPLATES_DIR), "pull", "--ff-only"]
                        if (TEMPLATES_DIR / ".git").is_dir() else ["nuclei", "-duc", "-ut"])
                return redirect(url_for("panel.job_page", jid=start_job("nuclei şablonlarını güncelle", argv)))
            elif action == "notify-set":
                url = request.form.get("ntfy", "").strip()
                message(*_ok(pisec("notify", "set", url) if url else pisec("notify", "off")))
            elif action == "notify-test":
                message(*_ok(pisec("notify", "test", timeout=20)))
            elif action == "password":
                message(*change_password(request.form))
        except JobError as e:
            message(False, str(e))
        return redirect(url_for("panel.system_page"))
    rc, notify = pisec("notify", timeout=10)
    return render_template("system.html", versions=cached("versions", 3600, tool_versions),
                           notify=notify.strip(), actions=SYSTEM_ACTIONS)


def change_password(form):
    pw_hash = current_app.config["PASSWORD_HASH"]
    if not pw_hash or not check_password_hash(pw_hash, form.get("current", "")):
        return False, "Mevcut parola yanlış."
    new = form.get("new", "")
    if len(new) < 10:
        return False, "Yeni parola en az 10 karakter olmalı."
    if new != form.get("repeat"):
        return False, "Yeni parolalar aynı değil."
    conf = load_conf()
    conf["password_hash"] = generate_password_hash(new)
    save_conf(conf)
    current_app.config["PASSWORD_HASH"] = conf["password_hash"]
    return True, "Parola değişti."


@bp.app_template_filter("cmdline")
def cmdline(argv):
    if argv and Path(argv[0]).name == "pisec":
        argv = ["pisec", *argv[1:]]
    return " ".join(argv)


@bp.app_template_filter("status_class")
def status_class(state):
    return {"active": "ok", "running": "run", "done": "ok", "failed": "bad", "stopped": "warn",
            "unknown": "warn", "inactive": "off", "exited": "off", "not-found": "off"}.get(state, "warn")


@bp.app_template_filter("status_text")
def status_text(state):
    return {"active": "çalışıyor", "running": "çalışıyor", "done": "bitti", "failed": "hata",
            "stopped": "durduruldu", "unknown": "bilinmiyor", "inactive": "kapalı", "exited": "durdu",
            "not-found": "kurulu değil", "activating": "başlıyor"}.get(state, state)


# --- Uygulama -------------------------------------------------------------------

def create_app_instance(demo=DEMO):
    conf = load_conf()
    app = Flask(__name__)
    app.secret_key = conf.get("secret_key") or secrets.token_hex(32)
    app.config.update(
        DEMO=demo,
        PASSWORD_HASH=conf.get("password_hash"),
        SESSION_COOKIE_NAME="pisec_session",
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Strict",
        SESSION_COOKIE_SECURE=bool(conf.get("cookie_secure")),
        PERMANENT_SESSION_LIFETIME=12 * 3600,
        MAX_CONTENT_LENGTH=256 * 1024,
    )
    app.register_blueprint(bp)
    return app


def cmd_passwd():
    conf = load_conf()
    while True:
        pw = getpass.getpass("Panel parolası (en az 10 karakter): ")
        if len(pw) < 10:
            print("En az 10 karakter olmalı.")
            continue
        if pw != getpass.getpass("Tekrar: "):
            print("Parolalar aynı değil.")
            continue
        break
    conf["password_hash"] = generate_password_hash(pw)
    conf.setdefault("secret_key", secrets.token_hex(32))
    conf.setdefault("host", "127.0.0.1")
    conf.setdefault("port", 8090)
    conf.setdefault("cookie_secure", False)
    save_conf(conf)
    print(f"Kaydedildi: {PANEL_CONF}")
    print("Paneli başlatmak için: pisec panel start")


def cmd_serve(host, port):
    conf = load_conf()
    host = host or conf.get("host", "127.0.0.1")
    port = port or int(conf.get("port", 8090))
    if DEMO and host not in ("127.0.0.1", "::1", "localhost"):
        sys.exit("Demo modunda giriş kapalı; sadece 127.0.0.1 üzerinde açılır.")
    if not DEMO and not conf.get("password_hash"):
        sys.exit("Panel parolası belirlenmemiş. Önce: pisec panel passwd")
    app = create_app_instance()
    print(f"pisec paneli: http://{host}:{port}" + ("  (demo modu, giriş kapalı)" if DEMO else ""), flush=True)
    try:
        from waitress import serve
    except ImportError:
        sys.exit("waitress bulunamadı: sudo apt install python3-waitress")
    serve(app, host=host, port=port, threads=8, ident="pisec")


def main():
    parser = argparse.ArgumentParser(description="pisec web paneli")
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("passwd", help="parola belirle")
    serve = sub.add_parser("serve", help="paneli başlat")
    serve.add_argument("--host")
    serve.add_argument("--port", type=int)
    args = parser.parse_args()
    if args.cmd == "passwd":
        cmd_passwd()
    else:
        cmd_serve(getattr(args, "host", None), getattr(args, "port", None))


if __name__ == "__main__":
    main()
