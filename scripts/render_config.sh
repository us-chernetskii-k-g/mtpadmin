#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/mtpadmin/state.env
CFG=/etc/mtpadmin/config/config.toml
python3 - "$CFG" "$PUBLIC_HOST" "$PORT" "$PUBLIC_IP" "$FAKE_TLS_DOMAIN" "${AD_TAG:-}" <<'PY'
from pathlib import Path
import os,re,stat,tempfile,sys
p=Path(sys.argv[1]); host=sys.argv[2]; port=int(sys.argv[3]); ip=sys.argv[4]; tls=sys.argv[5]; tag=sys.argv[6]
lines=p.read_text(encoding='utf-8').splitlines(keepends=True)
sec_re=re.compile(r'^\s*\[([^\[\]]+)\]\s*(?:#.*)?$')

def bounds(sec):
    a=None
    for i,l in enumerate(lines):
        m=sec_re.match(l)
        if not m: continue
        if a is None and m.group(1).strip()==sec: a=i; continue
        if a is not None: return a,i
    return (a,len(lines)) if a is not None else (None,None)

def setv(sec,key,literal,delete=False):
    a,b=bounds(sec)
    if a is None:
        if delete: return
        if lines and lines[-1].strip(): lines.append('\n')
        lines.extend([f'[{sec}]\n',f'{key} = {literal}\n']); return
    kr=re.compile(r'^\s*'+re.escape(key)+r'\s*=')
    for i in range(a+1,b):
        if kr.match(lines[i]):
            if delete: del lines[i]
            else: lines[i]=f'{key} = {literal}\n'
            return
    if not delete: lines.insert(b,f'{key} = {literal}\n')

def qs(s): return '"'+s.replace('\\','\\\\').replace('"','\\"')+'"'
setv('general','ad_tag',qs(tag),delete=(tag==''))
setv('general','middle_proxy_nat_ip',qs(ip))
setv('general.links','public_host',qs(host)); setv('general.links','public_port',str(port))
setv('server','port',str(port)); setv('censorship','tls_domain',qs(tls))
st=p.stat(); fd,tmp=tempfile.mkstemp(prefix='.config.toml.',dir=str(p.parent))
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        f.writelines(lines); f.flush(); os.fsync(f.fileno())
    os.chown(tmp,st.st_uid,st.st_gid); os.chmod(tmp,stat.S_IMODE(st.st_mode)); os.replace(tmp,p)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
PY
