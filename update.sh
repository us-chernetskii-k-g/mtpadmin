#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.11.0'
BASE_010_COMMIT='2d84178680bba7c540bf5e890aeb2aa561e6cd8f'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_010_COMMIT/update.sh" -o "$TMP/update-010.sh" || die 'Не удалось скачать базовый update 0.10.0.'

python3 - "$TMP/update-010.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')

# Promote the proven 0.10.0 wrapper to 0.11.0.
s=s.replace('0.10.0','0.11.0')

old='''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/37-analytics-plus.py" -o "$TMP/analytics-plus-extension.py" || die 'Не удалось скачать analytics-plus extension'\n  python3 - "$TMP/mtpadmin_web.py" "$TMP/world-map-extension.py" "$TMP/analytics-extension.py" "$TMP/analytics-plus-extension.py" <<'PYWEBEXT'\n'''
new='''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/37-analytics-plus.py" -o "$TMP/analytics-plus-extension.py" || die 'Не удалось скачать analytics-plus extension'\n  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/38-operations.py" -o "$TMP/operations-extension.py" || die 'Не удалось скачать operations extension'\n  python3 - "$TMP/mtpadmin_web.py" "$TMP/world-map-extension.py" "$TMP/analytics-extension.py" "$TMP/analytics-plus-extension.py" "$TMP/operations-extension.py" <<'PYWEBEXT'\n'''
if s.count(old)!=1:
    raise SystemExit('unexpected 0.10 web extension block')
s=s.replace(old,new,1)
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-010.sh" || die '0.11.0 сформировал невалидный core updater.'
grep -q "VERSION='0.11.0'" "$TMP/update-010.sh" || die 'Версия core updater не обновилась.'
grep -q '38-operations.py' "$TMP/update-010.sh" || die 'Operations extension не встроен.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 bash "$TMP/update-010.sh" || die 'Вложенная сборка update-engine не прошла.'
    bash -n scripts/webproxy_install.sh 2>/dev/null || true
    ok 'Nested 0.11.0 updater transformation PASS'
    exit 0
    ;;
  1)
    ok 'Update wrapper 0.11.0 transformation PASS'
    exit 0
    ;;
esac

# First update MTPADMIN itself using the already-proven seamless core path.
bash "$TMP/update-010.sh"

# Then provision/update the official Telegram WEB transport relay. This does not
# restart TeleMT; it creates/reuses a dedicated TeleMT source and applies it via API reload.
curl -fsSL --retry 3 "$ROOT/main/scripts/webproxy_install.sh" -o "$TMP/webproxy_install.sh" || die 'Не удалось скачать WEB Proxy installer.'
chmod 0700 "$TMP/webproxy_install.sh"
bash -n "$TMP/webproxy_install.sh" || die 'WEB Proxy installer syntax invalid.'
install -m 0700 -o root -g root "$TMP/webproxy_install.sh" /usr/local/lib/mtpadmin/webproxy_install.sh

# QR generation is local; absence is non-fatal for transport, but install it when possible.
if ! command -v qrencode >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
  info 'Устанавливаю qrencode для локальных WEB QR-кодов...'
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode >/dev/null || true
fi

bash /usr/local/lib/mtpadmin/webproxy_install.sh

python3 - "$VERSION" <<'PY' || true
import sqlite3,sys,time
try:
    with sqlite3.connect('/var/lib/mtpadmin/stats.db',timeout=5) as c:
        c.execute('''CREATE TABLE IF NOT EXISTS system_events(id INTEGER PRIMARY KEY AUTOINCREMENT,ts INTEGER NOT NULL,category TEXT NOT NULL,action TEXT NOT NULL,actor TEXT,detail TEXT)''')
        c.execute('INSERT INTO system_events(ts,category,action,actor,detail) VALUES(?,?,?,?,?)',(int(time.time()),'webproxy','WEB Proxy provisioned','update.sh','MTPADMIN '+sys.argv[1]))
        c.commit()
except Exception:
    pass
PY

ok 'MTPADMIN 0.11.0 Operations + Telegram WEB Proxy установлен.'
