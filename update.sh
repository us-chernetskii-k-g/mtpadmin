#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.11.14'
BASE_01112_COMMIT='6b56d501c12dd7f13d1d21b76a320a5973336777'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_01112_COMMIT/update.sh" -o "$TMP/update-01112.sh" || die 'Не удалось скачать immutable update 0.11.12.'

python3 - "$TMP/update-01112.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "VERSION='0.11.12'" not in s:
    raise SystemExit('unexpected immutable 0.11.12 updater')
s=s.replace('0.11.12','0.11.14')
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-01112.sh" || die '0.11.14 сформировал невалидный updater.'
grep -q "VERSION='0.11.14'" "$TMP/update-01112.sh" || die 'Версия updater не обновилась до 0.11.14.'
grep -q 'webproxy_telemetry_install.sh' "$TMP/update-01112.sh" || die 'WEB telemetry installer потерян.'
grep -q "prefix='/action/component-update/'" "$TMP/update-01112.sh" || die 'Route-safe Update Center потерян.'
grep -q 'PRAGMA busy_timeout=5000' "$TMP/update-01112.sh" || die 'SQLite hardening потерян.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01112.sh" || die 'Nested 0.11.14 updater transformation failed.'
    ok 'Nested 0.11.14 updater transformation PASS'; exit 0 ;;
  1)
    MTPADMIN_BOOTSTRAP_TEST=1 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01112.sh" || die '0.11.14 wrapper transformation failed.'
    ok '0.11.14 wrapper transformation PASS'; exit 0 ;;
esac

# Reuse the proven 0.11.12 production update chain, pinned to the exact
# selected release commit. This installs all current runtime fragments first.
MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01112.sh"

# Force-install the release-pinned telemetry installer once more. 0.11.14 fixes
# the disk-backed build-root traversal permission required by the unprivileged
# tproxy compiler process.
TELEMETRY='/usr/local/lib/mtpadmin/webproxy_telemetry_install.sh'
curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/scripts/webproxy_telemetry_install.sh" -o "$TMP/webproxy_telemetry_install.sh" || die 'Не удалось скачать release-pinned WEB telemetry installer.'
bash -n "$TMP/webproxy_telemetry_install.sh" || die 'WEB telemetry installer syntax invalid.'
grep -Fq 'install -d -m 0711 -o root -g root "$BUILD_ROOT"' "$TMP/webproxy_telemetry_install.sh" || die '0.11.14 build-root traverse fix отсутствует.'
grep -Fq 'runuser -u tproxy -- test -x "$BUILD_ROOT"' "$TMP/webproxy_telemetry_install.sh" || die '0.11.14 tproxy traverse preflight отсутствует.'
install -m 0755 -o root -g root "$TMP/webproxy_telemetry_install.sh" "$TELEMETRY"

if [[ -x /usr/local/bin/tproxy-server && -f /usr/local/lib/mtpadmin/tproxy-server.commit && -f /etc/tproxy-server/config.json && -f /etc/tproxy-server/profiles.json ]]; then
  info 'Завершаю WEB client telemetry repair 0.11.14...'
  if ! bash "$TELEMETRY"; then
    die 'MTPADMIN 0.11.14 установлен, но WEB client telemetry repair не завершился. Основные сервисы не откатываются; смотрите журнал Update Center.'
  fi
fi

[[ -x /usr/local/lib/mtpadmin/update_check.py ]] && /usr/local/lib/mtpadmin/update_check.py >/dev/null 2>&1 || true
if ! /usr/local/bin/mtpadmin doctor; then
  die 'MTPADMIN 0.11.14 установлен, но итоговый doctor обнаружил failure. Версия не откатывается автоматически; исправьте указанную проверку.'
fi

ok 'MTPADMIN 0.11.14 updater завершён: tproxy build-root traverse + disk-backed WEB telemetry repair PASS.'
