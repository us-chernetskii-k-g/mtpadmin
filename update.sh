#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.11.2'
BASE_090_COMMIT='e7475ec650eed8b85aebb2311b74a3ef09a115b2'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_090_COMMIT/update.sh" -o "$TMP/update-090.sh" || die 'Не удалось скачать базовый update 0.9.0.'

python3 - "$TMP/update-090.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
s=s.replace('0.9.0','0.11.2')
old='''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/36-analytics.py" -o "$TMP/analytics-extension.py" || die 'Не удалось скачать analytics extension'\n  python3 - "$TMP/mtpadmin_web.py" "$TMP/world-map-extension.py" "$TMP/analytics-extension.py" <<'PYWEBEXT'\n'''
new='''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/36-analytics.py" -o "$TMP/analytics-extension.py" || die 'Не удалось скачать analytics extension'\n  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/37-analytics-plus.py" -o "$TMP/analytics-plus-extension.py" || die 'Не удалось скачать analytics-plus extension'\n  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/38-operations.py" -o "$TMP/operations-extension.py" || die 'Не удалось скачать operations extension'\n  python3 - "$TMP/mtpadmin_web.py" "$TMP/world-map-extension.py" "$TMP/analytics-extension.py" "$TMP/analytics-plus-extension.py" "$TMP/operations-extension.py" <<'PYWEBEXT'\n'''
if s.count(old)!=1: raise SystemExit('unexpected 0.9 web extension block')
s=s.replace(old,new,1)
needle='bash "$TMP/update-bootstrap.sh"\n'
if s.count(needle)!=1: raise SystemExit('unexpected final bootstrap invocation')
logger=r"""bash "$TMP/update-bootstrap.sh"
python3 - "$VERSION" <<'PYEV' || true
import sqlite3,sys,time
try:
    with sqlite3.connect('/var/lib/mtpadmin/stats.db',timeout=5) as c:
        c.execute('''CREATE TABLE IF NOT EXISTS system_events(id INTEGER PRIMARY KEY AUTOINCREMENT,ts INTEGER NOT NULL,category TEXT NOT NULL,action TEXT NOT NULL,actor TEXT,detail TEXT)''')
        c.execute('CREATE INDEX IF NOT EXISTS idx_system_events_ts ON system_events(ts DESC)')
        c.execute('INSERT INTO system_events(ts,category,action,actor,detail) VALUES(?,?,?,?,?)',(int(time.time()),'update','MTPADMIN updated','update.sh','version '+sys.argv[1]))
        c.commit()
except Exception: pass
PYEV
"""
s=s.replace(needle,logger,1)
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-090.sh" || die '0.11.2 сформировал невалидный updater.'
grep -q "VERSION='0.11.2'" "$TMP/update-090.sh" || die 'Версия updater не обновилась.'
grep -q '38-operations.py' "$TMP/update-090.sh" || die 'Operations extension не встроен.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2) MTPADMIN_BOOTSTRAP_TEST=2 bash "$TMP/update-090.sh" || die 'Вложенная сборка update-engine не прошла.'; ok 'Nested 0.11.2 updater transformation PASS'; exit 0 ;;
  1) ok 'Update wrapper 0.11.2 transformation PASS'; exit 0 ;;
esac

# Core/web first. Incomplete WEB Proxy provisioning remains warning-only until
# the resumable installer below finishes successfully.
bash "$TMP/update-090.sh"

for file in webproxy_install.sh update_check.py component_update.sh; do
  curl -fsSL --retry 3 "$ROOT/main/scripts/$file" -o "$TMP/$file" || die "Не удалось скачать scripts/$file"
done
bash -n "$TMP/webproxy_install.sh" || die 'WEB Proxy installer syntax invalid.'
bash -n "$TMP/component_update.sh" || die 'Component updater syntax invalid.'
python3 -m py_compile "$TMP/update_check.py" || die 'Update checker syntax invalid.'
install -d -m 0755 /usr/local/lib/mtpadmin
install -m 0700 -o root -g root "$TMP/webproxy_install.sh" /usr/local/lib/mtpadmin/webproxy_install.sh
install -m 0700 -o root -g root "$TMP/component_update.sh" /usr/local/lib/mtpadmin/component_update.sh
install -m 0755 -o root -g root "$TMP/update_check.py" /usr/local/lib/mtpadmin/update_check.py

cat > /etc/systemd/system/mtpadmin-update-check.service <<'EOF'
[Unit]
Description=MTPADMIN component update availability check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/lib/mtpadmin/update_check.py
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/mtpadmin
RestrictAddressFamilies=AF_INET AF_INET6
EOF
cat > /etc/systemd/system/mtpadmin-update-check.timer <<'EOF'
[Unit]
Description=Check MTPADMIN/TeleMT/WEB Proxy updates

[Timer]
OnBootSec=2min
OnUnitActiveSec=6h
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
chmod 0644 /etc/systemd/system/mtpadmin-update-check.service /etc/systemd/system/mtpadmin-update-check.timer
systemctl daemon-reload
systemctl enable --now mtpadmin-update-check.timer >/dev/null

if ! command -v qrencode >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
  info 'Устанавливаю qrencode для локальных QR-кодов...'
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode >/dev/null || true
fi

# Resume/retry WEB Proxy provisioning. Existing WEB_PROXY source is reused
# without secret rotation, so a failed first install is safe to repeat.
bash /usr/local/lib/mtpadmin/webproxy_install.sh

/usr/local/lib/mtpadmin/update_check.py >/dev/null 2>&1 || true

python3 - "$VERSION" <<'PY' || true
import sqlite3,sys,time
try:
    with sqlite3.connect('/var/lib/mtpadmin/stats.db',timeout=5) as c:
        c.execute('INSERT INTO system_events(ts,category,action,actor,detail) VALUES(?,?,?,?,?)',(int(time.time()),'webproxy','WEB Proxy provisioned','update.sh','MTPADMIN '+sys.argv[1]))
        c.commit()
except Exception: pass
PY

echo
info 'Финальная проверка MTPADMIN + WEB Proxy...'
/usr/local/bin/mtpadmin doctor
ok 'MTPADMIN 0.11.2 установлен: Operations + Update Center + Telegram WEB Proxy.'
