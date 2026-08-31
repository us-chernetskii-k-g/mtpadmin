#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.11.11'
BASE_01110_COMMIT='75f3268bad55d6dee5eae40abe8546ade481c1b9'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_01110_COMMIT/update.sh" -o "$TMP/update-01110.sh" || die 'Не удалось скачать immutable update 0.11.10.'

python3 - "$TMP/update-01110.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "VERSION='0.11.10'" not in s:
    raise SystemExit('unexpected immutable 0.11.10 updater')
s=s.replace('0.11.10','0.11.11')
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-01110.sh" || die '0.11.11 сформировал невалидный updater.'
grep -q "VERSION='0.11.11'" "$TMP/update-01110.sh" || die 'Версия updater не обновилась до 0.11.11.'
grep -q 'PRAGMA busy_timeout=5000' "$TMP/update-01110.sh" || die 'SQLite hardening потерян.'
grep -q 'repair-misplaced' "$TMP/update-01110.sh" || die 'Source TOML migration потеряна.'
grep -q '44-webproxy-activity.py' "$TMP/update-01110.sh" || die 'WEB activity layer потерян.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01110.sh" || die 'Nested 0.11.11 updater transformation failed.'
    ok 'Nested 0.11.11 updater transformation PASS'; exit 0 ;;
  1)
    MTPADMIN_BOOTSTRAP_TEST=1 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01110.sh" || die '0.11.11 wrapper transformation failed.'
    ok '0.11.11 wrapper transformation PASS'; exit 0 ;;
esac

# First deploy the proven blue/green release. Because RELEASE_REF is commit-pinned
# by Update Center, current collector/web/component files are fetched from the
# exact release commit rather than floating main.
MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01110.sh"

info 'Устанавливаю privacy-safe WEB client telemetry...'
curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/scripts/webproxy_telemetry_install.sh" -o "$TMP/webproxy_telemetry_install.sh" || die 'Не удалось скачать WEB telemetry installer.'
bash -n "$TMP/webproxy_telemetry_install.sh" || die 'WEB telemetry installer syntax invalid.'
install -m 0700 -o root -g root "$TMP/webproxy_telemetry_install.sh" /usr/local/lib/mtpadmin/webproxy_telemetry_install.sh
bash /usr/local/lib/mtpadmin/webproxy_telemetry_install.sh

info 'Проверяю WEB client telemetry contract...'
curl -fsS --max-time 3 http://127.0.0.1:8081/mtpadmin/clients | python3 -c 'import ipaddress,json,sys; obj=json.load(sys.stdin); rows=obj.get("clients"); assert isinstance(rows,list); [(ipaddress.ip_address(str(row.get("ip"))), isinstance(row.get("sessions"),int) and row.get("sessions")>0, set(row).issubset({"ip","sessions"})) for row in rows]; assert all(isinstance(row.get("sessions"),int) and row.get("sessions")>0 and set(row).issubset({"ip","sessions"}) for row in rows)' >/dev/null || die 'WEB client telemetry endpoint invalid.'

# The new collector tolerates the endpoint being absent during blue/green
# deployment; once telemetry is live it will pick up WEB clients on the next
# poll. Restart only the collector to make that transition immediate.
systemctl restart mtpadmin-stats.service >/dev/null 2>&1 || warn 'Statistics collector restart failed; systemd retry/next poll will recover.'
sleep 2
/usr/local/bin/mtpadmin doctor

ok 'MTPADMIN 0.11.11 updater завершён: WEB client IP/GeoIP telemetry + panel update path READY.'
