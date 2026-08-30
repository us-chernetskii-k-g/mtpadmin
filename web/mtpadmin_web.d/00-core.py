#!/usr/bin/env python3
import argparse
import datetime as dt
import hashlib
import hmac
import html
import ipaddress
import json
import os
import re
import shutil
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

VERSION = "0.5.0"
DB = "/var/lib/mtpadmin/stats.db"
STATE = "/etc/mtpadmin/state.env"
CFG = "/etc/mtpadmin/config/config.toml"
CSRF_FILE = "/etc/mtpadmin/web.csrf"
CLI = "/usr/local/bin/mtpadmin"
USERCFG = "/usr/local/lib/mtpadmin/user_config.py"
API = "http://127.0.0.1:9091"
ACTION_LOCK = threading.Lock()
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
HEX32_RE = re.compile(r"^[0-9a-fA-F]{32}$")
PERIODS = {
    "today": "Сегодня",
    "yesterday": "Вчера",
    "7d": "7 дней",
    "30d": "30 дней",
    "all": "Всё время",
}


def esc(v):
    return html.escape(str(v if v is not None else ""), quote=True)


def state():
    out = {}
    try:
        for line in Path(STATE).read_text(encoding="utf-8").splitlines():
            if not line or line.lstrip().startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                v = v[1:-1]
            out[k.strip()] = v
    except OSError:
        pass
    return out


def api_json(path, method="GET", data=None, timeout=5):
    body = None
    headers = {"Accept": "application/json"}
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(API + path, data=body, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        payload = json.loads(r.read().decode("utf-8", "replace"))
    if not isinstance(payload, dict) or payload.get("ok") is not True:
        raise RuntimeError("TeleMT API returned non-ok response")
    return payload.get("data")


def run(args, timeout=25):
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, env={**os.environ, "TERM": "dumb", "NO_COLOR": "1"})
    text = (p.stdout or "") + (("\n" + p.stderr) if p.stderr else "")
    return p.returncode, ANSI_RE.sub("", text).strip()


def cli(*args, timeout=25):
    return run([CLI, *args], timeout=timeout)


def db_connect():
    return sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=5)


def period_bounds(p):
    now = dt.datetime.now().date()
    if p == "today":
        return now.isoformat(), now.isoformat()
    if p == "yesterday":
        d = now - dt.timedelta(days=1)
        return d.isoformat(), d.isoformat()
    if p == "7d":
        return (now - dt.timedelta(days=6)).isoformat(), now.isoformat()
    if p == "30d":
        return (now - dt.timedelta(days=29)).isoformat(), now.isoformat()
    return "1970-01-01", now.isoformat()


def query(sql, params=()):
    try:
        with db_connect() as con:
            con.row_factory = sqlite3.Row
            return [dict(r) for r in con.execute(sql, params).fetchall()]
    except Exception:
        return []


def scalar(sql, params=(), default=0):
    rows = query(sql, params)
    if not rows:
        return default
    return next(iter(rows[0].values()), default)


def human_bytes(n):
    try:
        n = float(n or 0)
    except Exception:
        return "0 B"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024
    return f"{n:.1f} PB"


def csrf_secret():
    return Path(CSRF_FILE).read_bytes()


def csrf_token(user):
    slot = int(time.time() // 3600)
    msg = f"{user}|{slot}".encode()
    return hmac.new(csrf_secret(), msg, hashlib.sha256).hexdigest()


def csrf_ok(user, token):
    try:
        secret = csrf_secret()
    except OSError:
        return False
    slot = int(time.time() // 3600)
    for s in (slot, slot - 1):
