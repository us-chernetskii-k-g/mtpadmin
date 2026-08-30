#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
VERSION='0.6.0'
RAW_BASE='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main'
STATE='/etc/mtpadmin/state.env'
SERVICE='mtpadmin-telemt.service'
STATSSVC='mtpadmin-stats.service'
SCANNERSVC='mtpadmin-scanner.service'
SCANNERSVC_FILE='/etc/systemd/system/mtpadmin-scanner.service'
GUARD='/usr/local/lib/mtpadmin/scanner_guard.py'
WEBSVC='mtpadmin-web.service'
WEBSVC_FILE='/etc/systemd/system/mtpadmin-web.service'
WEBAPP='/usr/local/lib/mtpadmin/web/mtpadmin_web.py'
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/var/backups/mtpadmin/repo-update-$STAMP"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }
die(){ echo "[FAIL] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запустите через sudo/root.'
[[ -f "$STATE" ]] || die 'MTPADMIN не установлен.'
systemctl is-active --quiet "$SERVICE" || die 'TeleMT сейчас не работает; update остановлен.'
mkdir -p "$BACKUP"
for f in /usr/local/bin/mtpadmin /usr/local/lib/mtpadmin/stats_collector.py /usr/local/lib/mtpadmin/user_config.py /usr/local/lib/mtpadmin/render_config.sh /usr/local/lib/mtpadmin/geo_update.sh "$GUARD" "$SCANNERSVC_FILE" "$WEBAPP" "$WEBSVC_FILE" "$STATE"; do
  [[ -e "$f" ]] && cp -a "$f" "$BACKUP/$(basename "$f").before"
done
[[ -f /var/lib/mtpadmin/stats.db ]] && sqlite3 /var/lib/mtpadmin/stats.db ".backup '$BACKUP/stats.db.before'" || true
ok "Backup: $BACKUP"

if ! command -v nft >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    info 'Устанавливаю nftables для Scanner Guard...'
    apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y nftables >/dev/null
  else
    die 'Scanner Guard требует nftables (команда nft).'
  fi
fi
command -v nft >/dev/null 2>&1 || die 'nftables не установлен.'

fetch(){ curl -fsSL --retry 3 "$RAW_BASE/$1" -o "$2" || die "Не удалось скачать $1"; }
: > "$TMP/mtpadmin"
for part in 00-core.sh 10-sources.sh 20-admin.sh 22-guard.sh 25-doctor-runtime.sh 29-guard-dispatch.sh 30-menu.sh; do
  curl -fsSL --retry 3 "$RAW_BASE/src/mtpadmin.d/$part" >> "$TMP/mtpadmin" || die "Не удалось скачать CLI fragment $part"
done
: > "$TMP/stats_collector.py"
for part in 00-core.py 10-runtime.py; do
  curl -fsSL --retry 3 "$RAW_BASE/src/stats_collector.d/$part" >> "$TMP/stats_collector.py" || die "Не удалось скачать collector fragment $part"
done
fetch src/user_config.py "$TMP/user_config.py"
fetch src/scanner_guard.py "$TMP/scanner_guard.py"
fetch scripts/render_config.sh "$TMP/render_config.sh"
fetch scripts/geo_update.sh "$TMP/geo_update.sh"

WEB_INSTALLED=0
if [[ -f "$WEBAPP" ]] || systemctl cat "$WEBSVC" >/dev/null 2>&1; then
  WEB_INSTALLED=1
  : > "$TMP/mtpadmin_web.py"
  for part in 00-core.py 05-version.py 10-ui.py 15-guard-ui.py 20-pages.py 25-guard-route.py 30-actions.py; do
    curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/$part" >> "$TMP/mtpadmin_web.py" || die "Не удалось скачать web fragment $part"
  done
fi

bash -n "$TMP/mtpadmin"
bash -n "$TMP/render_config.sh"
bash -n "$TMP/geo_update.sh"
python3 -m py_compile "$TMP/stats_collector.py" "$TMP/user_config.py" "$TMP/scanner_guard.py"
(( WEB_INSTALLED == 0 )) || python3 -m py_compile "$TMP/mtpadmin_web.py"
python3 "$TMP/scanner_guard.py" selftest
ok 'Новые файлы и Scanner Guard прошли проверку'

install -m 0700 "$TMP/mtpadmin" /usr/local/bin/mtpadmin
install -m 0700 "$TMP/stats_collector.py" /usr/local/lib/mtpadmin/stats_collector.py
install -m 0700 "$TMP/user_config.py" /usr/local/lib/mtpadmin/user_config.py
install -m 0700 "$TMP/scanner_guard.py" "$GUARD"
install -m 0700 "$TMP/render_config.sh" /usr/local/lib/mtpadmin/render_config.sh
install -m 0700 "$TMP/geo_update.sh" /usr/local/lib/mtpadmin/geo_update.sh
if (( WEB_INSTALLED == 1 )); then
  install -d -m 0755 /usr/local/lib/mtpadmin/web
  install -m 0700 "$TMP/mtpadmin_web.py" "$WEBAPP"
fi

python3 - <<'PY'
from pathlib import Path
p=Path('/etc/mtpadmin/state.env'); lines=[]; done=False
for line in p.read_text().splitlines():
    if line.startswith('MTPADMIN_VERSION='): lines.append("MTPADMIN_VERSION='0.6.0'"); done=True
    else: lines.append(line)
if not done: lines.append("MTPADMIN_VERSION='0.6.0'")
p.write_text('\n'.join(lines)+'\n')
PY
chmod 0600 "$STATE"

cat > "$SCANNERSVC_FILE" <<'EOF'
[Unit]
Description=MTPADMIN Scanner Guard observer and manual ban controller
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/python3 /usr/local/lib/mtpadmin/scanner_guard.py worker
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
ReadOnlyPaths=/etc/mtpadmin
ReadWritePaths=/var/lib/mtpadmin
UMask=0077
MemoryMax=96M
TasksMax=32

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$SCANNERSVC_FILE"

if (( WEB_INSTALLED == 1 )) && [[ -f "$WEBSVC_FILE" ]]; then
  if grep -q '^RestrictAddressFamilies=' "$WEBSVC_FILE"; then
    sed -i 's/^RestrictAddressFamilies=.*/RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK/' "$WEBSVC_FILE"
  else
    sed -i '/^\[Service\]/a RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK' "$WEBSVC_FILE"
  fi
fi

rollback(){
  warn 'Выполняю rollback файлов MTPADMIN'
  [[ -f "$BACKUP/mtpadmin.before" ]] && cp -a "$BACKUP/mtpadmin.before" /usr/local/bin/mtpadmin
  [[ -f "$BACKUP/stats_collector.py.before" ]] && cp -a "$BACKUP/stats_collector.py.before" /usr/local/lib/mtpadmin/stats_collector.py
  [[ -f "$BACKUP/user_config.py.before" ]] && cp -a "$BACKUP/user_config.py.before" /usr/local/lib/mtpadmin/user_config.py
  [[ -f "$BACKUP/scanner_guard.py.before" ]] && cp -a "$BACKUP/scanner_guard.py.before" "$GUARD"
  [[ -f "$BACKUP/render_config.sh.before" ]] && cp -a "$BACKUP/render_config.sh.before" /usr/local/lib/mtpadmin/render_config.sh
  [[ -f "$BACKUP/geo_update.sh.before" ]] && cp -a "$BACKUP/geo_update.sh.before" /usr/local/lib/mtpadmin/geo_update.sh
  [[ -f "$BACKUP/mtpadmin_web.py.before" ]] && cp -a "$BACKUP/mtpadmin_web.py.before" "$WEBAPP"
  [[ -f "$BACKUP/mtpadmin-web.service.before" ]] && cp -a "$BACKUP/mtpadmin-web.service.before" "$WEBSVC_FILE"
  [[ -f "$BACKUP/mtpadmin-scanner.service.before" ]] && cp -a "$BACKUP/mtpadmin-scanner.service.before" "$SCANNERSVC_FILE"
  [[ -f "$BACKUP/state.env.before" ]] && cp -a "$BACKUP/state.env.before" "$STATE"
  if [[ ! -f "$BACKUP/mtpadmin-scanner.service.before" ]]; then
    systemctl disable --now "$SCANNERSVC" >/dev/null 2>&1 || true
    rm -f "$SCANNERSVC_FILE" "$GUARD"
    nft delete table inet mtpadmin_guard >/dev/null 2>&1 || true
  fi
  systemctl daemon-reload || true
  systemctl restart "$STATSSVC" || true
  (( WEB_INSTALLED == 0 )) || systemctl restart "$WEBSVC" || true
  [[ -f "$BACKUP/mtpadmin-scanner.service.before" ]] && systemctl restart "$SCANNERSVC" || true
}

systemctl daemon-reload
systemctl restart "$STATSSVC" || { rollback; die 'Новый collector не запустился.'; }
if (( WEB_INSTALLED == 1 )); then
  systemctl restart "$WEBSVC" || { rollback; die 'Новый web backend не запустился.'; }
  sleep 1
  curl -fsS --max-time 5 -H 'X-MTPADMIN-User: local-health' http://127.0.0.1:9199/healthz >/dev/null || { rollback; die 'Web healthcheck failed.'; }
fi
systemctl enable --now "$SCANNERSVC" >/dev/null || { rollback; die 'Scanner Guard service не запустился.'; }
sleep 4
systemctl is-active --quiet "$SCANNERSVC" || { journalctl -u "$SCANNERSVC" -n 80 --no-pager; rollback; die 'Scanner Guard не активен.'; }
nft list table inet mtpadmin_guard >/dev/null 2>&1 || { journalctl -u "$SCANNERSVC" -n 80 --no-pager; rollback; die 'Scanner Guard nftables table не создана.'; }
GH=$(sqlite3 /var/lib/mtpadmin/stats.db "SELECT value FROM scanner_meta WHERE key='heartbeat';" 2>/dev/null || true); NOW=$(date +%s)
[[ "$GH" =~ ^[0-9]+$ ]] && (( NOW-GH < 40 )) || { journalctl -u "$SCANNERSVC" -n 80 --no-pager; rollback; die 'Scanner Guard heartbeat отсутствует.'; }
systemctl is-active --quiet "$SERVICE" || { rollback; die 'TeleMT неожиданно остановился.'; }
systemctl is-active --quiet "$STATSSVC" || { rollback; die 'Collector не работает.'; }
ok "MTPADMIN обновлён до $VERSION; TeleMT не перезапускался"
ok 'Scanner Guard активен; autoban=OFF'
(( WEB_INSTALLED == 0 )) || ok 'Web backend обновлён'
mtpadmin doctor
