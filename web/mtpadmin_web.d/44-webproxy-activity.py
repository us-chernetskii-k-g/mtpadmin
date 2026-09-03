# MTPADMIN 0.12.0 WEB Proxy activity + public client UI layer.
# tproxy-server is outside TeleMT. MTPADMIN's patched loopback admin endpoint
# exposes only active client IP + session count; no tokens, capabilities or
# request/query logs are exported.

_WPA_METRICS_URL = 'http://127.0.0.1:8081/metrics'
_WPA_CLIENTS_URL = 'http://127.0.0.1:8081/mtpadmin/clients'
_WPA_NAMES = {
    'tproxy_sessions_live',
    'tproxy_streams_live',
    'tproxy_streams_opened_total',
    'tproxy_bytes_up_total',
    'tproxy_bytes_down_total',
    'tproxy_backend_dial_failures_total',
    'tproxy_limit_hits_total',
}


def _wpa_metrics():
    try:
        req = urllib.request.Request(_WPA_METRICS_URL, headers={'Accept':'text/plain'})
        with urllib.request.urlopen(req, timeout=1.5) as r:
            text = r.read().decode('utf-8','replace')
        out = {}
        for line in text.splitlines():
            if not line or line.startswith('#') or ' ' not in line:
                continue
            name, raw = line.split(None, 1)
            if name not in _WPA_NAMES:
                continue
            try:
                out[name] = int(float(raw.strip()))
            except (TypeError, ValueError):
                continue
        return out
    except Exception:
        return {}


def _wpa_clients():
    try:
        req=urllib.request.Request(_WPA_CLIENTS_URL,headers={'Accept':'application/json'})
        with urllib.request.urlopen(req,timeout=1.5) as r:
            obj=json.loads(r.read().decode('utf-8','replace'))
        raw=obj.get('clients') if isinstance(obj,dict) else None
        if not isinstance(raw,list):
            return []
        out=[]
        for row in raw:
            if not isinstance(row,dict):
                continue
            try:
                ip=str(ipaddress.ip_address(str(row.get('ip') or '')))
                sessions=int(row.get('sessions') or 0)
            except (ValueError,TypeError):
                continue
            if sessions>0:
                out.append({'ip':ip,'sessions':sessions})
        def sort_key(row):
            addr=ipaddress.ip_address(row['ip'])
            return (addr.version,int(addr))
        out.sort(key=sort_key)
        return out
    except Exception:
        return []


_wpa_source_rows = source_rows

def source_rows():
    rows = [dict(x) for x in _wpa_source_rows()]
    st = state()
    websrc = str(st.get('WEBPROXY_SOURCE','WEB_PROXY') or 'WEB_PROXY')
    metrics = _wpa_metrics()
    clients = _wpa_clients()
    if not metrics and not clients:
        return rows
    fallback_sessions=sum(int(x.get('sessions') or 0) for x in clients)
    sessions = int(metrics.get('tproxy_sessions_live',fallback_sessions) or fallback_sessions)
    streams = int(metrics.get('tproxy_streams_live',0) or 0)
    for row in rows:
        if str(row.get('username') or '') != websrc:
            continue
        row['web_proxy'] = True
        row['web_sessions_live'] = sessions
        row['web_streams_live'] = streams
        row['web_streams_opened_total'] = int(metrics.get('tproxy_streams_opened_total',0) or 0)
        row['web_bytes_up_total'] = int(metrics.get('tproxy_bytes_up_total',0) or 0)
        row['web_bytes_down_total'] = int(metrics.get('tproxy_bytes_down_total',0) or 0)
        row['web_backend_dial_failures_total'] = int(metrics.get('tproxy_backend_dial_failures_total',0) or 0)
        row['web_limit_hits_total'] = int(metrics.get('tproxy_limit_hits_total',0) or 0)
        row['current_connections'] = sessions
        row['active_unique_ips'] = len(clients)
        row['active_unique_ips_list'] = [x['ip'] for x in clients]
        break
    return rows


def active_clients_html():
    users=source_rows(); by_name={str(u.get('username','')):u for u in users}
    st=state(); websrc=str(st.get('WEBPROXY_SOURCE','WEB_PROXY') or 'WEB_PROXY')
    try:
        telemt_live=api_json('/v1/stats/users/active-ips',timeout=5) or []
    except Exception:
        telemt_live=[]
        for u in users:
            name=str(u.get('username',''))
            if name==websrc:
                continue
            ips=u.get('active_unique_ips_list') or []
            if ips: telemt_live.append({'username':name,'active_ips':ips})

    items=[]
    for entry in telemt_live:
        name=str(entry.get('username',''))
        if name==websrc:
            continue
        for raw_ip in entry.get('active_ips') or []:
            try: ip=str(ipaddress.ip_address(str(raw_ip)))
            except ValueError: continue
            items.append(('MT',name,ip,0))
    for row in _wpa_clients():
        items.append(('WEB',websrc,row['ip'],int(row.get('sessions') or 0)))

    rows=[]; unique=set(); active_source_names=set()
    for kind,name,ip,ip_sessions in items:
        unique.add(ip); active_source_names.add(name)
        src=by_name.get(name,{})
        hist=query('SELECT country_code,city,asn,org,first_seen,last_seen,hits FROM clients WHERE ip=? LIMIT 1',(ip,))
        h=hist[0] if hist else {}
        obs=query('SELECT classification,risk_score,valid_last_seen FROM scanner_observations WHERE ip=? LIMIT 1',(ip,))
        o=obs[0] if obs else {}
        if kind=='WEB':
            live_badge='<span class="ok">● WEB</span>'+(f' <span class="muted">×{ip_sessions}</span>' if ip_sessions>1 else '')
        else:
            live_badge='<span class="ok">● LIVE</span>'
        rows.append([
            live_badge,esc(name),esc(ip),esc(h.get('country_code','')),esc(h.get('city','')),
            esc(h.get('asn','')),esc(h.get('org','')),esc(src.get('current_connections',0)),
            esc(guard_epoch(h.get('first_seen'))),esc(guard_epoch(h.get('last_seen'))),guard_badge(o.get('classification','CLIENT'))
        ])
    rows.sort(key=lambda r:(r[1],r[2]))
    total_conns=sum(int(u.get('current_connections') or 0) for u in users)
    metrics=_wpa_metrics(); streams=int(metrics.get('tproxy_streams_live',0) or 0)
    cards=f"""<div class='grid'>
<div class='card metric'><div class='k'>Текущие соединения</div><div class='v'>{total_conns}</div><div class='muted'>TeleMT + WEB Proxy</div></div>
<div class='card metric'><div class='k'>Активные IP</div><div class='v ok'>{len(unique)}</div><div class='muted'>оба транспорта</div></div>
<div class='card metric'><div class='k'>Активные источники</div><div class='v'>{len(active_source_names)}</div><div class='muted'>из {len(users)}</div></div>
<div class='card metric'><div class='k'>WEB потоки</div><div class='v'>{streams}</div><div class='muted'>обновление 5 сек · {esc(dt.datetime.now().strftime('%H:%M:%S'))}</div></div>
</div>"""
    note="""<div class='card' style='margin-top:14px'><h2>Активные клиенты сейчас</h2><div class='muted'>Обычные MTProto-клиенты и WEB-клиенты показываются в одном списке. Для WEB Proxy панель получает только текущий IP и число активных соединений через локальный служебный интерфейс сервера. Данные для подключения и секреты туда не передаются.</div></div>"""
    body=table(['','Источник','IP','CC','Город','ASN','Провайдер / сеть','Соед. источника','Первый','Последний','Guard'],rows)
    return cards+note+"<div class='card' style='margin-top:14px'>"+body+"</div>"


# analytics-plus owns the real /active HTTP route and intentionally calls the
# pre-analytics snapshot named _a_active_clients_html. Rebind that hook after
# this extension loads, otherwise the new renderer exists in the assembled
# file but the browser still receives the old TeleMT-only page.
if '_a_active_clients_html' in globals():
    _a_active_clients_html = active_clients_html


# ---------------------------------------------------------------------------
# Public, responsive client UI. Presentation only: all proven handlers and
# actions stay underneath this layer.
# ---------------------------------------------------------------------------
_PUBLIC_GITHUB='https://github.com/us-chernetskii-k-g/mtpadmin'
_PUBLIC_TG='https://t.me/boss_of_this_vpn'
_PUBLIC_SITE='https://brakonder.ru'

_CLIENT_STYLE=r'''
<style id="mtpadmin-client-ui">
:root{--bg:#07101d;--panel:#0d1929;--panel2:#111f33;--panel3:#15263d;--line:#213552;--line2:#2c4466;--text:#f2f6fc;--muted:#91a2b9;--ok:#24d17e;--warn:#ffb020;--bad:#ff6666;--accent:#2583ff;--accent2:#5c5cff;--cyan:#29b6f6;--shadow:0 18px 45px rgba(0,0,0,.22)}
html{background:var(--bg)}body.mtp-modern{min-height:100vh;background:radial-gradient(circle at 70% -10%,rgba(37,131,255,.11),transparent 32%),linear-gradient(145deg,#06101d 0%,#091321 52%,#0a1422 100%);font-size:14px}
body.mtp-modern .wrap{max-width:none!important;min-height:100vh;margin:0!important;padding:0!important;display:grid;grid-template-columns:236px minmax(0,1fr);grid-template-rows:74px auto minmax(0,1fr) auto}
body.mtp-modern .top{grid-column:1/3;grid-row:1;margin:0!important;padding:0 28px;display:flex;align-items:center;position:sticky;top:0;z-index:90;background:rgba(6,16,29,.88);backdrop-filter:blur(18px);border-bottom:1px solid rgba(66,94,130,.35)}
body.mtp-modern .brand{display:flex;align-items:center;gap:12px;font-size:0!important;min-width:190px}
.m-logo{display:grid;place-items:center;width:42px;height:42px;border-radius:12px;background:linear-gradient(145deg,#237cff,#654eff);box-shadow:0 8px 24px rgba(37,131,255,.36);font-size:23px;font-weight:900;color:#fff;letter-spacing:-1px;clip-path:polygon(50% 0,94% 23%,94% 77%,50% 100%,6% 77%,6% 23%)}
.m-brand-text{display:flex;flex-direction:column;line-height:1}.m-brand-name{font-size:21px;font-weight:850;letter-spacing:.15px;color:#fff}.m-brand-name b{color:#59a2ff}.m-brand-sub{font-size:10px;color:#8295ad;font-weight:500;margin-top:6px;letter-spacing:.2px}
body.mtp-modern .user{margin-left:auto;display:flex;align-items:center;gap:10px}.m-user-dot{width:34px;height:34px;border-radius:50%;display:grid;place-items:center;border:1px solid var(--line2);background:#142238;color:#d7e3f4;font-weight:700;text-transform:uppercase}.m-user-name{color:#9fb0c7;font-size:12px}
body.mtp-modern .live-pill{display:inline-flex;align-items:center;gap:7px;padding:7px 11px!important;border:1px solid rgba(36,209,126,.28)!important;border-radius:10px!important;background:rgba(7,46,33,.65)!important;color:var(--ok)!important;font-size:12px!important;font-weight:650}.live-pill:before{content:'';width:7px;height:7px;border-radius:50%;background:currentColor;box-shadow:0 0 10px currentColor}
body.mtp-modern .nav{grid-column:1;grid-row:2/5;position:sticky!important;top:74px!important;height:calc(100vh - 74px);margin:0!important;padding:18px 14px!important;background:rgba(8,18,31,.82)!important;border-right:1px solid rgba(66,94,130,.34);display:flex!important;flex-direction:column;gap:4px!important;overflow-y:auto;overflow-x:hidden!important;white-space:normal!important;backdrop-filter:blur(14px)}
body.mtp-modern .nav a{position:relative;display:flex;align-items:center;min-height:42px;padding:10px 12px 10px 43px!important;border:1px solid transparent!important;border-radius:11px!important;background:transparent!important;color:#acbad0!important;font-size:13px!important;font-weight:560;transition:.18s ease}
body.mtp-modern .nav a:hover{background:#111f33!important;color:#edf5ff!important;border-color:#203754!important;transform:translateX(1px)}body.mtp-modern .nav a.active{background:linear-gradient(90deg,rgba(37,131,255,.23),rgba(37,131,255,.08))!important;border-color:rgba(58,139,255,.42)!important;color:#69aaff!important;box-shadow:inset 3px 0 #2583ff}
body.mtp-modern .nav a:before{position:absolute;left:14px;width:18px;text-align:center;font-size:16px;opacity:.95}body.mtp-modern .nav a[href='/']:before{content:'⌂'}body.mtp-modern .nav a[href='/stats']:before{content:'⌁'}body.mtp-modern .nav a[href='/clients']:before{content:'♙'}body.mtp-modern .nav a[href='/active']:before{content:'◉'}body.mtp-modern .nav a[href='/geo']:before{content:'◎'}body.mtp-modern .nav a[href='/sources']:before{content:'◫'}body.mtp-modern .nav a[href='/links']:before{content:'↗'}body.mtp-modern .nav a[href='/security']:before{content:'◇'}body.mtp-modern .nav a[href='/operations']:before{content:'☷'}body.mtp-modern .nav a[href='/system']:before{content:'⚙'}
.m-side-links{margin-top:auto;padding-top:16px;border-top:1px solid #1c2e47}.m-side-title{padding:0 10px 7px;color:#61758f;font-size:10px;text-transform:uppercase;letter-spacing:.8px}.m-side-links a{padding-left:42px!important}.m-side-links a:before{content:'↗'!important}.m-side-links a.m-support:before{content:'?'!important}.m-side-links a.m-community:before{content:'✈'!important}
body.mtp-modern .flash{grid-column:2;grid-row:2;margin:18px 26px 0!important;border:1px solid rgba(37,131,255,.46)!important;background:linear-gradient(90deg,rgba(20,66,124,.62),rgba(19,41,71,.72))!important;border-radius:12px!important;padding:11px 14px!important;box-shadow:none!important}
body.mtp-modern #live-root{grid-column:2;grid-row:3;padding:22px 26px 34px;min-width:0;max-width:1540px;width:100%;margin:0 auto}
body.mtp-modern .footer{grid-column:2;grid-row:4;margin:0!important;padding:20px 28px 24px!important;border-top:1px solid rgba(66,94,130,.25);display:flex;align-items:center;justify-content:space-between;gap:14px;flex-wrap:wrap;color:#70839b!important;background:rgba(5,14,25,.42)}.m-footer-links{display:flex;gap:14px;flex-wrap:wrap}.m-footer-links a{color:#8ca5c2}.m-footer-links a:hover{color:#61a8ff}
body.mtp-modern .card{background:linear-gradient(145deg,rgba(14,27,45,.96),rgba(12,23,39,.95))!important;border:1px solid #203651!important;border-radius:15px!important;box-shadow:0 8px 28px rgba(0,0,0,.12)!important;padding:17px!important}body.mtp-modern .card:hover{border-color:#294766!important}
body.mtp-modern .grid{grid-template-columns:repeat(4,minmax(0,1fr));gap:12px!important}body.mtp-modern .grid2{gap:13px!important}.metric{position:relative;overflow:hidden}.metric:after{content:'';position:absolute;width:90px;height:90px;right:-40px;top:-45px;border-radius:50%;background:rgba(37,131,255,.05)}body.mtp-modern .metric .k{font-size:11px!important;color:#8799b0!important}.metric .v{font-size:26px!important;line-height:1.15;letter-spacing:-.35px;margin-top:7px!important}
.m-hero{display:flex;align-items:center;justify-content:space-between;gap:18px;min-height:106px;padding:19px 22px!important;background:linear-gradient(110deg,rgba(12,28,48,.98),rgba(12,31,56,.94))!important}.m-hero-left{display:flex;align-items:center;gap:16px}.m-health-icon{width:52px;height:52px;border-radius:50%;display:grid;place-items:center;background:rgba(36,209,126,.12);border:2px solid var(--ok);color:var(--ok);font-size:27px;box-shadow:0 0 26px rgba(36,209,126,.12)}.m-health-icon.warn{border-color:var(--warn);color:var(--warn);background:rgba(255,176,32,.12)}.m-hero h1{font-size:20px!important;margin:0 0 4px!important}.m-hero-spark{width:min(390px,36vw);height:44px;opacity:.8}.m-hero-spark path{fill:none;stroke:#2583ff;stroke-width:2}
.m-section-title{display:flex;align-items:flex-end;justify-content:space-between;gap:12px;margin:22px 2px 11px}.m-section-title h2{margin:0!important;font-size:17px!important}.m-section-title p{margin:2px 0 0;color:#7f91a9;font-size:12px}.m-quick{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px}.m-quick a{display:flex;align-items:center;gap:10px;padding:13px 14px;border-radius:12px;border:1px solid #213956;background:#101d30;color:#dce7f5;transition:.18s}.m-quick a:hover{border-color:#3375c6;background:#132640;transform:translateY(-1px)}.m-quick i{font-style:normal;width:30px;height:30px;border-radius:9px;display:grid;place-items:center;background:#122e54;color:#55a3ff;font-size:16px}
body.mtp-modern h1{font-size:22px}body.mtp-modern h2{font-size:16px}body.mtp-modern h3{color:#d9e8fa}body.mtp-modern .muted{color:#8799b0!important}body.mtp-modern .ok{color:#2bd786!important}body.mtp-modern .warn{color:#ffb62e!important}body.mtp-modern .bad{color:#ff7474!important}
body.mtp-modern table{font-size:12.5px}body.mtp-modern th{color:#91a4bd!important;font-size:11px;font-weight:650;background:rgba(18,32,51,.58)}body.mtp-modern th,body.mtp-modern td{padding:10px 9px!important;border-bottom-color:#1d3049!important}body.mtp-modern tr:hover td{background:rgba(37,131,255,.035)!important}
body.mtp-modern input,body.mtp-modern select,body.mtp-modern textarea{background:#071321!important;border:1px solid #2b4160!important;border-radius:10px!important;color:#edf4fc!important;min-height:38px;outline:none}body.mtp-modern input:focus,body.mtp-modern select:focus,body.mtp-modern textarea:focus{border-color:#3185ed!important;box-shadow:0 0 0 3px rgba(37,131,255,.12)}
body.mtp-modern .btn,body.mtp-modern button{border-radius:10px!important;padding:8px 12px!important;background:linear-gradient(180deg,#267fe9,#1766cb)!important;border-color:#388deb!important;font-weight:600;box-shadow:none!important}body.mtp-modern button.secondary,body.mtp-modern .btn.secondary{background:#132238!important;border-color:#2c4465!important;color:#d1dded!important}body.mtp-modern button.danger{background:#872f31!important;border-color:#aa4244!important}body.mtp-modern button.warnbtn{background:#85590b!important;border-color:#a87312!important}
body.mtp-modern .ui-tabs{padding:4px;background:#0c1828;border:1px solid #1f344f;border-radius:12px;width:max-content;max-width:100%}body.mtp-modern .ui-tabs button{border:0!important;background:transparent!important;color:#899cb4!important}body.mtp-modern .ui-tabs button.active{background:#1f63c5!important;color:#fff!important}
body.mtp-modern .linkbox{background:#071321!important;border-color:#223955!important;border-radius:10px!important}body.mtp-modern pre{background:#060f1c!important;border-color:#213651!important;border-radius:12px!important;color:#cfe0f5!important}
.m-friendly-note{display:flex;gap:12px;align-items:flex-start;padding:13px 14px;border-radius:12px;background:#0b1d31;border:1px solid #1f3b5d;color:#cdd9e8}.m-friendly-note i{font-style:normal;color:#54a4ff;font-size:18px}.m-tech-details{margin-top:13px!important;border:1px solid #203651!important;border-radius:12px!important;background:#0a1626!important}.m-tech-details>summary{padding:11px 13px!important;color:#8fa1b8!important;font-size:12px!important}.m-tech-details .ui-details-body{padding:0 13px 13px!important}
@media(max-width:1100px){body.mtp-modern .wrap{grid-template-columns:205px minmax(0,1fr)}body.mtp-modern #live-root{padding:18px}.m-quick{grid-template-columns:repeat(2,1fr)}body.mtp-modern .grid{grid-template-columns:repeat(2,1fr)}.m-hero-spark{display:none}}
@media(max-width:760px){body.mtp-modern{padding-bottom:66px}body.mtp-modern .wrap{display:block!important;min-height:auto}body.mtp-modern .top{height:64px;padding:0 14px!important;position:sticky;top:0}.m-logo{width:36px;height:36px;font-size:20px}.m-brand-name{font-size:18px}.m-brand-sub{display:none}.m-user-name,.m-user-dot{display:none}.live-pill{font-size:10px!important;padding:6px 8px!important}body.mtp-modern .nav{position:fixed!important;left:0;right:0;bottom:0;top:auto!important;height:64px!important;z-index:120;padding:5px 7px!important;border-right:0;border-top:1px solid #213753;display:flex!important;flex-direction:row!important;align-items:stretch;gap:3px!important;overflow-x:auto!important;background:rgba(5,15,27,.96)!important}body.mtp-modern .nav a{min-width:72px;min-height:52px;padding:29px 7px 4px!important;justify-content:center;text-align:center;font-size:9.5px!important;border-radius:9px!important;flex:1 0 72px}body.mtp-modern .nav a:before{left:50%!important;top:5px;transform:translateX(-50%);font-size:16px}.m-side-links{display:none!important}body.mtp-modern .flash{margin:12px 12px 0!important}body.mtp-modern #live-root{padding:14px 12px 24px!important}.footer{display:none!important}.m-hero{min-height:94px;padding:16px!important}.m-health-icon{width:44px;height:44px;font-size:23px}.m-hero h1{font-size:17px!important}.m-hero .muted{font-size:12px}.m-quick{grid-template-columns:repeat(2,1fr)}body.mtp-modern .grid{grid-template-columns:repeat(2,1fr)!important}.metric .v{font-size:23px!important}.card{padding:14px!important}.ui-table-wrap{max-height:none!important}table{min-width:680px}.geo-layout{grid-template-columns:1fr!important}.actions{gap:6px!important}}
@media(max-width:430px){body.mtp-modern .grid{grid-template-columns:1fr!important}.m-quick{grid-template-columns:1fr}.m-hero-left{gap:11px}.m-health-icon{width:40px;height:40px}.m-section-title{align-items:flex-start;flex-direction:column}.formgrid{grid-template-columns:1fr!important}}
</style>
'''

_CLIENT_SCRIPT=r'''
<script id="mtpadmin-client-ui-script">
(function(){
 function enhance(){
  document.body.classList.add('mtp-modern');
  var brand=document.querySelector('.brand');
  if(brand&&!brand.dataset.modern){brand.dataset.modern='1';brand.innerHTML='<span class="m-logo">M</span><span class="m-brand-text"><span class="m-brand-name">MTP<b>ADMIN</b></span><small class="m-brand-sub">Управление Telegram Proxy</small></span>';}
  var nav=document.querySelector('.nav');
  if(nav&&!nav.querySelector('.m-side-links')){var box=document.createElement('div');box.className='m-side-links';box.innerHTML='<div class="m-side-title">Проект</div><a class="m-support" href="https://github.com/us-chernetskii-k-g/mtpadmin" target="_blank" rel="noopener">GitHub</a><a class="m-community" href="https://t.me/boss_of_this_vpn" target="_blank" rel="noopener">Сообщество</a>';nav.appendChild(box);}
  var names={'/':'Обзор','/stats':'Статистика','/clients':'Клиенты','/active':'Активные','/geo':'География','/sources':'Источники','/links':'Ссылки','/security':'Защита','/operations':'Операции','/system':'Настройки'};
  document.querySelectorAll('.nav>a').forEach(function(a){var p=new URL(a.href,location.href).pathname;if(names[p])a.textContent=names[p];});
  var u=document.querySelector('.user');if(u&&!u.dataset.modern){u.dataset.modern='1';var raw=(u.textContent||'').trim();var who=(raw.match(/\b([A-Za-zА-Яа-я0-9_.@-]+)\s*·\s*web/)||[])[1]||'admin';u.querySelectorAll('span:not(.live-pill)').forEach(function(e){e.remove()});var n=document.createElement('span');n.className='m-user-name';n.textContent=who;var d=document.createElement('span');d.className='m-user-dot';d.textContent=who.slice(0,1);u.append(n,d);}
 }
 if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',enhance);else enhance();
 new MutationObserver(enhance).observe(document.documentElement,{childList:true,subtree:true});
})();
</script>
'''

_client_base_page_template=page_template

def page_template(title,body,user,active='dashboard',refresh=None,message=''):
    doc=_client_base_page_template(title,body,user,active=active,refresh=refresh,message=message)
    if 'mtpadmin-client-ui' not in doc:
        doc=doc.replace('</head>',_CLIENT_STYLE+'</head>',1)
    doc=doc.replace('<body>','<body class="mtp-modern">',1)
    year=dt.datetime.now().year
    footer=(f"<div class=\"footer\"><span>© {year} MTPADMIN · часть экосистемы <a href=\"{_PUBLIC_SITE}\" target=\"_blank\" rel=\"noopener\">VPN BOSS</a></span>" f"<span class=\"m-footer-links\"><a href=\"{_PUBLIC_GITHUB}\" target=\"_blank\" rel=\"noopener\">Исходный код</a><a href=\"{_PUBLIC_TG}\" target=\"_blank\" rel=\"noopener\">Помощь и сообщество</a><span>версия {esc(VERSION)}</span></span></div>")
    doc=re.sub(r'<div class="footer">.*?</div>',footer,doc,count=1,flags=re.S)
    if 'mtpadmin-client-ui-script' not in doc:
        doc=doc.replace('</body>',_CLIENT_SCRIPT+'</body>',1)
    return doc


def _client_spark():
    return """<svg class='m-hero-spark' viewBox='0 0 360 48' preserveAspectRatio='none' aria-hidden='true'><path d='M0 38 C25 31 30 35 54 27 S86 30 105 20 S140 25 162 16 S197 22 216 12 S247 18 270 10 S310 16 360 5'/></svg>"""


def dashboard_html():
    st=state(); users=source_rows() or []
    current=sum(int(u.get('current_connections') or 0) for u in users); ips=sum(int(u.get('active_unique_ips') or 0) for u in users)
    score=100
    try: score,_checks=_o_health()
    except Exception: pass
    wp_host=st.get('WEBPROXY_HOST','не настроен')
    try: wp_ready=bool(st.get('WEBPROXY_READY','0')=='1' and _o_service('tproxy-server.service') and _o_http_ok('http://127.0.0.1:8081/readyz'))
    except Exception: wp_ready=st.get('WEBPROXY_READY','0')=='1'
    today=dt.date.today().isoformat(); uniq=scalar("SELECT count(DISTINCT ip_hash) AS n FROM anon_visits WHERE day=?",(today,),0); traffic=scalar("SELECT coalesce(sum(bytes_from_client+bytes_to_client),0) AS n FROM daily_traffic WHERE day=?",(today,),0)
    try: updates=int((_o_update_status().get('updates') or 0))
    except Exception: updates=0
    good=score>=90
    hero=f"""<div class='card m-hero'><div class='m-hero-left'><div class='m-health-icon {' ' if good else 'warn'}'>{'✓' if good else '!'}</div><div><h1>{'Сервис работает стабильно' if good else 'Есть пункты, требующие внимания'}</h1><div class='muted'>{'Все основные службы доступны' if good else 'Откройте «Операции», чтобы увидеть подробности'}</div></div></div>{_client_spark()}</div>"""
    metrics=f"""<div class='grid' style='margin-top:12px'><div class='card metric'><div class='k'>Состояние</div><div class='v {'ok' if good else 'warn'}'>{score}/100</div><div class='muted'>общая проверка</div></div><div class='card metric'><div class='k'>Подключения сейчас</div><div class='v'>{current}</div><div class='muted'>активных IP: {ips}</div></div><div class='card metric'><div class='k'>Клиенты сегодня</div><div class='v'>{esc(uniq)}</div><div class='muted'>трафик: {esc(human_bytes(traffic))}</div></div><div class='card metric'><div class='k'>WEB Proxy</div><div class='v {'ok' if wp_ready else 'warn'}'>{'Готов' if wp_ready else 'Проверить'}</div><div class='muted'>{esc(wp_host)}</div></div></div>"""
    quick="""<div class='m-section-title'><div><h2>Быстрые действия</h2><p>Самые частые действия — без поиска по меню</p></div></div><div class='m-quick'><a href='/links'><i>↗</i><span><b>Ссылки</b><br><small class='muted'>Подключить Telegram</small></span></a><a href='/active'><i>◉</i><span><b>Активные клиенты</b><br><small class='muted'>Кто подключён сейчас</small></span></a><a href='/sources'><i>＋</i><span><b>Источники</b><br><small class='muted'>Создать отдельную ссылку</small></span></a><a href='/operations'><i>✓</i><span><b>Проверить систему</b><br><small class='muted'>Обновления и состояние</small></span></a></div>"""
    rows=[]
    for u in users[:10]: rows.append([esc(u.get('username','')),'<span class="ok">● работает</span>' if u.get('enabled',True) else '<span class="bad">● выключен</span>',esc(u.get('current_connections',0)),esc(u.get('active_unique_ips',0)),esc(human_bytes(u.get('total_octets',0)))])
    sources=f"""<div class='m-section-title'><div><h2>Источники подключения</h2><p>Краткая сводка по вашим ссылкам</p></div><a href='/sources'>Все источники →</a></div><div class='card'>{table(['Источник','Состояние','Подключения','Активные IP','Трафик'],rows)}</div>"""
    updates_note=("<span class='warn'>доступны обновления: <b>%d</b></span>"%updates) if updates else "<span class='ok'>всё актуально</span>"
    lower=f"""<div class='grid2' style='margin-top:14px'><div class='card'><h2>Сегодня</h2><div class='m-friendly-note'><i>◎</i><div><b>{esc(uniq)} уникальных клиентов</b><br><span class='muted'>Суммарный трафик за день: {esc(human_bytes(traffic))}</span></div></div></div><div class='card'><h2>Обновления</h2><div class='m-friendly-note'><i>↻</i><div><b>{updates_note}</b><br><a href='/operations'>Открыть центр обновлений →</a></div></div></div></div>"""
    return hero+metrics+quick+sources+lower


def _o_update_center(csrf):
    data=_o_update_status(); comps=data.get('components') or {}; rows=[]
    labels=(('mtpadmin','MTPADMIN'),('telemt','TeleMT'),('webproxy','Telegram WEB Proxy'))
    for key,label in labels:
        c=comps.get(key) or {}; cur=c.get('current') or '—'; latest=c.get('latest') or '—'; available=bool(c.get('available'))
        if key=='webproxy': cur=_o_short(cur); latest=_o_short(latest)
        status='<span class="warn"><b>Есть новая версия</b></span>' if available else ('<span class="ok">Актуально</span>' if latest!='—' else '<span class="muted">Нет данных</span>')
        text='Обновить' if available else 'Проверить / переустановить'
        button=f"<form class='inline' method='post' action='/action/component-update/{esc(key)}'><input type='hidden' name='csrf' value='{esc(csrf)}'><button class={'warnbtn' if available else 'secondary'}>{text}</button></form>"
        rows.append([esc(label),esc(cur),esc(latest),status,button])
    checked=data.get('checked_at'); checked_txt=dt.datetime.fromtimestamp(int(checked)).strftime('%d.%m.%Y %H:%M') if checked else 'ещё не выполнялась'
    cs=_o_component_status(); op=''
    if cs:
        st_name=str(cs.get('state') or ''); cls='ok' if st_name=='success' else ('bad' if st_name=='failed' else 'warn'); human={'success':'успешно','failed':'ошибка','running':'выполняется','queued':'в очереди'}.get(st_name,st_name)
        op=f"<div class='m-friendly-note' style='margin-top:12px'><i>↻</i><div>Последняя операция: <span class='{cls}'><b>{esc(human)}</b></span><br><span class='muted'>{esc(cs.get('detail',''))}</span></div></div>"
    checkform=f"<form class='inline' method='post' action='/action/update-check'><input type='hidden' name='csrf' value='{esc(csrf)}'><button class='secondary'>Проверить обновления</button></form>"
    return f"<div class='card'><div class='a-head'><div><h2>Центр обновлений</h2><div class='muted'>Последняя проверка: {esc(checked_txt)}</div></div>{checkform}</div>{table(['Компонент','Установлено','Новая версия','Состояние','Действие'],rows)}{op}<div class='muted' style='margin-top:10px'>Обновления выполняются в фоне. Вкладку браузера можно закрыть — работа на сервере продолжится.</div></div>"


def _o_webproxy_card(csrf):
    st=_o_state(); host=st.get('WEBPROXY_HOST',''); source=st.get('WEBPROXY_SOURCE','WEB_PROXY'); link=_o_webproxy_link(); ready=st.get('WEBPROXY_READY','0')=='1' and _o_service('tproxy-server.service') and _o_http_ok('http://127.0.0.1:8081/readyz'); qr=_o_qr(link); status='<span class="ok">● Готов к работе</span>' if ready else '<span class="warn">● Требуется проверка</span>'
    linkbox=f"<div class='linkbox' id='webproxy-link'>{esc(link)}</div><button class='secondary' onclick=\"copyText('webproxy-link')\">Копировать ссылку</button>" if link else "<div class='muted'>Ссылка пока не сформирована.</div>"
    form=f"""<form method='post' action='/action/webproxy-host'><input type='hidden' name='csrf' value='{esc(csrf)}'><label>Домен WEB Proxy</label><div class='actions'><input name='host' required autocomplete='off' autocapitalize='off' spellcheck='false' style='min-width:min(420px,100%)' value='{esc(host)}' placeholder='webproxy.example.com'><button>Сохранить</button></div><div class='muted' style='margin-top:6px'>DNS-запись этого домена должна указывать на ваш сервер.</div></form>"""
    tech=f"""<details class='ui-details m-tech-details'><summary>Для специалистов</summary><div class='ui-details-body'><div class='muted'>Источник: {esc(source)} · HTTPS 443 · локальная серверная часть WEB Proxy.</div></div></details>"""
    return f"""<div class='card'><div class='a-head'><div><h2>Telegram WEB Proxy</h2><div>{status}</div></div>{qr}</div>{form}<div style='margin-top:13px'>{linkbox}</div>{tech}</div>"""


def _o_operations_html(user,csrf):
    score,checks=_o_health(); st=_o_state(); current=st.get('MTPADMIN_VERSION',VERSION); updates=int((_o_update_status().get('updates') or 0)); wp_ready=st.get('WEBPROXY_READY','0')=='1' and _o_service('tproxy-server.service') and _o_http_ok('http://127.0.0.1:8081/readyz')
    metrics=f"""<div class='grid'><div class='card metric'><div class='k'>Состояние сервиса</div><div class='v {'ok' if score>=90 else 'warn'}'>{score}/100</div><div class='muted'>{'всё работает' if score>=90 else 'нужна проверка'}</div></div><div class='card metric'><div class='k'>Версия MTPADMIN</div><div class='v'>{esc(current)}</div><div class='muted'>установлена сейчас</div></div><div class='card metric'><div class='k'>WEB Proxy</div><div class='v {'ok' if wp_ready else 'warn'}'>{'Готов' if wp_ready else 'Проверить'}</div><div class='muted'>{esc(st.get('WEBPROXY_HOST','не настроен'))}</div></div><div class='card metric'><div class='k'>Обновления</div><div class='v {'warn' if updates else 'ok'}'>{updates}</div><div class='muted'>{'доступно' if updates else 'всё актуально'}</div></div></div>"""
    tabs="""<div class='ui-tabs' data-ui-tabs><button type='button' data-ui-tab='updates'>Обновления</button><button type='button' data-ui-tab='webproxy'>WEB Proxy</button><button type='button' data-ui-tab='advanced'>Для специалистов</button></div>"""
    updates_p=f"<div class='ui-pane active' data-ui-pane='updates'>{_o_update_center(csrf)}</div>"; web_p=f"<div class='ui-pane' data-ui-pane='webproxy'>{_o_webproxy_card(csrf)}</div>"; advanced=f"""<div class='ui-pane' data-ui-pane='advanced'><div class='grid2'><div class='card'><h2>Проверки служб</h2>{table(['Компонент','Состояние'],checks)}</div><div class='card'><h2>Резервные копии</h2>{_o_backups()}</div></div><div class='card' style='margin-top:14px'><h2>Scanner Guard</h2><div class='muted' style='margin-bottom:10px'>Автоматическая блокировка выключена. Ниже — служебная оценка возможных порогов.</div>{_o_learning()}</div></div>"""
    return metrics+"<div class='m-section-title'><div><h2>Управление сервисом</h2><p>Обновления и WEB Proxy — в простом виде. Технические сведения спрятаны отдельно.</p></div></div>"+tabs+updates_p+web_p+advanced
