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
STATUS='/var/lib/mtpadmin/component-update-status.json'

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

case "${1:-}" in
  webproxy)
    [[ -x "$HARDENING" ]] || { write_status webproxy failed 'WEB Proxy hardening updater missing'; echo '[FAIL] WEB Proxy hardening updater missing' >&2; exit 1; }
    write_status webproxy running 'Безопасное обновление relay: build, token key, rollback и telemetry'
    if ! "$HARDENING"; then
      rc=$?
      write_status webproxy failed "Безопасное обновление WEB Proxy завершилось ошибкой, rc=$rc"
      exit "$rc"
    fi
    if [[ -x "$LANDINGS" ]] && ! "$LANDINGS" --webproxy-only; then
      rc=$?
      write_status webproxy failed "WEB Proxy обновлён, но landing repair завершился ошибкой, rc=$rc"
      exit "$rc"
    fi
    commit=$(tr -d '\r\n' </usr/local/lib/mtpadmin/tproxy-server.commit 2>/dev/null || true)
    write_status webproxy success "WEB Proxy ${commit:0:12} READY; persistent token key + telemetry PASS"
    ;;
  webproxy-host)
    "$LEGACY" "$@"
    [[ ! -x "$LANDINGS" ]] || "$LANDINGS" --webproxy-only
    ;;
  *)
    exec "$LEGACY" "$@"
    ;;
esac
