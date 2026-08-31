# MTPADMIN 0.11.10 WEB Proxy live-activity layer.
# tproxy-server is outside TeleMT, so its sessions cannot appear in /v1/users.
# Merge relay metrics into WEB_PROXY without inventing client IP data.

_WPA_METRICS_URL = 'http://127.0.0.1:8081/metrics'
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


_wpa_source_rows = source_rows

def source_rows():
    rows = [dict(x) for x in _wpa_source_rows()]
    st = state()
    websrc = str(st.get('WEBPROXY_SOURCE','WEB_PROXY') or 'WEB_PROXY')
    metrics = _wpa_metrics()
    if not metrics:
        return rows
    sessions = int(metrics.get('tproxy_sessions_live',0) or 0)
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
        # One tproxy carrier session is the closest WEB equivalent to one live
        # client connection. The upstream metrics endpoint intentionally does
        # not export client IPs, so active_unique_ips remains TeleMT-only.
        row['current_connections'] = sessions
        break
    return rows


_wpa_active_clients_html = active_clients_html

def active_clients_html():
    body = _wpa_active_clients_html()
    m = _wpa_metrics()
    if not m:
        return body
    sessions = int(m.get('tproxy_sessions_live',0) or 0)
    streams = int(m.get('tproxy_streams_live',0) or 0)
    opened = int(m.get('tproxy_streams_opened_total',0) or 0)
    up = int(m.get('tproxy_bytes_up_total',0) or 0)
    down = int(m.get('tproxy_bytes_down_total',0) or 0)
    failures = int(m.get('tproxy_backend_dial_failures_total',0) or 0)
    limits = int(m.get('tproxy_limit_hits_total',0) or 0)
    cls = 'ok' if sessions > 0 else 'muted'
    card = f"""<div class='card' style='margin-bottom:14px'>
<h2>WEB Proxy · сейчас</h2>
<div class='grid'>
<div class='card metric'><div class='k'>WEB-сессии</div><div class='v {cls}'>{sessions}</div><div class='muted'>tproxy carrier sessions</div></div>
<div class='card metric'><div class='k'>Потоки</div><div class='v'>{streams}</div><div class='muted'>открыто всего: {opened}</div></div>
<div class='card metric'><div class='k'>WEB → Telegram</div><div class='v' style='font-size:20px'>{esc(human_bytes(up))}</div><div class='muted'>текущий процесс relay</div></div>
<div class='card metric'><div class='k'>Telegram → WEB</div><div class='v' style='font-size:20px'>{esc(human_bytes(down))}</div><div class='muted'>ошибки backend: {failures} · limits: {limits}</div></div>
</div>
<div class='muted' style='margin-top:10px'>IP WEB-клиента здесь не показывается: текущий tproxy-server экспортирует агрегированные sessions/streams/bytes, но не список клиентских IP. Обычные MTProto-клиенты ниже по-прежнему берутся из TeleMT.</div>
</div>"""
    return card + body
