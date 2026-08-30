        expected = hmac.new(secret, f"{user}|{s}".encode(), hashlib.sha256).hexdigest()
        if hmac.compare_digest(expected, token or ""):
            return True
    return False


def backup_config():
    dest = f"/var/backups/mtpadmin/web-config-{time.strftime('%Y%m%d-%H%M%S')}.toml"
    shutil.copy2(CFG, dest)
    return dest


def reload_config():
    data = api_json("/v1/system/reload", method="POST", data={"mode": "instant", "failure_policy": "rollback"}, timeout=8)
    rid = (data or {}).get("reload_id")
    if not rid:
        raise RuntimeError("TeleMT did not return reload_id")
    for _ in range(40):
        st = api_json(f"/v1/system/reload/{urllib.parse.quote(str(rid))}", timeout=4)
        state_name = (st or {}).get("state")
        if state_name == "succeeded":
            return
        if state_name in ("failed", "rolled_back"):
            raise RuntimeError(f"TeleMT reload: {state_name}")
        time.sleep(0.25)
    raise RuntimeError("TeleMT reload timeout")


def source_mutation(argv, capture_secret=False):
    with ACTION_LOCK:
        backup = backup_config()
        rc, out = run([USERCFG, *argv], timeout=15)
        if rc != 0:
            shutil.copy2(backup, CFG)
            raise RuntimeError(out or "Config edit failed")
        try:
            reload_config()
        except Exception:
            shutil.copy2(backup, CFG)
            try:
                reload_config()
            except Exception:
                pass
            raise
        return out.strip() if capture_secret else ""


def source_rows():
    try:
        return api_json("/v1/users", timeout=5) or []
    except Exception:
        return []


def source_by_name(name):
    for row in source_rows():
        if str(row.get("username")) == name:
            return row
    return None


def safe_source_name(v):
    v = (v or "").strip()
    if not NAME_RE.fullmatch(v):
        raise ValueError("Некорректное имя источника")
    return v


def safe_int(v, label, allow_blank=True):
    v = (v or "").strip()
    if not v and allow_blank:
        return None
    n = int(v)
    if n < 1 or n > 10_000_000:
        raise ValueError(f"{label}: значение вне допустимого диапазона")
    return n


def page_template(title, body, user, active="dashboard", refresh=None, message=""):
    nav = [
        ("dashboard", "/", "Обзор"),
        ("stats", "/stats", "Статистика"),
        ("clients", "/clients", "Клиенты"),
        ("active", "/active", "Активные"),
        ("geo", "/geo", "География"),
        ("sources", "/sources", "Источники"),
        ("links", "/links", "Ссылки"),
        ("security", "/security", "Безопасность"),
        ("system", "/system", "Система"),
    ]
    nav_html = "".join(f'<a class="{"active" if k == active else ""}" href="{u}">{esc(label)}</a>' for k, u, label in nav)
    refresh_tag = f'<meta http-equiv="refresh" content="{int(refresh)}">' if refresh else ""
    flash = f'<div class="flash">{esc(message)}</div>' if message else ""
    return f"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">{refresh_tag}
<title>{esc(title)} · MTPADMIN</title>
<style>
:root{{--bg:#09111f;--panel:#111c2e;--panel2:#17243a;--line:#26364f;--text:#e9eef7;--muted:#94a3b8;--ok:#32d583;--warn:#fdb022;--bad:#f97066;--accent:#60a5fa;--accent2:#8b5cf6}}
*{{box-sizing:border-box}} body{{margin:0;background:linear-gradient(160deg,#07101e,#0b1323 42%,#101827);color:var(--text);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}}
a{{color:#93c5fd;text-decoration:none}} .wrap{{max-width:1450px;margin:auto;padding:22px}} .top{{display:flex;align-items:center;gap:18px;justify-content:space-between;margin-bottom:18px}}
.brand{{font-size:25px;font-weight:800;letter-spacing:.5px}} .brand span{{color:var(--accent)}} .user{{color:var(--muted);font-size:13px}}
.nav{{display:flex;gap:7px;flex-wrap:wrap;margin:0 0 18px}} .nav a{{padding:9px 13px;border:1px solid var(--line);border-radius:10px;color:#cbd5e1;background:rgba(17,28,46,.72)}} .nav a.active,.nav a:hover{{background:#1d4ed8;color:#fff;border-color:#3b82f6}}
.grid{{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}} .grid2{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}}
.card{{background:rgba(17,28,46,.92);border:1px solid var(--line);border-radius:14px;padding:16px;box-shadow:0 8px 28px rgba(0,0,0,.12)}} .metric .v{{font-size:26px;font-weight:750;margin-top:5px}} .metric .k{{color:var(--muted)}}
h1{{font-size:22px;margin:0 0 14px}} h2{{font-size:17px;margin:0 0 12px}} h3{{font-size:14px;margin:14px 0 7px;color:#dbeafe}} .muted{{color:var(--muted)}} .ok{{color:var(--ok)}} .warn{{color:var(--warn)}} .bad{{color:var(--bad)}}
table{{width:100%;border-collapse:collapse;font-size:13px}} th,td{{padding:9px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}} th{{color:#a8b6cb;font-weight:650}} tr:hover td{{background:rgba(255,255,255,.025)}}
pre{{white-space:pre-wrap;word-break:break-word;background:#07101e;border:1px solid var(--line);border-radius:10px;padding:12px;max-height:620px;overflow:auto;color:#dbeafe}}
.btn,button{{display:inline-block;border:1px solid #3b82f6;background:#1d4ed8;color:#fff;border-radius:9px;padding:8px 11px;cursor:pointer;font:inherit}} button.secondary,.btn.secondary{{background:#17243a;border-color:#3b4c67}} button.danger{{background:#b42318;border-color:#d92d20}} button.warnbtn{{background:#b54708;border-color:#dc6803}}
form.inline{{display:inline}} input,select{{background:#081221;border:1px solid #334155;color:#fff;border-radius:8px;padding:8px 10px;max-width:100%}} label{{display:block;color:#aebbd0;margin-bottom:4px}} .formgrid{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}} .actions{{display:flex;gap:7px;flex-wrap:wrap}} .flash{{border:1px solid #2563eb;background:#102b55;padding:10px 12px;border-radius:10px;margin-bottom:14px}} .tag{{display:inline-block;padding:2px 7px;border-radius:999px;background:#253553;color:#cfe1ff;font-size:12px}}
.linkbox{{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:12px;word-break:break-all;background:#081221;padding:8px;border-radius:8px;border:1px solid #26364f;margin:5px 0}}
.footer{{color:#64748b;margin:22px 0 5px;font-size:12px}}
@media(max-width:950px){{.grid{{grid-template-columns:repeat(2,1fr)}}.grid2{{grid-template-columns:1fr}}}} @media(max-width:600px){{.grid{{grid-template-columns:1fr}}.formgrid{{grid-template-columns:1fr}}.wrap{{padding:12px}}}}
</style></head><body><div class="wrap"><div class="top"><div class="brand">MTP<span>ADMIN</span></div><div class="user">{esc(user)} · web {VERSION}</div></div><div class="nav">{nav_html}</div>{flash}{body}<div class="footer">MTPADMIN · локальная панель через Caddy · DB-IP Lite применяется только локально</div></div>
<script>function copyText(id){{navigator.clipboard.writeText(document.getElementById(id).innerText);}} </script></body></html>"""


def table(headers, rows):
    h = "".join(f"<th>{esc(x)}</th>" for x in headers)
    r = []
    for row in rows:
        r.append("<tr>" + "".join(f"<td>{x}</td>" for x in row) + "</tr>")
    return f"<div style='overflow:auto'><table><thead><tr>{h}</tr></thead><tbody>{''.join(r) if r else '<tr><td colspan=99 class=muted>Нет данных</td></tr>'}</tbody></table></div>"


def dashboard_html():
    st = state()
    profile = st.get("PROFILE", "MAIN")
    try:
        users = source_rows()
    except Exception:
        users = []
    current = sum(int(u.get("current_connections") or 0) for u in users)
    active_ips = sum(int(u.get("active_unique_ips") or 0) for u in users)
    total_bytes = sum(int(u.get("total_octets") or 0) for u in users)
    today = dt.date.today().isoformat()
    uniq = scalar("SELECT count(DISTINCT ip_hash) AS n FROM anon_visits WHERE day=?", (today,), 0)
    sessions = scalar("SELECT coalesce(sum(observations),0) AS n FROM anon_visits WHERE day=?", (today,), 0)
    countries = query("SELECT country_code,country_name,count(DISTINCT ip_hash) u,sum(observations) s FROM anon_visits WHERE day=? GROUP BY country_code,country_name ORDER BY u DESC,s DESC LIMIT 8", (today,))
    sources = []
    for u in users:
        sources.append([
            esc(u.get("username")),
            '<span class="ok">ON</span>' if u.get("enabled", True) else '<span class="bad">OFF</span>',
            esc(u.get("current_connections", 0)), esc(u.get("active_unique_ips", 0)), human_bytes(u.get("total_octets", 0))
        ])
    cards = f"""<div class="grid">
<div class="card metric"><div class="k">TeleMT</div><div class="v ok">ONLINE</div><div class="muted">{esc(st.get('PUBLIC_HOST',''))}:{esc(st.get('PORT',''))}</div></div>
<div class="card metric"><div class="k">Сейчас соединений</div><div class="v">{current}</div><div class="muted">активных IP: {active_ips}</div></div>
<div class="card metric"><div class="k">Сегодня клиентов</div><div class="v">{esc(uniq)}</div><div class="muted">наблюдений: {esc(sessions)}</div></div>
<div class="card metric"><div class="k">Суммарный трафик TeleMT</div><div class="v">{esc(human_bytes(total_bytes))}</div><div class="muted">основной профиль: {esc(profile)}</div></div>
</div>"""