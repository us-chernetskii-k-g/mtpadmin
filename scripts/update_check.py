#!/usr/bin/env python3
import base64, json, os, re, subprocess, tempfile, time, urllib.request
from pathlib import Path

OUT=Path('/var/lib/mtpadmin/update-status.json')
STATE=Path('/etc/mtpadmin/state.env')
UA='MTPADMIN-update-check/0.11.3'


def state():
    out={}
    try:
        for line in STATE.read_text(encoding='utf-8').splitlines():
            if not line or line.lstrip().startswith('#') or '=' not in line: continue
            k,v=line.split('=',1); v=v.strip()
            if len(v)>=2 and v[0]==v[-1] and v[0] in "'\"": v=v[1:-1]
            out[k.strip()]=v
    except Exception: pass
    return out


def get_text(url, timeout=10):
    req=urllib.request.Request(url,headers={
        'User-Agent':UA,
        'Accept':'application/vnd.github+json',
        'Cache-Control':'no-cache',
        'Pragma':'no-cache',
    })
    with urllib.request.urlopen(req,timeout=timeout) as r:
        return r.read().decode('utf-8','replace')


def get_json(url): return json.loads(get_text(url))

def github_file_text(repo, path, ref='main'):
    data=get_json(f'https://api.github.com/repos/{repo}/contents/{path}?ref={ref}')
    if not isinstance(data,dict): raise RuntimeError('GitHub contents API returned non-object')
    if data.get('encoding')!='base64' or not data.get('content'):
        raise RuntimeError('GitHub contents API returned unsupported encoding')
    return base64.b64decode(str(data['content']).encode('ascii')).decode('utf-8','replace')


def semver(v):
    m=re.search(r'(\d+)\.(\d+)\.(\d+)',str(v or ''))
    return tuple(map(int,m.groups())) if m else (0,0,0)

def cmdver(argv):
    try:
        p=subprocess.run(argv,capture_output=True,text=True,timeout=5)
        s=(p.stdout or '')+' '+(p.stderr or '')
        m=re.search(r'\b\d+\.\d+\.\d+\b',s)
        return m.group(0) if m else s.strip().splitlines()[0][:80]
    except Exception: return ''


def main():
    st=state(); errors=[]; comps={}
    # Runtime binary is authoritative; state.env is only a fallback after a partial install.
    cur_m=cmdver(['/usr/local/bin/mtpadmin','version']) or st.get('MTPADMIN_VERSION') or ''
    try: lat_m=github_file_text('us-chernetskii-k-g/mtpadmin','VERSION','main').strip()
    except Exception as e: lat_m=''; errors.append('MTPADMIN: '+str(e))
    comps['mtpadmin']={'label':'MTPADMIN','current':cur_m,'latest':lat_m,'available':bool(lat_m and semver(lat_m)>semver(cur_m))}

    cur_t=cmdver(['/usr/local/bin/telemt','--version'])
    try:
        rel=get_json('https://api.github.com/repos/telemt/telemt/releases/latest'); lat_t=str(rel.get('tag_name') or '')
    except Exception as e: lat_t=''; errors.append('TeleMT: '+str(e))
    comps['telemt']={'label':'TeleMT','current':cur_t,'latest':lat_t,'available':bool(lat_t and semver(lat_t)>semver(cur_t))}

    marker=Path('/usr/local/lib/mtpadmin/tproxy-server.commit')
    try: cur_w=marker.read_text(encoding='utf-8').strip()
    except Exception: cur_w=''
    try:
        br=get_json('https://api.github.com/repos/telegramdesktop/tproxy-server/branches/master'); lat_w=str(((br.get('commit') or {}).get('sha')) or '')
    except Exception as e: lat_w=''; errors.append('WEB Proxy: '+str(e))
    comps['webproxy']={'label':'Telegram WEB Proxy','current':cur_w,'latest':lat_w,'available':bool(lat_w and cur_w and lat_w!=cur_w),'installed':bool(cur_w)}

    data={'checked_at':int(time.time()),'components':comps,'updates':sum(1 for x in comps.values() if x.get('available')),'errors':errors}
    OUT.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix='.update-status.',dir=str(OUT.parent),text=True)
    try:
        with os.fdopen(fd,'w') as f: json.dump(data,f,ensure_ascii=False,indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
        os.chmod(tmp,0o644); os.replace(tmp,OUT)
    finally:
        try: os.unlink(tmp)
        except FileNotFoundError: pass
    print(json.dumps(data,ensure_ascii=False))

if __name__=='__main__': main()
