#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
VERSION='0.4.4'
RAW_BASE='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main'
STATE='/etc/mtpadmin/state.env'
STATSSVC='mtpadmin-stats.service'
SERVICE='mtpadmin-telemt.service'
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
bash -n "$TMP/mtpadmin"
bash -n "$TMP/render_config.sh"
bash -n "$TMP/geo_update.sh"
python3 -m py_compile "$TMP/stats_collector.py" "$TMP/user_config.py"
ok 'Новые файлы прошли проверку'

install -m 0700 "$TMP/mtpadmin" /usr/local/bin/mtpadmin
install -m 0700 "$TMP/stats_collector.py" /usr/local/lib/mtpadmin/stats_collector.py
install -m 0700 "$TMP/user_config.py" /usr/local/lib/mtpadmin/user_config.py
install -m 0700 "$TMP/render_config.sh" /usr/local/lib/mtpadmin/render_config.sh
install -m 0700 "$TMP/geo_update.sh" /usr/local/lib/mtpadmin/geo_update.sh
python3 - <<'PY'
from pathlib import Path
p=Path('/etc/mtpadmin/state.env')
s=p.read_text()
lines=[]; done=False
for line in s.splitlines():
    if line.startswith('MTPADMIN_VERSION='):
        lines.append("MTPADMIN_VERSION='0.4.4'"); done=True
    else: lines.append(line)
if not done: lines.append("MTPADMIN_VERSION='0.4.4'")
p.write_text('\n'.join(lines)+'\n')
PY
chmod 0600 "$STATE"

if ! systemctl restart "$STATSSVC"; then
  warn 'Новый collector не запустился — rollback'
  [[ -f "$BACKUP/mtpadmin.before" ]] && cp -a "$BACKUP/mtpadmin.before" /usr/local/bin/mtpadmin
  [[ -f "$BACKUP/stats_collector.py.before" ]] && cp -a "$BACKUP/stats_collector.py.before" /usr/local/lib/mtpadmin/stats_collector.py
  [[ -f "$BACKUP/user_config.py.before" ]] && cp -a "$BACKUP/user_config.py.before" /usr/local/lib/mtpadmin/user_config.py
  [[ -f "$BACKUP/render_config.sh.before" ]] && cp -a "$BACKUP/render_config.sh.before" /usr/local/lib/mtpadmin/render_config.sh
  [[ -f "$BACKUP/geo_update.sh.before" ]] && cp -a "$BACKUP/geo_update.sh.before" /usr/local/lib/mtpadmin/geo_update.sh
  [[ -f "$BACKUP/state.env.before" ]] && cp -a "$BACKUP/state.env.before" "$STATE"
  systemctl restart "$STATSSVC" || true
  die 'Обновление отменено.'
fi
sleep 4
systemctl is-active --quiet "$SERVICE" || die 'TeleMT неожиданно остановился.'
systemctl is-active --quiet "$STATSSVC" || die 'Collector не работает.'
ok "MTPADMIN обновлён до $VERSION; TeleMT не перезапускался"
mtpadmin doctor
