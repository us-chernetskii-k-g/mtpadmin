#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

DB='/var/lib/mtpadmin/stats.db'
SCANNER='mtpadmin-scanner.service'
TELEMT='mtpadmin-telemt.service'
MAX_AGE=${MTPADMIN_SCANNER_MAX_AGE:-120}

log(){ logger -t mtpadmin-scanner-watchdog -- "$*" 2>/dev/null || true; echo "$*"; }

[[ "$MAX_AGE" =~ ^[0-9]+$ ]] && (( MAX_AGE >= 30 )) || MAX_AGE=120
command -v sqlite3 >/dev/null 2>&1 || exit 0
[[ -f "$DB" ]] || exit 0

# A stopped TeleMT is not a Scanner Guard failure. Do not create a restart loop
# while the primary proxy is intentionally offline.
systemctl is-active --quiet "$TELEMT" || exit 0

heartbeat(){
  sqlite3 -readonly "$DB" "SELECT value FROM scanner_meta WHERE key='heartbeat';" 2>/dev/null | head -1 || true
}

now=$(date +%s)
hb=$(heartbeat)
age=$(( MAX_AGE + 1 ))
[[ "$hb" =~ ^[0-9]+$ ]] && (( hb <= now )) && age=$((now-hb))

if systemctl is-active --quiet "$SCANNER" && (( age <= MAX_AGE )); then
  exit 0
fi

if systemctl is-active --quiet "$SCANNER"; then
  log "Scanner Guard heartbeat stale: ${age}s; restarting service"
else
  log 'Scanner Guard is not active while TeleMT is active; starting service'
fi

systemctl restart "$SCANNER"

for _ in {1..20}; do
  sleep 1
  systemctl is-active --quiet "$SCANNER" || continue
  now=$(date +%s); hb=$(heartbeat)
  if [[ "$hb" =~ ^[0-9]+$ ]] && (( hb <= now )) && (( now-hb <= 30 )); then
    log 'Scanner Guard heartbeat recovered'
    exit 0
  fi
done

log 'Scanner Guard restart did not restore a fresh heartbeat'
exit 1
