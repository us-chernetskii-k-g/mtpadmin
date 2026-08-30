        for raw in raws:
            try: ip=str(ipaddress.ip_address(str(raw)))
            except ValueError: continue
            if u: out.add((u,ip))
    return out


def upsert_pair(con,salt,user,ip,count_hit):
    now=int(time.time()); day=dt.datetime.now().date().isoformat(); ih=anon_hash(salt,ip)
    row=con.execute('SELECT country_code,country_name,region,city,asn,org FROM clients WHERE ip=?',(ip,)).fetchone()
    if row is None:
        cc,cn,region,city,asn,org=geo(ip)
        con.execute('INSERT INTO clients(ip,first_seen,last_seen,hits,country_code,country_name,region,city,asn,org) VALUES(?,?,?,?,?,?,?,?,?,?)',
                    (ip,now,now,1 if count_hit else 0,cc,cn,region,city,asn,org))
    else:
        cc,cn,region,city,asn,org=(row[0] or '??',row[1] or 'Unknown',row[2] or '',row[3] or '',row[4] or '',row[5] or '')
        if os.path.exists(CITY_DB) or os.path.exists(ASN_DB) or cc in ('??','') or not asn:
            ncc,ncn,nregion,ncity,nasn,norg=geo(ip)
            if os.path.exists(CITY_DB) and ncc not in ('??',''):
                cc,cn=ncc,ncn
                region=nregion or ''
                city=ncity or ''
            elif cc in ('??','') and ncc not in ('??',''):
                cc,cn=ncc,ncn
            if os.path.exists(ASN_DB) and nasn:
                asn,org=nasn,norg
            elif not asn and nasn:
                asn,org=nasn,norg
        con.execute('UPDATE clients SET last_seen=?,hits=hits+?,country_code=?,country_name=?,region=?,city=?,asn=?,org=? WHERE ip=?',
                    (now,1 if count_hit else 0,cc,cn,region,city,asn,org,ip))

    existed=con.execute('SELECT 1 FROM visits WHERE day=? AND ip=?',(day,ip)).fetchone() is not None
    if existed:
        if count_hit: con.execute('UPDATE visits SET hits=hits+1 WHERE day=? AND ip=?',(day,ip))
    else:
        con.execute('INSERT INTO visits(day,ip,hits) VALUES(?,?,?)',(day,ip,1 if count_hit else 0))
        con.execute('INSERT INTO daily_total(day,unique_ips,hits) VALUES(?,1,?) ON CONFLICT(day) DO UPDATE SET unique_ips=unique_ips+1,hits=hits+excluded.hits',(day,1 if count_hit else 0))
        con.execute('INSERT INTO daily_country(day,country_code,country_name,unique_ips,hits) VALUES(?,?,?,?,?) ON CONFLICT(day,country_code,country_name) DO UPDATE SET unique_ips=unique_ips+1,hits=hits+excluded.hits',(day,cc,cn,1,1 if count_hit else 0))
    if existed and count_hit:
        con.execute('UPDATE daily_total SET hits=hits+1 WHERE day=?',(day,))
        con.execute('UPDATE daily_country SET hits=hits+1 WHERE day=? AND country_code=? AND country_name=?',(day,cc,cn))

    uv=con.execute('SELECT 1 FROM user_visits WHERE day=? AND username=? AND ip=?',(day,user,ip)).fetchone()
    if uv:
        con.execute('UPDATE user_visits SET last_seen=?,observations=observations+? WHERE day=? AND username=? AND ip=?',(now,1 if count_hit else 0,day,user,ip))
    else:
        con.execute('INSERT INTO user_visits(day,username,ip,first_seen,last_seen,observations) VALUES(?,?,?,?,?,?)',(day,user,ip,now,now,1 if count_hit else 0))

    av=con.execute('SELECT 1 FROM anon_visits WHERE day=? AND username=? AND ip_hash=?',(day,user,ih)).fetchone()
    if av:
        con.execute('UPDATE anon_visits SET last_seen=?,observations=observations+?,country_code=?,country_name=?,region=?,city=?,asn=?,org=? WHERE day=? AND username=? AND ip_hash=?',
                    (now,1 if count_hit else 0,cc,cn,region,city,asn,org,day,user,ih))
    else:
        con.execute('INSERT INTO anon_visits(day,username,ip_hash,country_code,country_name,region,city,asn,org,first_seen,last_seen,observations) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)',
                    (day,user,ih,cc,cn,region,city,asn,org,now,now,1 if count_hit else 0))
    con.commit()


def reenrich_existing(con, salt):
    if not (os.path.exists(CITY_DB) or os.path.exists(ASN_DB)):
        return 0
    rows=con.execute('SELECT ip FROM clients').fetchall()
    changed=0
    for (ip,) in rows:
        try:
            cc,cn,region,city,asn,org=geo(ip)
            if cc in ('??','') and not asn and not city:
                continue
            con.execute('UPDATE clients SET country_code=?,country_name=?,region=?,city=?,asn=?,org=? WHERE ip=?',(cc,cn,region,city,asn,org,ip))
            ih=anon_hash(salt,ip)
            con.execute('UPDATE anon_visits SET country_code=?,country_name=?,region=?,city=?,asn=?,org=? WHERE ip_hash=?',(cc,cn,region,city,asn,org,ih))
            changed += 1
        except Exception as e:
            print(f'geo re-enrich warning for {ip}: {e}', file=sys.stderr, flush=True)
    con.execute("INSERT INTO collector_meta(key,value) VALUES('geo_reenriched_at',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(str(int(time.time())),))
    con.commit(); return changed


def fetch_metrics():
    req=urllib.request.Request(METRICS)
    with urllib.request.urlopen(req,timeout=2.5) as r: return r.read().decode('utf-8','replace')


def parse_metrics(text):
    glob={}; users={}
    for line in text.splitlines():
        if not line or line.startswith('#'): continue
        try: lhs,val=line.rsplit(None,1); value=float(val)
        except ValueError: continue
        if '{' in lhs:
            name,labels=lhs.split('{',1); labels=labels.rstrip('}')
            m=re.search(r'user="([^"]+)"',labels)
            if m: users.setdefault(m.group(1),{})[name]=value
        else: glob[lhs]=value
    return glob,users


def delta(cur,prev):
    cur=int(cur or 0); prev=int(prev or 0); return cur-prev if cur>=prev else cur


def sample_counters(con, active):
    text=fetch_metrics(); g,us=parse_metrics(text); now=int(time.time()); day=dt.datetime.now().date().isoformat()
    uptime=int(g.get('telemt_uptime_seconds',0)); started_today=dt.datetime.fromtimestamp(max(0,now-uptime)).date()==dt.datetime.now().date()
    total_current=0; distinct_active=len({ip for _,ip in active})
    for user,m in us.items():
        if 'telemt_user_connections_total' not in m and 'telemt_user_octets_from_client_total' not in m: continue
        cur_conn=int(m.get('telemt_user_connections_total',0)); cur_from=int(m.get('telemt_user_octets_from_client_total',0)); cur_to=int(m.get('telemt_user_octets_to_client_total',0))
        live=int(m.get('telemt_user_connections_current',0)); uniq=int(m.get('telemt_user_unique_ips_current',0)); total_current+=live
        prev=con.execute('SELECT conn_total,bytes_from,bytes_to FROM counter_state WHERE username=?',(user,)).fetchone()
        if prev is None:
            dc=cur_conn if started_today else 0; df=cur_from if started_today else 0; dtb=cur_to if started_today else 0
        else:
            dc=delta(cur_conn,prev[0]); df=delta(cur_from,prev[1]); dtb=delta(cur_to,prev[2])
        con.execute('''INSERT INTO daily_traffic(day,username,connections,bad_connections,bytes_from_client,bytes_to_client,peak_connections,peak_unique_ips)
                       VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(day,username) DO UPDATE SET
                       connections=connections+excluded.connections,bytes_from_client=bytes_from_client+excluded.bytes_from_client,
                       bytes_to_client=bytes_to_client+excluded.bytes_to_client,
                       peak_connections=max(peak_connections,excluded.peak_connections),peak_unique_ips=max(peak_unique_ips,excluded.peak_unique_ips)''',
                    (day,user,dc,0,df,dtb,live,uniq))
        con.execute('INSERT INTO counter_state(username,conn_total,bad_total,bytes_from,bytes_to,updated_at) VALUES(?,?,?,?,?,?) ON CONFLICT(username) DO UPDATE SET conn_total=excluded.conn_total,bytes_from=excluded.bytes_from,bytes_to=excluded.bytes_to,updated_at=excluded.updated_at',(user,cur_conn,0,cur_from,cur_to,now))
    gc=int(g.get('telemt_connections_total',0)); gb=int(g.get('telemt_connections_bad_total',0))
    prev=con.execute("SELECT conn_total,bad_total FROM counter_state WHERE username='__GLOBAL__'").fetchone()
    if prev is None: dc=gc if started_today else 0; db=gb if started_today else 0
    else: dc=delta(gc,prev[0]); db=delta(gb,prev[1])
    con.execute('''INSERT INTO daily_traffic(day,username,connections,bad_connections,bytes_from_client,bytes_to_client,peak_connections,peak_unique_ips)
                   VALUES(?,?,?,?,0,0,?,?) ON CONFLICT(day,username) DO UPDATE SET
                   connections=connections+excluded.connections,bad_connections=bad_connections+excluded.bad_connections,
                   peak_connections=max(peak_connections,excluded.peak_connections),peak_unique_ips=max(peak_unique_ips,excluded.peak_unique_ips)''',
                (day,'__GLOBAL__',dc,db,total_current,distinct_active))
    con.execute("INSERT INTO counter_state(username,conn_total,bad_total,bytes_from,bytes_to,updated_at) VALUES('__GLOBAL__',?,?,?,?,?) ON CONFLICT(username) DO UPDATE SET conn_total=excluded.conn_total,bad_total=excluded.bad_total,updated_at=excluded.updated_at",(gc,gb,0,0,now))
    con.execute("INSERT INTO collector_meta(key,value) VALUES('heartbeat',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(str(now),))
    con.execute("INSERT INTO collector_meta(key,value) VALUES('traffic_started_at',?) ON CONFLICT(key) DO NOTHING",(str(now),))
    con.commit()


def cleanup(con):
    st=state(); raw=max(1,min(365,int(st.get('RETENTION_DAYS','7') or '7'))); anon=max(raw,min(3650,int(st.get('ANON_RETENTION_DAYS','400') or '400')))
    cutoff=int(time.time())-raw*86400; day_cut=(dt.datetime.now()-dt.timedelta(days=raw)).date().isoformat(); anon_cut=(dt.datetime.now()-dt.timedelta(days=anon)).date().isoformat()
    con.execute('DELETE FROM clients WHERE last_seen < ?',(cutoff,)); con.execute('DELETE FROM visits WHERE day < ?',(day_cut,)); con.execute('DELETE FROM user_visits WHERE day < ?',(day_cut,)); con.execute('DELETE FROM anon_visits WHERE day < ?',(anon_cut,)); con.commit()


def main():
    import signal
    reload_requested=False
    def request_reload(*_):
        nonlocal reload_requested
        reload_requested=True
    signal.signal(signal.SIGHUP,request_reload)

    con=connect(); salt=get_salt(); cleanup(con)
    enriched=reenrich_existing(con,salt)
    hot=os.environ.pop('MTPADMIN_HOT_RELOAD','')=='1'
    if hot:
        try: prev_active=active_pairs()
        except Exception: prev_active=set()
    else:
        prev_active=set()
    last_metrics=0.; last_cleanup=0.; last_error=0.
    print(f'MTPADMIN collector 0.7.0: API + traffic + local city/ASN GeoIP; re-enriched={enriched}',flush=True)
    while True:
        try:
            active=active_pairs()
            for pair in active: upsert_pair(con,salt,pair[0],pair[1],pair not in prev_active)
            for pair in recent_pairs():
                if pair not in active: upsert_pair(con,salt,pair[0],pair[1],False)
            prev_active=active
            if time.time()-last_metrics>=POLL_METRICS:
                sample_counters(con,active); last_metrics=time.time()
            else:
                con.execute("INSERT INTO collector_meta(key,value) VALUES('heartbeat',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(str(int(time.time())),)); con.commit()
        except Exception as e:
            if time.time()-last_error>=60:
                print(f'collector warning: {e}',file=sys.stderr,flush=True); last_error=time.time()
        if time.time()-last_cleanup>=3600: cleanup(con); last_cleanup=time.time()
        if reload_requested:
            try: con.commit(); con.close()
            except Exception: pass
            os.environ['MTPADMIN_HOT_RELOAD']='1'
            os.execv(sys.executable,[sys.executable,str(Path(__file__).resolve())])
        time.sleep(POLL_IP)

if __name__=='__main__': raise SystemExit(main() or 0)
