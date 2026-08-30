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


def geo_positions_data():
    """Approximate country points from retained client IPs using local DB-IP only."""
    path = Path('/var/lib/mtpadmin/geo/dbip-city-lite.mmdb')
    if not path.exists():
        return {}
    try:
        import maxminddb
    except Exception:
        return {}
    rows = query("SELECT ip,country_code FROM clients WHERE coalesce(country_code,'')!='' ORDER BY last_seen DESC LIMIT 800")
    buckets = {}
    try:
        with maxminddb.open_database(str(path)) as rd:
            for row in rows:
                cc = str(row.get('country_code') or '').upper()
                if len(cc) != 2:
                    continue
                vals = buckets.setdefault(cc, [])
                if len(vals) >= 5:
                    continue
                rec = rd.get(str(row.get('ip') or '')) or {}
                loc = rec.get('location') or {}
                lat, lon = loc.get('latitude'), loc.get('longitude')
                try:
                    lat, lon = float(lat), float(lon)
                except (TypeError, ValueError):
                    continue
                if -90 <= lat <= 90 and -180 <= lon <= 180:
                    vals.append((lat, lon))
    except Exception:
        return {}
    out = {}
    for cc, vals in buckets.items():
        if vals:
            out[cc] = [round(sum(x[0] for x in vals)/len(vals), 4), round(sum(x[1] for x in vals)/len(vals), 4)]
    return out


def page_template(title, body, user, active="dashboard", refresh=None, message=""):
    nav = [
        ("dashboard", "/", "Обзор"),
        ("stats", "/stats", "Статистика"),
        ("clients", "/clients", "Клиенты"),
        ("geo", "/geo", "География"),
        ("sources", "/sources", "Источники"),
        ("links", "/links", "Ссылки"),
        ("security", "/security", "Безопасность"),
        ("system", "/system", "Система"),
    ]
    nav_html = "".join(f'<a class="{"active" if k == active else ""}" href="{u}">{esc(label)}</a>' for k, u, label in nav)
    defaults = {"dashboard": 5, "active": 5, "security": 10, "system": 10, "stats": 15, "clients": 15, "geo": 15, "sources": 15, "links": 15}
    live_sec = int(refresh or defaults.get(active, 15))
    live_sec = max(3, min(60, live_sec))
    flash = f'<div class="flash">{esc(message)}</div>' if message else ""

    if active == 'active':
        body = body.replace('Соед. источника', 'Всего соед. источника')
        body = ("<div class='card live-tools' style='margin-bottom:14px'><h2>Поиск по активным клиентам</h2>"
                "<input id='active-local-filter' autocomplete='off' placeholder='IP, источник, страна, город, ASN или провайдер' style='width:min(520px,100%)'>"
                " <span class='muted'>Фильтр работает прямо в браузере.</span></div>" + body)

    if active == 'geo':
        positions = esc(json.dumps(geo_positions_data(), ensure_ascii=False, separators=(',', ':')))
        map_card = f"""<div class='card geo-map-card' style='margin-bottom:14px'>
<div class='geo-map-head'><div><h2>Карта мира</h2><div class='muted'>Точки строятся локально по DB-IP из сохранённых IP; размер точки соответствует выбранному показателю за период страницы.</div></div>
<div class='actions'><button class='secondary geo-metric active-metric' type='button' data-geo-metric='unique'>Уникальные IP</button><button class='secondary geo-metric' type='button' data-geo-metric='sessions'>Сеансы</button></div></div>
<div class='geo-layout'><div class='geo-canvas' id='world-map' data-positions="{positions}">
<svg viewBox='0 0 1000 500' role='img' aria-label='Карта мира с активностью клиентов'>
<rect class='geo-ocean' x='0' y='0' width='1000' height='500' rx='14'/>
<g class='geo-gridlines'><path d='M0 125H1000M0 250H1000M0 375H1000M250 0V500M500 0V500M750 0V500'/></g>
<g class='geo-land'>
<path d='M55 110 L95 70 L175 55 L250 78 L300 130 L270 180 L225 190 L205 225 L145 215 L105 175 L65 165 Z'/>
<path d='M290 250 L345 265 L375 315 L360 390 L325 455 L290 420 L275 350 Z'/>
<path d='M325 42 L382 35 L405 72 L372 118 L330 95 Z'/>
<path d='M420 105 L500 72 L610 62 L710 82 L805 115 L900 155 L860 210 L775 220 L720 195 L655 220 L585 195 L520 215 L455 180 Z'/>
<path d='M500 220 L570 205 L625 250 L610 330 L560 410 L510 365 L475 295 Z'/>
<path d='M785 330 L835 305 L900 330 L925 385 L880 420 L815 405 L775 365 Z'/>
<path d='M55 458 L180 448 L330 460 L500 450 L680 458 L850 447 L960 462 L930 492 L80 492 Z'/>
</g><g id='geo-points'></g></svg></div>
<div class='geo-side'><div id='geo-detail' class='geo-detail'><b>Активность по странам</b><div class='muted'>Нажмите на точку, чтобы увидеть значения.</div></div><div id='geo-top' class='geo-top'></div></div></div></div>"""
        body = map_card + body

    return f"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{esc(title)} · MTPADMIN</title>
<style>
:root{{--bg:#09111f;--panel:#111c2e;--panel2:#17243a;--line:#26364f;--text:#e9eef7;--muted:#94a3b8;--ok:#32d583;--warn:#fdb022;--bad:#f97066;--accent:#60a5fa;--accent2:#8b5cf6}}
*{{box-sizing:border-box}} body{{margin:0;background:linear-gradient(160deg,#07101e,#0b1323 42%,#101827);color:var(--text);font:14px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}}
a{{color:#93c5fd;text-decoration:none}} .wrap{{max-width:1450px;margin:auto;padding:22px}} .top{{display:flex;align-items:center;gap:18px;justify-content:space-between;margin-bottom:18px}}
.brand{{font-size:25px;font-weight:800;letter-spacing:.5px}} .brand span{{color:var(--accent)}} .user{{color:var(--muted);font-size:13px;display:flex;align-items:center;gap:8px}} .live-pill{{padding:2px 7px;border-radius:999px;border:1px solid #1f513d;color:var(--ok);background:#0c241d;font-size:11px}}
.nav{{display:flex;gap:7px;flex-wrap:wrap;margin:0 0 18px}} .nav a{{padding:9px 13px;border:1px solid var(--line);border-radius:10px;color:#cbd5e1;background:rgba(17,28,46,.72)}} .nav a.active,.nav a:hover{{background:#1d4ed8;color:#fff;border-color:#3b82f6}}
.grid{{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}} .grid2{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}}
.card{{background:rgba(17,28,46,.92);border:1px solid var(--line);border-radius:14px;padding:16px;box-shadow:0 8px 28px rgba(0,0,0,.12)}} .metric .v{{font-size:26px;font-weight:750;margin-top:5px}} .metric .k{{color:var(--muted)}}
h1{{font-size:22px;margin:0 0 14px}} h2{{font-size:17px;margin:0 0 12px}} h3{{font-size:14px;margin:14px 0 7px;color:#dbeafe}} .muted{{color:var(--muted)}} .ok{{color:var(--ok)}} .warn{{color:var(--warn)}} .bad{{color:var(--bad)}}
table{{width:100%;border-collapse:collapse;font-size:13px}} th,td{{padding:9px 8px;border-bottom:1px solid var(--line);text-align:left;vertical-align:top}} th{{color:#a8b6cb;font-weight:650}} tr:hover td{{background:rgba(255,255,255,.025)}}
pre{{white-space:pre-wrap;word-break:break-word;background:#07101e;border:1px solid var(--line);border-radius:10px;padding:12px;max-height:620px;overflow:auto;color:#dbeafe}}
.btn,button{{display:inline-block;border:1px solid #3b82f6;background:#1d4ed8;color:#fff;border-radius:9px;padding:8px 11px;cursor:pointer;font:inherit}} button.secondary,.btn.secondary{{background:#17243a;border-color:#3b4c67}} button.danger{{background:#b42318;border-color:#d92d20}} button.warnbtn{{background:#b54708;border-color:#dc6803}}
form.inline{{display:inline}} input,select{{background:#081221;border:1px solid #334155;color:#fff;border-radius:8px;padding:8px 10px;max-width:100%}} label{{display:block;color:#aebbd0;margin-bottom:4px}} .formgrid{{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}} .actions{{display:flex;gap:7px;flex-wrap:wrap}} .flash{{border:1px solid #2563eb;background:#102b55;padding:10px 12px;border-radius:10px;margin-bottom:14px}} .tag{{display:inline-block;padding:2px 7px;border-radius:999px;background:#253553;color:#cfe1ff;font-size:12px}}
.linkbox{{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;font-size:12px;word-break:break-all;background:#081221;padding:8px;border-radius:8px;border:1px solid #26364f;margin:5px 0}}
.geo-map-head{{display:flex;justify-content:space-between;gap:16px;align-items:flex-start;flex-wrap:wrap}} .geo-layout{{display:grid;grid-template-columns:minmax(0,3fr) minmax(220px,1fr);gap:14px;align-items:stretch}} .geo-canvas{{min-height:330px}} .geo-canvas svg{{width:100%;height:auto;display:block}} .geo-ocean{{fill:#071425;stroke:#26364f}} .geo-gridlines{{fill:none;stroke:#18304c;stroke-width:1}} .geo-land path{{fill:#20334b;stroke:#3c536e;stroke-width:1.4}} .geo-dot{{fill:#60a5fa;stroke:#e0f2fe;stroke-width:1.8;cursor:pointer;opacity:.9;transition:r .15s,opacity .15s}} .geo-dot:hover{{opacity:1;stroke-width:3}} .geo-side{{background:#0a1525;border:1px solid var(--line);border-radius:12px;padding:12px;min-height:180px}} .geo-detail{{margin-bottom:12px}} .geo-top-row{{display:flex;justify-content:space-between;gap:10px;padding:6px 0;border-bottom:1px solid #1f3048}} .active-metric{{border-color:#60a5fa!important;background:#1d4ed8!important}}
.footer{{color:#64748b;margin:22px 0 5px;font-size:12px}}
@media(max-width:950px){{.grid{{grid-template-columns:repeat(2,1fr)}}.grid2{{grid-template-columns:1fr}}.geo-layout{{grid-template-columns:1fr}}}} @media(max-width:600px){{.grid{{grid-template-columns:1fr}}.formgrid{{grid-template-columns:1fr}}.wrap{{padding:12px}}.geo-canvas{{min-height:220px}}}}
</style></head><body><div class="wrap"><div class="top"><div class="brand">MTP<span>ADMIN</span></div><div class="user"><span class="live-pill" id="live-state">● фон {live_sec}с</span><span>{esc(user)} · web {VERSION}</span></div></div><div class="nav">{nav_html}</div>{flash}<main id="live-root" data-live-ms="{live_sec*1000}" data-page="{esc(active)}">{body}</main><div class="footer">MTPADMIN · локальная панель через Caddy · DB-IP Lite применяется только локально</div></div>
<script>
function copyText(id){{navigator.clipboard.writeText(document.getElementById(id).innerText);}}
(function(){{
 const root=document.getElementById('live-root'); const stateEl=document.getElementById('live-state');
 let busy=false, geoMetric='unique';
 function editing(){{const a=document.activeElement; return !!(a&&root.contains(a)&&['INPUT','SELECT','TEXTAREA'].includes(a.tagName));}}
 function controls(){{const out={{}}; root.querySelectorAll('input,select,textarea').forEach((e,i)=>{{const k=e.id||e.name||('i'+i); if(e.type==='checkbox'||e.type==='radio')out[k]={{c:e.checked}};else out[k]={{v:e.value}};}}); return out;}}
 function restore(s){{root.querySelectorAll('input,select,textarea').forEach((e,i)=>{{const k=e.id||e.name||('i'+i),v=s[k]; if(!v)return; if('c'in v)e.checked=v.c;else if('v'in v)e.value=v.v;}});}}
 function liveMark(ok,text){{if(!stateEl)return; stateEl.textContent=(ok?'● ':'● ')+text; stateEl.style.color=ok?'var(--ok)':'var(--bad)'; stateEl.title=new Date().toLocaleTimeString();}}
 function activeFilter(){{const q=(document.getElementById('active-local-filter')?.value||'').trim().toLowerCase(); if(root.dataset.page!=='active')return; const t=[...root.querySelectorAll('table')].pop(); if(!t)return; t.querySelectorAll('tbody tr').forEach(tr=>{{tr.style.display=!q||tr.textContent.toLowerCase().includes(q)?'':'none';}});}}
 function renderGeo(){{
   const box=document.getElementById('world-map'), points=document.getElementById('geo-points'); if(!box||!points)return;
   let pos={{}}; try{{pos=JSON.parse(box.dataset.positions||'{{}}');}}catch(_e){{pos={{}};}}
   let ct=null; root.querySelectorAll('.card').forEach(c=>{{const h=c.querySelector('h2'); if(!ct&&h&&h.textContent.trim()==='Страны')ct=c.querySelector('table');}}); if(!ct)return;
   const items=[]; ct.querySelectorAll('tbody tr').forEach(tr=>{{const td=tr.querySelectorAll('td'); if(td.length<4)return; const cc=td[0].textContent.trim().toUpperCase(), name=td[1].textContent.trim(); const u=parseInt(td[2].textContent)||0,s=parseInt(td[3].textContent)||0; if(pos[cc])items.push({{cc,name,u,s,lat:+pos[cc][0],lon:+pos[cc][1]}});}});
   const vals=items.map(x=>geoMetric==='sessions'?x.s:x.u), max=Math.max(1,...vals); points.innerHTML='';
   items.forEach(x=>{{const val=geoMetric==='sessions'?x.s:x.u, cx=(x.lon+180)/360*1000,cy=(90-x.lat)/180*500,r=5+Math.sqrt(val/max)*19; const c=document.createElementNS('http://www.w3.org/2000/svg','circle'); c.setAttribute('class','geo-dot'); c.setAttribute('cx',cx.toFixed(1));c.setAttribute('cy',cy.toFixed(1));c.setAttribute('r',r.toFixed(1)); c.dataset.cc=x.cc;c.dataset.name=x.name;c.dataset.u=x.u;c.dataset.s=x.s; const title=document.createElementNS('http://www.w3.org/2000/svg','title'); title.textContent=`${{x.name}} (${{x.cc}}): ${{x.u}} IP, ${{x.s}} сеансов`; c.appendChild(title); points.appendChild(c);}});
   const top=[...items].sort((a,b)=>(geoMetric==='sessions'?b.s-a.s:b.u-a.u)).slice(0,7), target=document.getElementById('geo-top'); if(target)target.innerHTML='<b>Топ стран</b>'+top.map(x=>`<div class="geo-top-row"><span>${{x.cc}} · ${{x.name}}</span><b>${{geoMetric==='sessions'?x.s:x.u}}</b></div>`).join('');
   root.querySelectorAll('[data-geo-metric]').forEach(b=>b.classList.toggle('active-metric',b.dataset.geoMetric===geoMetric));
 }}
 function initDynamic(){{activeFilter(); renderGeo();}}
 async function tick(force=false){{
   if(location.pathname.startsWith('/action/'))return; if(!force&&(document.hidden||busy||editing()))return; busy=true; const saved=controls(), y=window.scrollY;
   try{{const r=await fetch(location.pathname+location.search,{{cache:'no-store',credentials:'same-origin',headers:{{'X-MTPADMIN-Live':'1'}}}}); if(!r.ok)throw new Error('HTTP '+r.status); const text=await r.text(); const doc=new DOMParser().parseFromString(text,'text/html'), next=doc.getElementById('live-root'); if(!next)throw new Error('live-root missing'); root.innerHTML=next.innerHTML; root.dataset.liveMs=next.dataset.liveMs||root.dataset.liveMs; root.dataset.page=next.dataset.page||root.dataset.page; restore(saved); initDynamic(); window.scrollTo(0,y); liveMark(true,'обновлено '+new Date().toLocaleTimeString());}}
   catch(e){{liveMark(false,'нет обновления'); console.debug('MTPADMIN live refresh',e);}} finally{{busy=false;}}
 }}
 root.addEventListener('input',e=>{{if(e.target.id==='active-local-filter')activeFilter();}});
 root.addEventListener('click',e=>{{const m=e.target.closest&&e.target.closest('[data-geo-metric]'); if(m){{geoMetric=m.dataset.geoMetric;renderGeo();return;}} const d=e.target.closest&&e.target.closest('.geo-dot'); if(d){{const t=document.getElementById('geo-detail'); if(t)t.innerHTML=`<b>${{d.dataset.name}} (${{d.dataset.cc}})</b><div>Уникальных IP: <b>${{d.dataset.u}}</b></div><div>Сеансов: <b>${{d.dataset.s}}</b></div>`;}}}});
 initDynamic(); const ms=Math.max(3000,parseInt(root.dataset.liveMs||'15000')); setInterval(()=>tick(false),ms); document.addEventListener('visibilitychange',()=>{{if(!document.hidden)tick(true);}}); window.addEventListener('focus',()=>tick(false));
}})();
</script></body></html>"""


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
