# MTPADMIN 0.9.0 online-history extension.
# Injected before collector main() so it can wrap connect/sample_counters/cleanup.

_ONLINE_SAMPLE_SECONDS = 30
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


def _sample_online(con, users_metrics, active, now):
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
    con.execute('''INSERT INTO online_samples(ts,username,connections,unique_ips)
                   VALUES(?,?,?,?) ON CONFLICT(ts,username) DO UPDATE SET
                   connections=excluded.connections,unique_ips=excluded.unique_ips''',
                (bucket, '__GLOBAL__', total_connections, len(all_ips)))
    _online_last_sample = now


_base_sample_counters = sample_counters
def sample_counters(con, active):
    text = fetch_metrics()
    _g, users_metrics = parse_metrics(text)
    now = int(time.time())
    _sample_online(con, users_metrics, active, now)
    # Preserve the proven traffic/counter logic exactly as before.
    # It fetches metrics again; this is only every 10s and keeps the extension low-risk.
    return _base_sample_counters(con, active)


_base_cleanup = cleanup
def cleanup(con):
    _base_cleanup(con)
    # High-resolution online history is operational telemetry, not long-term client history.
    # Keep 31 days; daily aggregates remain available for longer periods.
    cutoff = int(time.time()) - 31 * 86400
    con.execute('DELETE FROM online_samples WHERE ts < ?', (cutoff,))
    con.commit()
