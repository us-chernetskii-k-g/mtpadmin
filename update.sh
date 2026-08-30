#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.11.5'
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
s=s.replace('0.9.0','0.11.5')
old='''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/36-analytics.py" -o "$TMP/analytics-extension.py" || die 'Не удалось скачать analytics extension'\n  python3 - "$TMP/mtpadmin_web.py" "$TMP/world-map-extension.py" "$TMP/analytics-extension.py" <<'PYWEBEXT'\n'''
new='''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/36-analytics.py" -o "$TMP/analytics-extension.py" || die 'Не удалось скачать analytics extension'\n  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/37-analytics-plus.py" -o "$TMP/analytics-plus-extension.py" || die 'Не удалось скачать analytics-plus extension'\n  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/38-operations.py" -o "$TMP/operations-extension.py" || die 'Не удалось скачать operations extension'\n  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/39-compact-ui.py" -o "$TMP/compact-ui-extension.py" || die 'Не удалось скачать compact UI extension'\n  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/40-async-update-ui.py" -o "$TMP/async-update-ui-extension.py" || die 'Не удалось скачать async update UI extension'\n  python3 - "$TMP/mtpadmin_web.py" "$TMP/world-map-extension.py" "$TMP/analytics-extension.py" "$TMP/analytics-plus-extension.py" "$TMP/operations-extension.py" "$TMP/compact-ui-extension.py" "$TMP/async-update-ui-extension.py" <<'PYWEBEXT'\n'''
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

bash -n "$TMP/update-090.sh" || die '0.11.5 сформировал невалидный updater.'
grep -q "VERSION='0.11.5'" "$TMP/update-090.sh" || die 'Версия updater не обновилась.'
grep -q '38-operations.py' "$TMP/update-090.sh" || die 'Operations extension не встроен.'
grep -q '39-compact-ui.py' "$TMP/update-090.sh" || die 'Compact UI extension не встроен.'
grep -q '40-async-update-ui.py' "$TMP/update-090.sh" || die 'Async update UI extension не встроен.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2) MTPADMIN_BOOTSTRAP_TEST=2 bash "$TMP/update-090.sh" || die 'Вложенная сборка update-engine не прошла.'; ok 'Nested 0.11.5 updater transformation PASS'; exit 0 ;;
  1) ok 'Update wrapper 0.11.5 transformation PASS'; exit 0 ;;
esac

# Core/web first. Incomplete WEB Proxy provisioning remains warning-only until
# the resumable installer below finishes successfully.
bash "$TMP/update-090.sh"

CACHE_BUST="${VERSION}-$(date +%s)"
for file in webproxy_install.sh update_check.py component_update.sh; do
  curl -fsSL --retry 3 "$ROOT/main/scripts/$file?mtpadmin=$CACHE_BUST" -o "$TMP/$file" || die "Не удалось скачать scripts/$file"
done

# Upstream permission tests intentionally create a 0444 profiles fixture.
# The installer uses umask 077 for production secrets, so without this narrow
# test-only override the fixture becomes 0400 and the upstream test gives a
# false failure. Production profiles.json remains 0400.
python3 - "$TMP/webproxy_install.sh" <<'PYFIX'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
old=r'''(cd "$src" && runuser -u tproxy -- env HOME="$buildhome" GOCACHE="$buildhome/gocache" GOMODCACHE="$buildhome/gomod" GOMAXPROCS=1 "$go_binary" test -p=1 ./...)'''
new=r'''(cd "$src" && runuser -u tproxy -- env HOME="$buildhome" GOCACHE="$buildhome/gocache" GOMODCACHE="$buildhome/gomod" GOMAXPROCS=1 sh -c 'umask 022; exec "$@"' sh "$go_binary" test -p=1 ./...)'''
if s.count(old)!=1:
    raise SystemExit('unexpected tproxy upstream test command')
p.write_text(s.replace(old,new,1),encoding='utf-8')
PYFIX

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

fix_go_toolchain_access(){
  local gobin goroot fixed=0
  id tproxy >/dev/null 2>&1 || return 0
  for gobin in /opt/go*/bin/go; do
    [[ -x "$gobin" ]] || continue
    if runuser -u tproxy -- "$gobin" version >/dev/null 2>&1; then continue; fi
    goroot=${gobin%/bin/go}
    info "Исправляю права чтения Go toolchain для пользователя tproxy: $goroot"
    chmod a+rx /opt "$goroot" "$goroot/bin" 2>/dev/null || true
    chmod -R a+rX "$goroot" || die "Не удалось исправить права $goroot"
    runuser -u tproxy -- "$gobin" version >/dev/null 2>&1 || die "Go toolchain по-прежнему недоступен пользователю tproxy: $gobin"
    fixed=1
  done
  (( fixed == 0 )) || ok 'Go toolchain доступен непривилегированному tproxy без прав на запись'
}

fix_go_toolchain_access

if ! bash /usr/local/lib/mtpadmin/webproxy_install.sh; then
  fix_go_toolchain_access
  info 'Повторяю WEB Proxy provisioning после проверки Go toolchain...'
  bash /usr/local/lib/mtpadmin/webproxy_install.sh
fi

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
ok 'MTPADMIN 0.11.5 установлен: Compact UI + Async Update Center + Telegram WEB Proxy.'
