#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# MTPADMIN component update compatibility wrapper 0.12.5.
# The legacy dispatcher remains authoritative for MTPADMIN/TeleMT/jobs. Only the
# direct WEB Proxy worker is replaced because new upstream requires a persistent
# token signing key and first-upgrade drain handling.
LEGACY='/usr/local/lib/mtpadmin/component_update_legacy.sh'
HARDENING='/usr/local/lib/mtpadmin/webproxy_update_hardening.sh'
LANDINGS='/usr/local/lib/mtpadmin/public_landings_install.sh'
CHECKER='/usr/local/lib/mtpadmin/update_check.py'
STATUS='/var/lib/mtpadmin/component-update-status.json'
UPDATE_STATUS='/var/lib/mtpadmin/update-status.json'

[[ -x "$LEGACY" ]] || { echo '[FAIL] legacy component updater missing' >&2; exit 1; }

write_status(){
  local component="$1" state="$2" detail="${3:-}"
  install -d -m 0750 -o root -g mtpadmin /var/lib/mtpadmin 2>/dev/null || true
  python3 - "$STATUS" "$component" "$state" "$detail" <<'PY'
import json,os,sys,tempfile,time
p,comp,state,detail=sys.argv[1:]
fd,tmp=tempfile.mkstemp(prefix='.component-update.',dir=os.path.dirname(p),text=True)
with os.fdopen(fd,'w') as f:
    json.dump({'component':comp,'state':state,'detail':detail,'ts':int(time.time())},f,ensure_ascii=False)
    f.write('\n'); f.flush(); os.fsync(f.fileno())
os.chmod(tmp,0o644); os.replace(tmp,p)
PY
}

# Update Center renders update-status.json. A successful direct WEB Proxy
# upgrade must immediately update its local snapshot; otherwise the UI keeps
# showing the old commit until the next network update-check. Keep checked_at
# untouched because this local refresh is not itself a remote freshness check.
refresh_webproxy_snapshot(){
  local commit="$1"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 1
  install -d -m 0750 -o root -g mtpadmin /var/lib/mtpadmin 2>/dev/null || true
  python3 - "$UPDATE_STATUS" "$commit" <<'PY'
import json,os,sys,tempfile,time
p,commit=sys.argv[1:]
try:
    with open(p,encoding='utf-8') as f:
        data=json.load(f)
    if not isinstance(data,dict): data={}
except Exception:
    data={}
components=data.get('components')
if not isinstance(components,dict): components={}
webproxy=components.get('webproxy')
if not isinstance(webproxy,dict): webproxy={}
webproxy['label']='Telegram WEB Proxy'
webproxy['current']=commit
webproxy['installed']=True
latest=str(webproxy.get('latest') or '')
webproxy['available']=bool(latest and latest != commit)
components['webproxy']=webproxy
data['components']=components
data['updates']=sum(1 for item in components.values() if isinstance(item,dict) and item.get('available'))
data['local_refreshed_at']=int(time.time())
os.makedirs(os.path.dirname(p),exist_ok=True)
fd,tmp=tempfile.mkstemp(prefix='.update-status.',dir=os.path.dirname(p),text=True)
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        json.dump(data,f,ensure_ascii=False,indent=2)
        f.write('\n'); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,0o644)
    os.replace(tmp,p)
finally:
    try: os.unlink(tmp)
    except FileNotFoundError: pass
PY
}

case "${1:-}" in
  webproxy)
    [[ -x "$HARDENING" ]] || { write_status webproxy failed 'WEB Proxy hardening updater missing'; echo '[FAIL] WEB Proxy hardening updater missing' >&2; exit 1; }
    write_status webproxy running 'Безопасное обновление relay: build, token key, rollback и telemetry'
    if "$HARDENING"; then
      :
    else
      rc=$?
      write_status webproxy failed "Безопасное обновление WEB Proxy завершилось ошибкой, rc=$rc"
      exit "$rc"
    fi
    if [[ -x "$LANDINGS" ]]; then
      if "$LANDINGS" --webproxy-only; then
        :
      else
        rc=$?
        write_status webproxy failed "WEB Proxy обновлён, но landing repair завершился ошибкой, rc=$rc"
        exit "$rc"
      fi
    fi
    commit=$(tr -d '\r\n' </usr/local/lib/mtpadmin/tproxy-server.commit 2>/dev/null || true)
    write_status webproxy success "WEB Proxy ${commit:0:12} READY; persistent token key + telemetry PASS"
    if refresh_webproxy_snapshot "$commit"; then
      echo '[PASS] Update Center синхронизирован с установленным WEB Proxy'
    else
      echo '[WARN] WEB Proxy обновлён, но локальный snapshot Update Center не синхронизирован' >&2
    fi
    # Best-effort remote refresh. Network/API trouble must never turn a completed
    # component upgrade into a failure; the local snapshot above is authoritative
    # for the installed commit until the next scheduled/manual update check.
    if [[ -x "$CHECKER" ]]; then
      "$CHECKER" >/dev/null 2>&1 || true
    fi
    ;;
  webproxy-host)
    "$LEGACY" "$@"
    [[ ! -x "$LANDINGS" ]] || "$LANDINGS" --webproxy-only
    ;;
  *)
    exec "$LEGACY" "$@"
    ;;
esac
