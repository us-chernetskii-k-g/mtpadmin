#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.11.13'
BASE_01112_COMMIT='6b56d501c12dd7f13d1d21b76a320a5973336777'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_01112_COMMIT/update.sh" -o "$TMP/update-01112.sh" || die 'Не удалось скачать immutable update 0.11.12.'

python3 - "$TMP/update-01112.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "VERSION='0.11.12'" not in s:
    raise SystemExit('unexpected immutable 0.11.12 updater')
s=s.replace('0.11.12','0.11.13')
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-01112.sh" || die '0.11.13 сформировал невалидный updater.'
grep -q "VERSION='0.11.13'" "$TMP/update-01112.sh" || die 'Версия updater не обновилась до 0.11.13.'
grep -q 'webproxy_telemetry_install.sh' "$TMP/update-01112.sh" || die 'WEB telemetry installer потерян.'
grep -q "prefix='/action/component-update/'" "$TMP/update-01112.sh" || die 'Route-safe Update Center потерян.'
grep -q 'PRAGMA busy_timeout=5000' "$TMP/update-01112.sh" || die 'SQLite hardening потерян.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01112.sh" || die 'Nested 0.11.13 updater transformation failed.'
    ok 'Nested 0.11.13 updater transformation PASS'; exit 0 ;;
  1)
    MTPADMIN_BOOTSTRAP_TEST=1 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01112.sh" || die '0.11.13 wrapper transformation failed.'
    ok '0.11.13 wrapper transformation PASS'; exit 0 ;;
esac

MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01112.sh"

TELEMETRY='/usr/local/lib/mtpadmin/webproxy_telemetry_install.sh'
[[ -x "$TELEMETRY" ]] || die 'WEB telemetry installer не установлен.'
grep -Fq 'GOTMPDIR="$gotmp"' "$TELEMETRY" || die 'Disk-safe GOTMPDIR protection не установлена.'
grep -Fq 'restore_patched_backup' "$TELEMETRY" || die 'Telemetry backup recovery не установлена.'
grep -Fq 'MIN_BUILD_FREE_KB' "$TELEMETRY" || die 'Telemetry free-space preflight не установлена.'

/usr/local/bin/mtpadmin doctor
ok 'MTPADMIN 0.11.13 updater завершён: disk-safe WEB telemetry + route-safe Update Center PASS.'
