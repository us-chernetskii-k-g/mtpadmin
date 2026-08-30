#!/usr/bin/env python3
"""MTPADMIN collector 0.4.3: IP history + local city/ASN GeoIP + privacy aggregates + traffic."""
import datetime as dt
import hashlib, hmac, ipaddress, json, os, re, sqlite3, subprocess, sys, time
import urllib.error, urllib.request
from pathlib import Path

DB='/var/lib/mtpadmin/stats.db'
STATE='/etc/mtpadmin/state.env'
SALT_FILE='/etc/mtpadmin/stats_salt'
API='http://127.0.0.1:9091'
METRICS='http://127.0.0.1:9090/metrics'
POLL_IP=3
POLL_METRICS=10
GEO_DIR='/var/lib/mtpadmin/geo'
CITY_DB=GEO_DIR+'/dbip-city-lite.mmdb'
ASN_DB=GEO_DIR+'/dbip-asn-lite.mmdb'


def state():
    out={}
    try:
        for line in open(STATE,encoding='utf-8'):
            line=line.strip()
            if not line or '=' not in line: continue
            k,v=line.split('=',1)
            if len(v)>=2 and v[0]==v[-1]=="'": v=v[1:-1]
            out[k]=v
    except OSError: pass
    return out


def which(name):
    for d in os.environ.get('PATH','/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin').split(os.pathsep):
        p=os.path.join(d,name)
        if os.path.isfile(p) and os.access(p,os.X_OK): return p
    return None


def ensure_column(con, table, col, decl):
    cols={r[1] for r in con.execute(f'PRAGMA table_info({table})')}
    if col not in cols: con.execute(f'ALTER TABLE {table} ADD COLUMN {col} {decl}')


def connect():
    os.makedirs(os.path.dirname(DB),exist_ok=True)
    con=sqlite3.connect(DB,timeout=30)
    con.execute('PRAGMA journal_mode=WAL'); con.execute('PRAGMA synchronous=NORMAL')
    con.executescript('''
    CREATE TABLE IF NOT EXISTS clients(
      ip TEXT PRIMARY KEY, first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL,
      hits INTEGER NOT NULL DEFAULT 1, country_code TEXT, country_name TEXT
    );
    CREATE TABLE IF NOT EXISTS visits(day TEXT NOT NULL, ip TEXT NOT NULL, hits INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(day,ip));
    CREATE TABLE IF NOT EXISTS user_visits(
      day TEXT NOT NULL, username TEXT NOT NULL, ip TEXT NOT NULL,
      first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, observations INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY(day,username,ip)
    );
    CREATE TABLE IF NOT EXISTS daily_total(day TEXT PRIMARY KEY, unique_ips INTEGER NOT NULL DEFAULT 0, hits INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS daily_country(
      day TEXT NOT NULL, country_code TEXT NOT NULL, country_name TEXT NOT NULL,
      unique_ips INTEGER NOT NULL DEFAULT 0, hits INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(day,country_code,country_name)
    );
    CREATE TABLE IF NOT EXISTS anon_visits(
      day TEXT NOT NULL, username TEXT NOT NULL, ip_hash TEXT NOT NULL,
      country_code TEXT, country_name TEXT, region TEXT, city TEXT, asn TEXT, org TEXT,
      first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL, observations INTEGER NOT NULL DEFAULT 1,
      PRIMARY KEY(day,username,ip_hash)
    );
    CREATE TABLE IF NOT EXISTS daily_traffic(
      day TEXT NOT NULL, username TEXT NOT NULL,
      connections INTEGER NOT NULL DEFAULT 0, bad_connections INTEGER NOT NULL DEFAULT 0,
      bytes_from_client INTEGER NOT NULL DEFAULT 0, bytes_to_client INTEGER NOT NULL DEFAULT 0,
      peak_connections INTEGER NOT NULL DEFAULT 0, peak_unique_ips INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(day,username)
    );
    CREATE TABLE IF NOT EXISTS counter_state(
      username TEXT PRIMARY KEY, conn_total INTEGER NOT NULL DEFAULT 0,
      bad_total INTEGER NOT NULL DEFAULT 0, bytes_from INTEGER NOT NULL DEFAULT 0,
      bytes_to INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS collector_meta(key TEXT PRIMARY KEY, value TEXT);
    ''')
    ensure_column(con,'clients','asn','TEXT'); ensure_column(con,'clients','org','TEXT'); ensure_column(con,'clients','region','TEXT'); ensure_column(con,'clients','city','TEXT'); ensure_column(con,'anon_visits','region','TEXT'); ensure_column(con,'anon_visits','city','TEXT')
    con.commit(); return con


def get_salt():
    p=Path(SALT_FILE)
    if not p.exists():
        p.write_bytes(os.urandom(32)); os.chmod(p,0o600)
    return p.read_bytes()


def anon_hash(salt, ip): return hmac.new(salt,ip.encode(),hashlib.sha256).hexdigest()


def _name(names):
    if not isinstance(names,dict): return ''
    return str(names.get('ru') or names.get('en') or next(iter(names.values()), '') or '')


def _mmdb(path, ip):
    if not os.path.exists(path): return {}
    try:
        import maxminddb
        with maxminddb.open_database(path) as r:
            return r.get(ip) or {}
    except Exception:
        return {}


def country_lookup(ip):
    try:
        obj=ipaddress.ip_address(ip)
        if not obj.is_global: return '--','Private/Reserved'
    except ValueError: return '??','Unknown'

    rec=_mmdb(CITY_DB,ip)
    if rec:
        c=rec.get('country') or {}
        cc=str(c.get('iso_code') or '??')
        cn=_name(c.get('names') or {}) or 'Unknown'
        return cc,cn

    cmd='geoiplookup6' if ':' in ip and which('geoiplookup6') else 'geoiplookup'
    if not which(cmd): return '??','Unknown'
    try:
        p=subprocess.run([cmd,ip],capture_output=True,text=True,timeout=3)
        m=re.search(r':\s*([A-Z]{2}),\s*(.+)$',(p.stdout or '').strip())
        if m: return m.group(1),m.group(2).strip()
    except Exception: pass
    return '??','Unknown'


def city_lookup(ip):
    rec=_mmdb(CITY_DB,ip)
    if not rec: return '', ''
    region=''
    subdivisions=rec.get('subdivisions') or []
    if subdivisions and isinstance(subdivisions[0],dict):
        region=_name(subdivisions[0].get('names') or {})
    city=_name((rec.get('city') or {}).get('names') or {})
    return region,city


def asn_lookup(ip):
    rec=_mmdb(ASN_DB,ip)
    if rec:
        traits=rec.get('traits') or {}
        nested=rec.get('autonomous_system') or {}
        n=(rec.get('autonomous_system_number')
           or rec.get('as_number')
           or rec.get('asn')
           or traits.get('autonomous_system_number')
           or nested.get('number'))
        org=(rec.get('autonomous_system_organization')
             or rec.get('as_organization')
             or traits.get('autonomous_system_organization')
             or nested.get('organization')
             or '')
        if n:
            s=str(n)
            if s.upper().startswith('AS'):
                asn=s.upper()
            else:
                try: asn=f'AS{int(n)}'
                except Exception: asn='AS'+s
            return asn,str(org)

    candidates=[]
    if ':' in ip: candidates += ['/usr/share/GeoIP/GeoIPASNumv6.dat']
    candidates += ['/usr/share/GeoIP/GeoIPASNum.dat']
    exe=which('geoiplookup')
    if not exe: return '', ''
    for db in candidates:
        if not os.path.exists(db): continue
        try:
            p=subprocess.run([exe,'-f',db,ip],capture_output=True,text=True,timeout=3)
            text=(p.stdout or '').strip()
            m=re.search(r':\s*(AS\d+)\s*(.*)$',text)
            if m: return m.group(1),m.group(2).strip()
        except Exception: pass
    return '', ''


def geo(ip):
    cc,cn=country_lookup(ip)
    region,city=city_lookup(ip)
    asn,org=asn_lookup(ip)
    return cc,cn,region,city,asn,org

def api_json(path):
    req=urllib.request.Request(API+path,headers={'Accept':'application/json'})
    with urllib.request.urlopen(req,timeout=2.5) as r: body=json.loads(r.read().decode('utf-8','replace'))
    if not isinstance(body,dict) or body.get('ok') is not True: raise RuntimeError('TeleMT API non-ok')
    return body.get('data')


def active_pairs():
    out=set()
    rows=api_json('/v1/stats/users/active-ips') or []
    for row in rows:
        u=str(row.get('username') or '')
        for raw in row.get('active_ips') or []:
            try: ip=str(ipaddress.ip_address(str(raw)))
            except ValueError: continue
            if u: out.add((u,ip))
    return out


def recent_pairs():
    out=set()
    try: rows=api_json('/v1/users') or []
    except Exception: return out
    for row in rows:
        u=str(row.get('username') or '')
        raws=list(row.get('recent_unique_ips_list') or [])+list(row.get('active_unique_ips_list') or [])
