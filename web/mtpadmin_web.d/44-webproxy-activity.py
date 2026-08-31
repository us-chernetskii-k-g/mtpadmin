# MTPADMIN 0.11.11 WEB Proxy live-activity layer.
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
        out.sort(key=lambda x:ipaddress.ip_address(x['ip']))
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
    note="""<div class='card' style='margin-top:14px'><h2>Активные клиенты сейчас</h2><div class='muted'>Обычные MTProto-клиенты берутся из live API TeleMT, WEB-клиенты — из loopback-only telemetry tproxy-server. WEB endpoint отдаёт только IP и число активных carrier-сессий; capability, secret и URL запросов не журналируются. История IP хранится по общему retention MTPADMIN.</div></div>"""
    body=table(['','Источник','IP','CC','Город','ASN','Провайдер / сеть','Соед. источника','Первый','Последний','Guard'],rows)
    return cards+note+"<div class='card' style='margin-top:14px'>"+body+"</div>"
