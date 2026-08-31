#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.11.12'
BASE_01111_COMMIT='2805deea1364556677a352dcefeb049ae0ed6a48'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_01111_COMMIT/update.sh" -o "$TMP/update-01111.sh" || die 'Не удалось скачать immutable update 0.11.11.'

python3 - "$TMP/update-01111.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "VERSION='0.11.11'" not in s:
    raise SystemExit('unexpected immutable 0.11.11 updater')
s=s.replace('0.11.11','0.11.12')
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-01111.sh" || die '0.11.12 сформировал невалидный updater.'
grep -q "VERSION='0.11.12'" "$TMP/update-01111.sh" || die 'Версия updater не обновилась до 0.11.12.'
grep -q 'webproxy_telemetry_install.sh' "$TMP/update-01111.sh" || die 'WEB telemetry installer потерян.'
grep -q '44-webproxy-activity.py' "$TMP/update-01111.sh" || die 'WEB activity layer потерян.'
grep -q 'repair-misplaced' "$TMP/update-01111.sh" || die 'Source TOML migration потеряна.'
grep -q 'PRAGMA busy_timeout=5000' "$TMP/update-01111.sh" || die 'SQLite hardening потерян.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01111.sh" || die 'Nested 0.11.12 updater transformation failed.'
    ok 'Nested 0.11.12 updater transformation PASS'; exit 0 ;;
  1)
    MTPADMIN_BOOTSTRAP_TEST=1 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01111.sh" || die '0.11.12 wrapper transformation failed.'
    ok '0.11.12 wrapper transformation PASS'; exit 0 ;;
esac

# The immutable 0.11.11 updater already performs the full production chain:
# blue/green web, source repair, persistent stats, WEB relay/backend/telemetry,
# FD regression, doctor and rollback checks. RELEASE_REF keeps all mutable
# fragments pinned to the exact commit selected by Update Center.
MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01111.sh"

# Regression guard for the Update Center routing bug: the installed assembled
# web release must contain both protections before this updater can report PASS.
source /etc/mtpadmin/web-runtime.env
WEB_SERVICE=${WEB_ACTIVE_SERVICE:?}
WEB_PID=$(systemctl show -p MainPID --value "$WEB_SERVICE")
[[ "$WEB_PID" =~ ^[0-9]+$ && "$WEB_PID" -gt 0 ]] || die 'Не найден PID активного web slot.'
WEB_SCRIPT=$(tr '\0' '\n' < "/proc/$WEB_PID/cmdline" | grep -E '^/.*mtpadmin-web-.*\.py$' | head -1 || true)
[[ -f "$WEB_SCRIPT" ]] || die 'Не найден активный assembled web release.'
grep -q "input:not(\[type=hidden\])" "$WEB_SCRIPT" || die 'Live-refresh hidden-field protection не попала в active web release.'
grep -q "name='component' value='" "$WEB_SCRIPT" || die 'Update Center submit-button routing не попал в active web release.'

/usr/local/bin/mtpadmin doctor
ok 'MTPADMIN 0.11.12 updater завершён: Update Center routing + live-refresh form safety PASS.'
