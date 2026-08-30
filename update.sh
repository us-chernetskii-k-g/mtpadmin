#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
VERSION='0.5.0'
RAW_BASE='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main'
STATE='/etc/mtpadmin/state.env'
STATSSVC='mtpadmin-stats.service'
SERVICE='mtpadmin-telemt.service'
WEBSVC='mtpadmin-web.service'
WEBAPP='/usr/local/lib/mtpadmin/web/mtpadmin_web.py'
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/var/backups/mtpadmin/repo-update-$STAMP"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ok(){ echo "[PASS] $*"; }
warn(){ echo "[WARN] $*"; }
die(){ echo "[FAIL] $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запустите через sudo/root.'
[[ -f "$STATE" ]] || die 'MTPADMIN не установлен.'
systemctl is-active --quiet "$SERVICE" || die 'TeleMT сейчас не работает; update остановлен.'
mkdir -p "$BACKUP"
for f in \
 /usr/local/bin/mtpadmin \
 /usr/local/lib/mtpadmin/stats_collector.py \
 /usr/local/lib/mtpadmin/user_config.py \
 /usr/local/lib/mtpadmin/render_config.sh \
 /usr/local/lib/mtpadmin/geo_update.sh \
 "$WEBAPP" \
 "$STATE"; do
  [[ -e "$f" ]] && cp -a "$f" "$BACKUP/$(basename "$f").before"
done
[[ -f /var/lib/mtpadmin/stats.db ]] && sqlite3 /var/lib/mtpadmin/stats.db ".backup '$BACKUP/stats.db.before'" || true
ok "Backup: $BACKUP"

fetch(){ curl -fsSL --retry 3 "$RAW_BASE/$1" -o "$2" || die "Не удалось скачать $1"; }
: > "$TMP/mtpadmin"
for part in 00-core.sh 10-sources.sh 20-admin.sh 30-menu.sh; do
  curl -fsSL --retry 3 "$RAW_BASE/src/mtpadmin.d/$part" >> "$TMP/mtpadmin" || die "Не удалось скачать CLI fragment $part"
done
: > "$TMP/stats_collector.py"
for part in 00-core.py 10-runtime.py; do
  curl -fsSL --retry 3 "$RAW_BASE/src/stats_collector.d/$part" >> "$TMP/stats_collector.py" || die "Не удалось скачать collector fragment $part"
done
fetch src/user_config.py "$TMP/user_config.py"
fetch scripts/render_config.sh "$TMP/render_config.sh"
fetch scripts/geo_update.sh "$TMP/geo_update.sh"

WEB_INSTALLED=0
if [[ -f "$WEBAPP" ]] || systemctl cat "$WEBSVC" >/dev/null 2>&1; then
  WEB_INSTALLED=1
  : > "$TMP/mtpadmin_web.py"
  for part in 00-core.py 10-ui.py 20-pages.py 30-actions.py; do
    curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/$part" >> "$TMP/mtpadmin_web.py" || die "Не удалось скачать web fragment $part"
  done
fi

bash -n "$TMP/mtpadmin"
bash -n "$TMP/render_config.sh"
bash -n "$TMP/geo_update.sh"
python3 -m py_compile "$TMP/stats_collector.py" "$TMP/user_config.py"
(( WEB_INSTALLED == 0 )) || python3 -m py_compile "$TMP/mtpadmin_web.py"
ok 'Новые файлы прошли проверку'

install -m 0700 "$TMP/mtpadmin" /usr/local/bin/mtpadmin
install -m 0700 "$TMP/stats_collector.py" /usr/local/lib/mtpadmin/stats_collector.py
install -m 0700 "$TMP/user_config.py" /usr/local/lib/mtpadmin/user_config.py
install -m 0700 "$TMP/render_config.sh" /usr/local/lib/mtpadmin/render_config.sh
install -m 0700 "$TMP/geo_update.sh" /usr/local/lib/mtpadmin/geo_update.sh
if (( WEB_INSTALLED == 1 )); then
  install -d -m 0755 /usr/local/lib/mtpadmin/web
  install -m 0700 "$TMP/mtpadmin_web.py" "$WEBAPP"
fi

python3 - <<'PY'
from pathlib import Path
p=Path('/etc/mtpadmin/state.env')
s=p.read_text()
lines=[]; done=False
for line in s.splitlines():
    if line.startswith('MTPADMIN_VERSION='):
        lines.append("MTPADMIN_VERSION='0.5.0'"); done=True
    else: lines.append(line)
if not done: lines.append("MTPADMIN_VERSION='0.5.0'")
p.write_text('\n'.join(lines)+'\n')
PY
chmod 0600 "$STATE"

rollback_core(){
  [[ -f "$BACKUP/mtpadmin.before" ]] && cp -a "$BACKUP/mtpadmin.before" /usr/local/bin/mtpadmin
  [[ -f "$BACKUP/stats_collector.py.before" ]] && cp -a "$BACKUP/stats_collector.py.before" /usr/local/lib/mtpadmin/stats_collector.py
  [[ -f "$BACKUP/user_config.py.before" ]] && cp -a "$BACKUP/user_config.py.before" /usr/local/lib/mtpadmin/user_config.py
  [[ -f "$BACKUP/render_config.sh.before" ]] && cp -a "$BACKUP/render_config.sh.before" /usr/local/lib/mtpadmin/render_config.sh
  [[ -f "$BACKUP/geo_update.sh.before" ]] && cp -a "$BACKUP/geo_update.sh.before" /usr/local/lib/mtpadmin/geo_update.sh
  [[ -f "$BACKUP/state.env.before" ]] && cp -a "$BACKUP/state.env.before" "$STATE"
}

if ! systemctl restart "$STATSSVC"; then
  warn 'Новый collector не запустился — rollback'
  rollback_core
  systemctl restart "$STATSSVC" || true
  die 'Обновление отменено.'
fi

if (( WEB_INSTALLED == 1 )); then
  if ! systemctl restart "$WEBSVC"; then
    warn 'Новый web backend не запустился — возвращаю предыдущую web-версию'
    [[ -f "$BACKUP/mtpadmin_web.py.before" ]] && cp -a "$BACKUP/mtpadmin_web.py.before" "$WEBAPP"
    systemctl restart "$WEBSVC" || true
    rollback_core
    systemctl restart "$STATSSVC" || true
    die 'Обновление отменено.'
  fi
  sleep 1
  curl -fsS --max-time 5 -H 'X-MTPADMIN-User: local-health' http://127.0.0.1:9199/healthz >/dev/null || {
    warn 'Web healthcheck failed — rollback'
    [[ -f "$BACKUP/mtpadmin_web.py.before" ]] && cp -a "$BACKUP/mtpadmin_web.py.before" "$WEBAPP"
    systemctl restart "$WEBSVC" || true
    rollback_core
    systemctl restart "$STATSSVC" || true
    die 'Обновление отменено.'
  }
fi

sleep 4
systemctl is-active --quiet "$SERVICE" || die 'TeleMT неожиданно остановился.'
systemctl is-active --quiet "$STATSSVC" || die 'Collector не работает.'
ok "MTPADMIN обновлён до $VERSION; TeleMT не перезапускался"
(( WEB_INSTALLED == 0 )) || ok 'Web backend также обновлён'
mtpadmin doctor
