# MTPADMIN 0.11.11 online-history extension.
# Adds WEB Proxy relay sessions/bytes and active client IPs alongside TeleMT.
# WEB client IPs come from the loopback-only patched tproxy admin endpoint;
# raw IP retention remains governed by the same MTPADMIN retention policy.

_ONLINE_SAMPLE_SECONDS = 30
_TPROXY_METRICS = 'http://127.0.0.1:8081/metrics'
_TPROXY_CLIENTS = 'http://127.0.0.1:8081/mtpadmin/clients'
_online_last_sample = 0


_base_connect = connect
def connect():
    con = _base_connect()
    con.executescript('''
    CREATE TABLE IF NOT EXISTS online_samples(
      ts INTEGER NOT NULL,
      username TEXT NOT NULL,
      connections INTEGER NOT NULL DEFAULT 0,
      unique_ips INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(ts,username)
    );
    CREATE INDEX IF NOT EXISTS idx_online_samples_ts ON online_samples(ts);
    ''')
    con.commit()
    return con


def _tproxy_metrics():
    try:
        req = urllib.request.Request(_TPROXY_METRICS, headers={'Accept':'text/plain'})
        with urllib.request.urlopen(req, timeout=1.5) as r:
            text = r.read().decode('utf-8','replace')
        out = {}
        for line in text.splitlines():
            if not line or line.startswith('#') or ' ' not in line:
                continue
            name, raw = line.split(None, 1)
            if not name.startswith('tproxy_'):
                continue
            try:
                out[name] = int(float(raw.strip()))
            except (TypeError, ValueError):
                continue
        return out
    except Exception:
        return {}


def _tproxy_client_rows():
    try:
        req = urllib.request.Request(_TPROXY_CLIENTS, headers={'Accept':'application/json'})
        with urllib.request.urlopen(req, timeout=1.5) as r:
            obj = json.loads(r.read().decode('utf-8','replace'))
        rows = obj.get('clients') if isinstance(obj,dict) else None
        if not isinstance(rows,list):
            return []
        out=[]
        for row in rows:
            if not isinstance(row,dict):
                continue
            try:
                ip=str(ipaddress.ip_address(str(row.get('ip') or '')))
                sessions=int(row.get('sessions') or 0)
            except (ValueError,TypeError):
                continue
            if sessions > 0:
                out.append({'ip':ip,'sessions':sessions})
        return out
    except Exception:
        return []


# Merge WEB relay clients into the collector's proven active-pair path. This
# makes existing GeoIP, first/last seen, anonymous history and retention logic
# work identically for TeleMT and WEB_PROXY without a second database path.
_base_active_pairs = active_pairs
def active_pairs():
    out=set(_base_active_pairs())
    st=state(); web_source=str(st.get('WEBPROXY_SOURCE','WEB_PROXY') or 'WEB_PROXY')
    for row in _tproxy_client_rows():
        out.add((web_source,row['ip']))
    return out


def _sample_online(con, users_metrics, active, now, web_metrics=None, web_source='WEB_PROXY'):
    global _online_last_sample
    if now - _online_last_sample < _ONLINE_SAMPLE_SECONDS:
        return
    bucket = now - (now % _ONLINE_SAMPLE_SECONDS)
    active_by_user = {}
    for user, ip in active:
        active_by_user.setdefault(str(user), set()).add(str(ip))
    total_connections = 0
    all_ips = set()
    names = set(users_metrics) | set(active_by_user)
    for user in names:
        metrics = users_metrics.get(user, {})
        live = int(metrics.get('telemt_user_connections_current', 0) or 0)
        uniq = int(metrics.get('telemt_user_unique_ips_current', 0) or 0)
        if not uniq:
            uniq = len(active_by_user.get(user, ()))
        total_connections += live
        all_ips.update(active_by_user.get(user, ()))
        con.execute('''INSERT INTO online_samples(ts,username,connections,unique_ips)
                       VALUES(?,?,?,?) ON CONFLICT(ts,username) DO UPDATE SET
                       connections=excluded.connections,unique_ips=excluded.unique_ips''',
                    (bucket, user, live, uniq))

    # WEB traffic bypasses TeleMT. Sessions come from relay metrics while
    # unique IPs come from the loopback telemetry endpoint.
    if web_metrics:
        web_live = int(web_metrics.get('tproxy_sessions_live', 0) or 0)
        web_unique = len(active_by_user.get(web_source, ()))
        total_connections += web_live
        con.execute('''INSERT INTO online_samples(ts,username,connections,unique_ips)
                       VALUES(?,?,?,?) ON CONFLICT(ts,username) DO UPDATE SET
                       connections=excluded.connections,unique_ips=excluded.unique_ips''',
                    (bucket, web_source, web_live, web_unique))

    con.execute('''INSERT INTO online_samples(ts,username,connections,unique_ips)
                   VALUES(?,?,?,?) ON CONFLICT(ts,username) DO UPDATE SET
                   connections=excluded.connections,unique_ips=excluded.unique_ips''',
                (bucket, '__GLOBAL__', total_connections, len(all_ips)))
    _online_last_sample = now


def _sample_web_traffic(con, metrics, web_source, now, web_unique=0):
    if not metrics:
        return
    day = dt.datetime.now().date().isoformat()
    cur_conn = int(metrics.get('tproxy_sessions_created_total', 0) or 0)
    cur_from = int(metrics.get('tproxy_bytes_up_total', 0) or 0)
    cur_to = int(metrics.get('tproxy_bytes_down_total', 0) or 0)
    live = int(metrics.get('tproxy_sessions_live', 0) or 0)
    state_key = '__WEB_COUNTER__:' + str(web_source)
    prev = con.execute('SELECT conn_total,bytes_from,bytes_to FROM counter_state WHERE username=?',(state_key,)).fetchone()
    if prev is None:
        dc = df = dtb = 0
    else:
        dc = delta(cur_conn, prev[0])
        df = delta(cur_from, prev[1])
        dtb = delta(cur_to, prev[2])
    con.execute('''INSERT INTO daily_traffic(day,username,connections,bad_connections,bytes_from_client,bytes_to_client,peak_connections,peak_unique_ips)
                   VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(day,username) DO UPDATE SET
                   connections=connections+excluded.connections,
                   bytes_from_client=bytes_from_client+excluded.bytes_from_client,
                   bytes_to_client=bytes_to_client+excluded.bytes_to_client,
                   peak_connections=max(peak_connections,excluded.peak_connections),
                   peak_unique_ips=max(peak_unique_ips,excluded.peak_unique_ips)''',
                (day, web_source, dc, 0, df, dtb, live, int(web_unique or 0)))
    con.execute('''INSERT INTO counter_state(username,conn_total,bad_total,bytes_from,bytes_to,updated_at)
                   VALUES(?,?,?,?,?,?) ON CONFLICT(username) DO UPDATE SET
                   conn_total=excluded.conn_total,bytes_from=excluded.bytes_from,
                   bytes_to=excluded.bytes_to,updated_at=excluded.updated_at''',
                (state_key, cur_conn, 0, cur_from, cur_to, now))
    con.commit()


_base_sample_counters = sample_counters
def sample_counters(con, active):
    text = fetch_metrics()
    _g, users_metrics = parse_metrics(text)
    now = int(time.time())
    st = state()
    web_source = str(st.get('WEBPROXY_SOURCE','WEB_PROXY') or 'WEB_PROXY')
    web_metrics = _tproxy_metrics()
    web_unique = len({ip for user,ip in active if str(user)==web_source})
    _sample_online(con, users_metrics, active, now, web_metrics, web_source)
    # Preserve proven TeleMT traffic/counter logic exactly as before.
    result = _base_sample_counters(con, active)
    _sample_web_traffic(con, web_metrics, web_source, now, web_unique)
    return result


_base_cleanup = cleanup
def cleanup(con):
    _base_cleanup(con)
    # High-resolution online history is operational telemetry, not long-term client history.
    # Keep 31 days; daily aggregates remain available for longer periods.
    cutoff = int(time.time()) - 31 * 86400
    con.execute('DELETE FROM online_samples WHERE ts < ?', (cutoff,))
    con.commit()
