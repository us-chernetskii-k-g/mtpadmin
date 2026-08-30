#!/usr/bin/env python3
import argparse, ipaddress, json, os, re, signal, sqlite3, subprocess, sys, time, urllib.request
from pathlib import Path

VERSION='0.7.0'
STATE=Path(os.environ.get('MTPADMIN_STATE','/etc/mtpadmin/state.env'))
DB=Path(os.environ.get('MTPADMIN_DB','/var/lib/mtpadmin/stats.db'))
API='http://127.0.0.1:9091'
TABLE='mtpadmin_guard'
STOP=False
RELOAD=False
CITY=Path('/var/lib/mtpadmin/geo/dbip-city-lite.mmdb')
ASN=Path('/var/lib/mtpadmin/geo/dbip-asn-lite.mmdb')
HOSTING=('host','cloud','server','datacenter','data center','vps','leaseweb','hetzner','ovh','digitalocean','amazon','google','microsoft','oracle','linode','akamai','contabo','netcup','dedik','selectel','timeweb','ultrahost')
CLASSES=('CLIENT','UNKNOWN','HOSTING?','SCAN','WHITELIST','BANNED')


def state():
    d={}
    for x in STATE.read_text().splitlines():
        if '=' not in x or x.lstrip().startswith('#'):
            continue
        k,v=x.split('=',1); v=v.strip()
        d[k.strip()]=v[1:-1] if len(v)>1 and v[0]==v[-1] and v[0] in "'\"" else v
    return d


def con():
    c=sqlite3.connect(DB,timeout=10)
    c.row_factory=sqlite3.Row
    c.execute('PRAGMA busy_timeout=10000')
    return c


def _column_names(c,table):
    return {str(r[1]) for r in c.execute(f'PRAGMA table_info({table})')}


def initdb():
    with con() as c:
        c.executescript('''
CREATE TABLE IF NOT EXISTS scanner_observations(
 ip TEXT PRIMARY KEY,family INTEGER NOT NULL,first_seen INTEGER NOT NULL,last_seen INTEGER NOT NULL,
 total_attempts INTEGER NOT NULL DEFAULT 0,last_nft_counter INTEGER NOT NULL DEFAULT 0,
 valid_ever INTEGER NOT NULL DEFAULT 0,valid_last_seen INTEGER,classification TEXT NOT NULL DEFAULT 'UNKNOWN',
 country_code TEXT DEFAULT '',city TEXT DEFAULT '',asn TEXT DEFAULT '',org TEXT DEFAULT '',risk_score INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS scanner_obs_last ON scanner_observations(last_seen DESC);
CREATE INDEX IF NOT EXISTS scanner_obs_class_last ON scanner_observations(classification,last_seen DESC);
CREATE TABLE IF NOT EXISTS scanner_bans(ip TEXT PRIMARY KEY,created_at INTEGER NOT NULL,expires_at INTEGER,reason TEXT NOT NULL DEFAULT '',actor TEXT NOT NULL DEFAULT 'cli',active INTEGER NOT NULL DEFAULT 1,removed_at INTEGER);
CREATE TABLE IF NOT EXISTS scanner_whitelist(ip TEXT PRIMARY KEY,created_at INTEGER NOT NULL,note TEXT NOT NULL DEFAULT '',actor TEXT NOT NULL DEFAULT 'cli');
CREATE TABLE IF NOT EXISTS scanner_audit(id INTEGER PRIMARY KEY AUTOINCREMENT,ts INTEGER NOT NULL,actor TEXT NOT NULL,action TEXT NOT NULL,ip TEXT NOT NULL DEFAULT '',detail TEXT NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS scanner_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS scanner_state_events(
 id INTEGER PRIMARY KEY AUTOINCREMENT,ts INTEGER NOT NULL,ip TEXT NOT NULL,old_class TEXT NOT NULL,new_class TEXT NOT NULL,
 attempts INTEGER NOT NULL DEFAULT 0,risk_score INTEGER NOT NULL DEFAULT 0,detail TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS scanner_events_ts ON scanner_state_events(ts DESC);
CREATE INDEX IF NOT EXISTS scanner_events_ip_ts ON scanner_state_events(ip,ts DESC);
''')
        cols=_column_names(c,'scanner_observations')
        if 'risk_score' not in cols:
            c.execute("ALTER TABLE scanner_observations ADD COLUMN risk_score INTEGER NOT NULL DEFAULT 0")


def nft(*args,input=None,check=True):
    p=subprocess.run(['nft',*args],input=input,text=True,capture_output=True,timeout=15)
    if check and p.returncode:
        raise RuntimeError((p.stderr or p.stdout).strip())
    return p


def rules(port,table=TABLE):
    return f'''table inet {table} {{
 set seen4 {{ type ipv4_addr; flags dynamic,timeout; timeout 2h; size 65535; }}
 set seen6 {{ type ipv6_addr; flags dynamic,timeout; timeout 2h; size 65535; }}
 set blocked4_perm {{ type ipv4_addr; size 65535; }}
 set blocked6_perm {{ type ipv6_addr; size 65535; }}
 set blocked4_temp {{ type ipv4_addr; flags timeout; size 65535; }}
 set blocked6_temp {{ type ipv6_addr; flags timeout; size 65535; }}
 chain input {{ type filter hook input priority -5; policy accept;
  tcp dport {port} ip saddr @blocked4_perm counter drop
  tcp dport {port} ip saddr @blocked4_temp counter drop
  tcp dport {port} ip6 saddr @blocked6_perm counter drop
  tcp dport {port} ip6 saddr @blocked6_temp counter drop
  ct state new tcp flags syn tcp dport {port} update @seen4 {{ ip saddr timeout 2h counter }}
  ct state new tcp flags syn tcp dport {port} update @seen6 {{ ip6 saddr timeout 2h counter }}
 }}
}}\n'''


def nset(ip,temp): return f"blocked{ipaddress.ip_address(ip).version}_{'temp' if temp else 'perm'}"
def script(s,check=True): return nft('-f','-',input=s,check=check)


def delban_nft(ip):
    a=str(ipaddress.ip_address(ip))
    for t in (False,True): script(f'delete element inet {TABLE} {nset(a,t)} {{ {a} }}\n',False)


def addban_nft(ip,exp=None):
    a=str(ipaddress.ip_address(ip)); now=int(time.time()); name=nset(a,bool(exp)); delban_nft(a)
    if exp:
        left=int(exp)-now
        if left<=0: return
        script(f'add element inet {TABLE} {name} {{ {a} timeout {left}s }}\n')
    else: script(f'add element inet {TABLE} {name} {{ {a} }}\n')


def sync_bans():
    now=int(time.time())
    with con() as c:
        c.execute('UPDATE scanner_bans SET active=0,removed_at=? WHERE active=1 AND expires_at IS NOT NULL AND expires_at<=?',(now,now))
        rs=c.execute('SELECT ip,expires_at FROM scanner_bans WHERE active=1').fetchall()
    for r in rs:
        try: addban_nft(r['ip'],r['expires_at'])
        except Exception as e: print(f'restore ban {r["ip"]}: {e}',file=sys.stderr)


def ensure(port,force=False):
    initdb(); exists=nft('list','table','inet',TABLE,check=False).returncode==0
    with con() as c:
        r=c.execute("SELECT value FROM scanner_meta WHERE key='guard_port'").fetchone(); old=r[0] if r else None
    if exists and old==str(port) and not force: return
    nft('delete','table','inet',TABLE,check=False); script(rules(port))
    with con() as c: c.execute("INSERT INTO scanner_meta VALUES('guard_port',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(str(port),))
    sync_bans()


def elems(name):
    p=nft('-j','list','set','inet',TABLE,name,check=False); out={}
    if p.returncode: return out
    try: d=json.loads(p.stdout)
    except Exception: return out
    for o in d.get('nftables',[]):
        s=o.get('set') if isinstance(o,dict) else None
        if not s or s.get('name')!=name: continue
        for x in s.get('elem') or []:
            if isinstance(x,str): out[x]=1
            elif isinstance(x,dict) and 'elem' in x:
                e=x['elem']; v=e.get('val')
                if isinstance(v,str): out[v]=int((e.get('counter') or {}).get('packets') or 1)
    return out


def seen():
    d=elems('seen4'); d.update(elems('seen6')); return d


def api(path):
    with urllib.request.urlopen(API+path,timeout=4) as r: d=json.loads(r.read())
    return d.get('data') if isinstance(d,dict) and d.get('ok') is True else []


def valid_info():
    now=int(time.time()); out={}
    try:
        retention=max(1,min(365,int(state().get('RETENTION_DAYS','7')))); cutoff=now-retention*86400
        with con() as c:
            for r in c.execute("SELECT ip,last_seen FROM clients WHERE ip IS NOT NULL AND ip!='' AND last_seen>=?",(cutoff,)):
                try: out[str(ipaddress.ip_address(r[0]))]=int(r[1] or now)
                except (ValueError,TypeError): pass
    except Exception: pass
    try:
        for u in api('/v1/users') or []:
            for k in ('active_unique_ips_list','recent_unique_ips_list'):
                for x in u.get(k) or []:
                    try: out.setdefault(str(ipaddress.ip_address(x)),now)
                    except ValueError: pass
    except Exception: pass
    return out


def valid(): return set(valid_info())


def geo(ip):
    try:
        with con() as c: r=c.execute('SELECT country_code,city,asn,org FROM clients WHERE ip=?',(ip,)).fetchone()
        if r and any(r): return tuple((r[k] or '') for k in ('country_code','city','asn','org'))
    except Exception: pass
    cc=city=asn=org=''
    try:
        import maxminddb
        if CITY.exists():
            with maxminddb.open_database(str(CITY)) as rd: q=rd.get(ip) or {}
            cc=(q.get('country') or {}).get('iso_code') or ''; city=((q.get('city') or {}).get('names') or {}).get('en') or ''
        if ASN.exists():
            with maxminddb.open_database(str(ASN)) as rd: q=rd.get(ip) or {}
            n=q.get('autonomous_system_number') or q.get('asn') or q.get('as_number'); org=q.get('autonomous_system_organization') or q.get('as_organization') or ''
            if n: asn=str(n).upper(); asn=asn if asn.startswith('AS') else 'AS'+asn
    except Exception: pass
    return cc,city,asn,org


def hosting(org): return any(x in (org or '').lower() for x in HOSTING)


def _get(r,key,default=None):
    if isinstance(r,dict): v=r.get(key,default)
    else:
        try: v=r[key]
        except Exception: v=default
    return default if v is None else v


def classify(r,bans,white,now):
    ip=str(_get(r,'ip',''))
    if ip in bans: return 'BANNED'
    if ip in white: return 'WHITELIST'
    if int(_get(r,'valid_ever',0) or 0): return 'CLIENT'
    n=int(_get(r,'total_attempts',0) or 0); age=max(0,now-int(_get(r,'first_seen',now) or now))
    if (n>=10 and age>=60) or (n>=5 and age>=120): return 'SCAN'
    if n>=3 and age>=60 and hosting(str(_get(r,'org','') or '')): return 'HOSTING?'
    return 'UNKNOWN'


def risk_score(r,now=None):
    now=int(now or time.time()); cls=str(_get(r,'classification','UNKNOWN') or 'UNKNOWN')
    if cls in ('CLIENT','WHITELIST'): return 0
    if cls=='BANNED': return 100
    if int(_get(r,'valid_ever',0) or 0): return 0
    n=max(0,int(_get(r,'total_attempts',0) or 0)); first=int(_get(r,'first_seen',now) or now); last=int(_get(r,'last_seen',first) or first); age=max(0,last-first)
    score=min(45,n*5)
    if n>=3: score+=5
    if n>=5: score+=10
    if n>=10: score+=10
    if age>=60 and n>=3: score+=5
    if age>=120 and n>=5: score+=10
    if hosting(str(_get(r,'org','') or '')): score+=15
    return max(0,min(99,score))


def avg_interval(r):
    n=int(_get(r,'total_attempts',0) or 0)
    if n<=1: return None
    first=int(_get(r,'first_seen',0) or 0); last=int(_get(r,'last_seen',0) or 0)
    if not first or last<=first: return 0.0
    return max(0.0,(last-first)/(n-1))


def transition(c,row,new_class,now,detail='observer'):
    old=str(_get(row,'classification','UNKNOWN') or 'UNKNOWN'); d=dict(row); d['classification']=new_class
    risk=risk_score(d,now); ip=str(_get(row,'ip',''))
    c.execute('UPDATE scanner_observations SET classification=?,risk_score=? WHERE ip=?',(new_class,risk,ip))
    if new_class!=old:
        c.execute('INSERT INTO scanner_state_events(ts,ip,old_class,new_class,attempts,risk_score,detail) VALUES(?,?,?,?,?,?,?)',(now,ip,old,new_class,int(_get(row,'total_attempts',0) or 0),risk,detail[:120]))
    return risk


def set_class(ip,new_class,detail):
    now=int(time.time())
    with con() as c:
        row=c.execute('SELECT * FROM scanner_observations WHERE ip=?',(ip,)).fetchone()
        if row: transition(c,row,new_class,now,detail)


def collect():
    port=int(state().get('PORT','8443')); ensure(port); now=int(time.time()); ss=seen(); vv=valid_info()
    retention=max(1,min(365,int(state().get('RETENTION_DAYS','7') or '7'))); trust_cutoff=now-retention*86400
    with con() as c:
        c.execute('UPDATE scanner_bans SET active=0,removed_at=? WHERE active=1 AND expires_at IS NOT NULL AND expires_at<=?',(now,now))
        c.execute('UPDATE scanner_observations SET valid_ever=0 WHERE valid_ever=1 AND valid_last_seen IS NOT NULL AND valid_last_seen<?',(trust_cutoff,))
        bans={r[0] for r in c.execute('SELECT ip FROM scanner_bans WHERE active=1 AND (expires_at IS NULL OR expires_at>?)',(now,))}; white={r[0] for r in c.execute('SELECT ip FROM scanner_whitelist')}
        for ip,count in ss.items():
            try: fam=ipaddress.ip_address(ip).version
            except ValueError: continue
            r=c.execute('SELECT * FROM scanner_observations WHERE ip=?',(ip,)).fetchone()
            if r:
                prev=int(r['last_nft_counter']); delta=count-prev if count>=prev else count; cc,city,asn,org=(r['country_code'],r['city'],r['asn'],r['org'])
                if not any((cc,city,asn,org)): cc,city,asn,org=geo(ip)
                c.execute('''UPDATE scanner_observations SET last_seen=?,total_attempts=total_attempts+?,last_nft_counter=?,valid_ever=CASE WHEN ? THEN 1 ELSE valid_ever END,valid_last_seen=CASE WHEN ? THEN max(coalesce(valid_last_seen,0),?) ELSE valid_last_seen END,country_code=?,city=?,asn=?,org=? WHERE ip=?''',(now,max(0,delta),count,ip in vv,ip in vv,int(vv.get(ip,now)),cc,city,asn,org,ip))
            else:
                cc,city,asn,org=geo(ip); c.execute('''INSERT INTO scanner_observations(ip,family,first_seen,last_seen,total_attempts,last_nft_counter,valid_ever,valid_last_seen,country_code,city,asn,org) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)''',(ip,fam,now,now,max(count,1),count,1 if ip in vv else 0,int(vv[ip]) if ip in vv else None,cc,city,asn,org))
        for ip in vv:
            r=c.execute('SELECT ip FROM scanner_observations WHERE ip=?',(ip,)).fetchone()
            if r: c.execute('UPDATE scanner_observations SET valid_ever=1,valid_last_seen=max(coalesce(valid_last_seen,0),?) WHERE ip=?',(int(vv[ip]),ip))
            else:
                fam=ipaddress.ip_address(ip).version; cc,city,asn,org=geo(ip); c.execute('''INSERT INTO scanner_observations(ip,family,first_seen,last_seen,valid_ever,valid_last_seen,country_code,city,asn,org) VALUES(?,?,?,?,1,?,?,?,?,?)''',(ip,fam,now,now,int(vv[ip]),cc,city,asn,org))
        for r in c.execute('SELECT * FROM scanner_observations WHERE last_seen>=?',(now-30*86400,)).fetchall(): transition(c,r,classify(r,bans,white,now),now)
        c.execute("INSERT INTO scanner_meta VALUES('heartbeat',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",(str(now),)); c.execute("INSERT INTO scanner_meta VALUES('autoban','0') ON CONFLICT(key) DO UPDATE SET value='0'")


def audit(action,ip='',detail='',actor='cli'):
    with con() as c: c.execute('INSERT INTO scanner_audit(ts,actor,action,ip,detail) VALUES(?,?,?,?,?)',(int(time.time()),actor[:80],action[:40],ip[:64],detail[:500]))


def target(x):
    a=ipaddress.ip_address(x.strip())
    if a.is_loopback or a.is_unspecified or a.is_multicast or a.is_link_local or not a.is_global: raise ValueError('разрешены только публичные IP')
    own=state().get('PUBLIC_IP','')
    if own and a==ipaddress.ip_address(own): raise ValueError('IP самого сервера блокировать запрещено')
    return str(a)


def duration(x):
    x=x.lower()
    if x in ('permanent','perm','forever'): return None,'permanent'
    m=re.fullmatch(r'(\d+)([mhd])',x)
    if not m: raise ValueError('duration: 30m | 24h | 7d | permanent')
    sec=int(m[1])*{'m':60,'h':3600,'d':86400}[m[2]]
    if sec<1 or sec>3650*86400: raise ValueError('invalid duration')
    return int(time.time())+sec,x


def ban(ip,dur,reason,actor):
    ip=target(ip); exp,label=duration(dur); now=int(time.time()); initdb()
    with con() as c:
        if c.execute('SELECT 1 FROM scanner_whitelist WHERE ip=?',(ip,)).fetchone(): raise ValueError('IP в whitelist; сначала удалите его из whitelist')
        c.execute('''INSERT INTO scanner_bans VALUES(?,?,?,?,?,1,NULL) ON CONFLICT(ip) DO UPDATE SET created_at=excluded.created_at,expires_at=excluded.expires_at,reason=excluded.reason,actor=excluded.actor,active=1,removed_at=NULL''',(ip,now,exp,reason[:200],actor[:80]))
    ensure(int(state().get('PORT','8443'))); addban_nft(ip,exp); set_class(ip,'BANNED','manual-ban'); audit('ban',ip,f'duration={label}; reason={reason}',actor); print(f'BANNED {ip} {label}')


def unban(ip,actor):
    ip=target(ip); delban_nft(ip); now=int(time.time())
    with con() as c:
        c.execute('UPDATE scanner_bans SET active=0,removed_at=? WHERE ip=?',(now,ip)); row=c.execute('SELECT * FROM scanner_observations WHERE ip=?',(ip,)).fetchone(); white=bool(c.execute('SELECT 1 FROM scanner_whitelist WHERE ip=?',(ip,)).fetchone())
        if row: transition(c,row,'WHITELIST' if white else ('CLIENT' if row['valid_ever'] else 'UNKNOWN'),now,'manual-unban')
    audit('unban',ip,'',actor); print(f'UNBANNED {ip}')


def white(ip,note,actor):
    ip=target(ip); delban_nft(ip); now=int(time.time())
    with con() as c:
        c.execute('UPDATE scanner_bans SET active=0,removed_at=? WHERE ip=?',(now,ip)); c.execute('INSERT INTO scanner_whitelist VALUES(?,?,?,?) ON CONFLICT(ip) DO UPDATE SET note=excluded.note,actor=excluded.actor',(ip,now,note[:200],actor[:80])); row=c.execute('SELECT * FROM scanner_observations WHERE ip=?',(ip,)).fetchone()
        if row: transition(c,row,'WHITELIST',now,'manual-whitelist')
    audit('whitelist',ip,note,actor); print(f'WHITELIST {ip}')


def unwhite(ip,actor):
    ip=target(ip); now=int(time.time())
    with con() as c:
        c.execute('DELETE FROM scanner_whitelist WHERE ip=?',(ip,)); row=c.execute('SELECT * FROM scanner_observations WHERE ip=?',(ip,)).fetchone(); banned=bool(c.execute('SELECT 1 FROM scanner_bans WHERE ip=? AND active=1 AND (expires_at IS NULL OR expires_at>?)',(ip,now)).fetchone())
        if row: transition(c,row,'BANNED' if banned else ('CLIENT' if row['valid_ever'] else 'UNKNOWN'),now,'manual-unwhitelist')
    audit('unwhitelist',ip,'',actor); print(f'UNWHITELIST {ip}')


def status(js=False):
    initdb(); now=int(time.time())
    with con() as c:
        h=c.execute("SELECT value FROM scanner_meta WHERE key='heartbeat'").fetchone(); cls={r[0]:r[1] for r in c.execute('SELECT classification,count(*) FROM scanner_observations WHERE last_seen>=? GROUP BY classification',(now-86400,))}; bans=c.execute('SELECT count(*) FROM scanner_bans WHERE active=1 AND (expires_at IS NULL OR expires_at>?)',(now,)).fetchone()[0]; wh=c.execute('SELECT count(*) FROM scanner_whitelist').fetchone()[0]; high=c.execute("SELECT count(*) FROM scanner_observations WHERE last_seen>=? AND risk_score>=70 AND classification NOT IN ('CLIENT','WHITELIST')",(now-86400,)).fetchone()[0]
    d={'version':VERSION,'heartbeat':int(h[0]) if h else 0,'autoban':False,'bans':bans,'whitelist':wh,'risk70_24h':high,'classes_24h':cls}
    if js: print(json.dumps(d,ensure_ascii=False)); return
    print(f'Scanner Guard {VERSION}\n  heartbeat: {now-d["heartbeat"] if d["heartbeat"] else "нет"}s\n  autoban: OFF\n  active bans: {bans}\n  whitelist: {wh}\n  risk>=70 (24h): {high}\n  last 24h: '+', '.join(f'{k}={v}' for k,v in sorted(cls.items())))


def listing(kind):
    initdb()
    with con() as c:
        if kind=='bans': rs=c.execute('SELECT ip,expires_at,reason,actor FROM scanner_bans WHERE active=1 AND (expires_at IS NULL OR expires_at>?)',(int(time.time()),)).fetchall()
        elif kind=='events': rs=c.execute('SELECT ts,ip,old_class,new_class,attempts,risk_score,detail FROM scanner_state_events ORDER BY ts DESC LIMIT 100').fetchall()
        elif kind=='observed': rs=c.execute('SELECT ip,classification,risk_score,total_attempts,last_seen,valid_last_seen,country_code,city,asn,org FROM scanner_observations ORDER BY last_seen DESC LIMIT 200').fetchall()
        else: rs=c.execute("SELECT ip,classification,risk_score,total_attempts,last_seen,country_code,city,asn,org FROM scanner_observations WHERE classification IN ('SCAN','HOSTING?','UNKNOWN') ORDER BY risk_score DESC,total_attempts DESC LIMIT 100").fetchall()
    for r in rs: print('  '.join(str(x if x is not None else '-') for x in r))


def selftest():
    if not STATE.exists() or not DB.exists(): raise SystemExit('MTPADMIN state/database missing')
    port=int(state().get('PORT','0')); initdb(); nft('-c','-f','-',input=rules(port,'mtpadmin_guard_check')); print(f'PASS scanner selftest port={port}')


def worker():
    global STOP,RELOAD
    signal.signal(signal.SIGTERM,lambda *_:globals().__setitem__('STOP',True)); signal.signal(signal.SIGINT,lambda *_:globals().__setitem__('STOP',True)); signal.signal(signal.SIGHUP,lambda *_:globals().__setitem__('RELOAD',True))
    last=None
    while not STOP:
        try:
            port=int(state().get('PORT','8443')); ensure(port,force=last is not None and port!=last); last=port; collect()
        except Exception as e: print(f'scanner cycle: {type(e).__name__}: {e}',file=sys.stderr)
        if RELOAD:
            os.execv(sys.executable,[sys.executable,str(Path(__file__).resolve()),'worker'])
        for _ in range(10):
            if STOP or RELOAD: break
            time.sleep(1)


def main():
    p=argparse.ArgumentParser(); s=p.add_subparsers(dest='cmd',required=True)
    s.add_parser('selftest'); s.add_parser('init'); s.add_parser('worker'); q=s.add_parser('status'); q.add_argument('--json',action='store_true'); s.add_parser('suspicious'); s.add_parser('bans'); s.add_parser('observed'); s.add_parser('events')
    q=s.add_parser('ban'); q.add_argument('ip'); q.add_argument('duration',nargs='?',default='24h'); q.add_argument('--reason',default='manual'); q.add_argument('--actor',default='cli')
    q=s.add_parser('unban'); q.add_argument('ip'); q.add_argument('--actor',default='cli'); q=s.add_parser('whitelist'); q.add_argument('ip'); q.add_argument('--note',default='manual'); q.add_argument('--actor',default='cli'); q=s.add_parser('unwhitelist'); q.add_argument('ip'); q.add_argument('--actor',default='cli')
    a=p.parse_args()
    if a.cmd=='selftest': selftest()
    elif a.cmd=='init': selftest(); ensure(int(state().get('PORT','8443')),True); collect(); print('PASS guard initialized; autoban=OFF')
    elif a.cmd=='worker': worker()
    elif a.cmd=='status': status(a.json)
    elif a.cmd in ('suspicious','bans','observed','events'): listing(a.cmd)
    elif a.cmd=='ban': ban(a.ip,a.duration,a.reason,a.actor)
    elif a.cmd=='unban': unban(a.ip,a.actor)
    elif a.cmd=='whitelist': white(a.ip,a.note,a.actor)
    elif a.cmd=='unwhitelist': unwhite(a.ip,a.actor)


if __name__=='__main__': main()
