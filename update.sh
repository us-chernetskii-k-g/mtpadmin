#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
VERSION='0.7.0'
RAW_BASE='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main'
STATE='/etc/mtpadmin/state.env'
SERVICE='mtpadmin-telemt.service'
STATSSVC='mtpadmin-stats.service'
SCANNERSVC='mtpadmin-scanner.service'
SCANNERSVC_FILE='/etc/systemd/system/mtpadmin-scanner.service'
STATS_DROPIN='/etc/systemd/system/mtpadmin-stats.service.d/mtpadmin-hot-reload.conf'
GUARD='/usr/local/lib/mtpadmin/scanner_guard.py'
WEBAPP='/usr/local/lib/mtpadmin/web/mtpadmin_web.py'
WEB_RELEASES='/usr/local/lib/mtpadmin/web/releases'
WEB_RUNTIME='/etc/mtpadmin/web-runtime.env'
WEB_ALIAS='/etc/systemd/system/mtpadmin-web.service'
WEB_BLUE_FILE='/etc/systemd/system/mtpadmin-web-blue.service'
WEB_GREEN_FILE='/etc/systemd/system/mtpadmin-web-green.service'
CADDYFILE='/etc/caddy/Caddyfile'
WEB_BEGIN='# BEGIN MTPADMIN WEB - managed by mtpadmin'
WEB_END='# END MTPADMIN WEB - managed by mtpadmin'
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
# shellcheck disable=SC1090
source "$STATE"
OLD_VERSION="${MTPADMIN_VERSION:-0.0.0}"
mkdir -p "$BACKUP" /var/backups/mtpadmin

backup_file(){ local f="$1" n="${2:-$(basename "$1")}"; [[ -e "$f" || -L "$f" ]] && cp -aL "$f" "$BACKUP/$n.before" || true; }
backup_file /usr/local/bin/mtpadmin mtpadmin
backup_file /usr/local/lib/mtpadmin/stats_collector.py stats_collector.py
backup_file /usr/local/lib/mtpadmin/user_config.py user_config.py
backup_file /usr/local/lib/mtpadmin/render_config.sh render_config.sh
backup_file /usr/local/lib/mtpadmin/geo_update.sh geo_update.sh
backup_file "$GUARD" scanner_guard.py
backup_file "$SCANNERSVC_FILE" mtpadmin-scanner.service
backup_file "$STATS_DROPIN" mtpadmin-hot-reload.conf
backup_file "$WEBAPP" mtpadmin_web.py
backup_file "$WEB_ALIAS" mtpadmin-web.service
backup_file "$WEB_BLUE_FILE" mtpadmin-web-blue.service
backup_file "$WEB_GREEN_FILE" mtpadmin-web-green.service
backup_file "$WEB_RUNTIME" web-runtime.env
backup_file "$STATE" state.env
[[ -f "$CADDYFILE" ]] && backup_file "$CADDYFILE" Caddyfile
if [[ -f /var/lib/mtpadmin/stats.db ]]; then
  sqlite3 /var/lib/mtpadmin/stats.db ".backup '$BACKUP/stats.db.before'" || die 'Не удалось создать backup stats.db.'
fi
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
if [[ -f "$CADDYFILE" ]] && grep -Fq "$WEB_BEGIN" "$CADDYFILE" && grep -Fq "$WEB_END" "$CADDYFILE"; then WEB_INSTALLED=1; fi
if (( WEB_INSTALLED == 1 )); then
  command -v caddy >/dev/null 2>&1 || die 'Web установлен, но команда caddy не найдена.'
  : > "$TMP/mtpadmin_web.py"
  for part in 00-core.py 10-ui.py 20-pages.py 30-actions.py; do
    curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/$part" >> "$TMP/mtpadmin_web.py" || die "Не удалось скачать web fragment $part"
  done
fi

bash -n "$TMP/mtpadmin"
bash -n "$TMP/render_config.sh"
bash -n "$TMP/geo_update.sh"
python3 -m py_compile "$TMP/stats_collector.py" "$TMP/user_config.py" "$TMP/scanner_guard.py"
(( WEB_INSTALLED == 0 )) || python3 -m py_compile "$TMP/mtpadmin_web.py"
# Test the Scanner Guard database migration against a copy, never the live DB.
sqlite3 /var/lib/mtpadmin/stats.db ".backup '$TMP/scanner-test.db'"
MTPADMIN_DB="$TMP/scanner-test.db" python3 "$TMP/scanner_guard.py" selftest
ok 'Новые файлы, миграции и Scanner Guard прошли проверку'

atomic_install(){
  local src="$1" dst="$2" mode="$3" d t
  d=$(dirname "$dst"); mkdir -p "$d"; t="$d/.mtpadmin.$(basename "$dst").new.$$"
  install -m "$mode" -o root -g root "$src" "$t"
  mv -f "$t" "$dst"
}
atomic_install "$TMP/mtpadmin" /usr/local/bin/mtpadmin 0700
atomic_install "$TMP/stats_collector.py" /usr/local/lib/mtpadmin/stats_collector.py 0700
atomic_install "$TMP/user_config.py" /usr/local/lib/mtpadmin/user_config.py 0700
atomic_install "$TMP/scanner_guard.py" "$GUARD" 0700
atomic_install "$TMP/render_config.sh" /usr/local/lib/mtpadmin/render_config.sh 0700
atomic_install "$TMP/geo_update.sh" /usr/local/lib/mtpadmin/geo_update.sh 0700
if (( WEB_INSTALLED == 1 )); then atomic_install "$TMP/mtpadmin_web.py" "$WEBAPP" 0700; fi

# Version state is replaced atomically. The old web process already has its
# version in memory, while the candidate process sees the new version.
python3 - "$STATE" "$VERSION" <<'PY'
from pathlib import Path
import os,sys,tempfile
p=Path(sys.argv[1]); version=sys.argv[2]; out=[]; done=False
for line in p.read_text().splitlines():
    if line.startswith('MTPADMIN_VERSION='):
        out.append(f"MTPADMIN_VERSION='{version}'"); done=True
    else: out.append(line)
if not done: out.append(f"MTPADMIN_VERSION='{version}'")
fd,tmp=tempfile.mkstemp(prefix='.state.',dir=str(p.parent),text=True)
with os.fdopen(fd,'w') as f: f.write('\n'.join(out)+'\n')
os.chmod(tmp,0o600); os.replace(tmp,p)
PY
chmod 0600 "$STATE"

# Additive Scanner Guard schema migration on the real DB after the tested copy.
python3 "$GUARD" status --json >/dev/null

mkdir -p "$(dirname "$STATS_DROPIN")"
cat > "$STATS_DROPIN" <<'EOF'
[Service]
ExecReload=/bin/kill -HUP $MAINPID
EOF
chmod 0644 "$STATS_DROPIN"

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
ExecReload=/bin/kill -HUP $MAINPID
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
systemctl daemon-reload

# 0.7 introduces hot reload. Existing <=0.6 processes do one controlled
# handover now; every later release uses SIGHUP + exec without a stop window.
if [[ "$OLD_VERSION" =~ ^0\.[0-6]\. ]]; then
  info 'Однократный переход collector/Guard на hot-reload...'
  systemctl restart "$STATSSVC" || die 'Collector не запустился после перехода.'
  systemctl restart "$SCANNERSVC" || die 'Scanner Guard не запустился после перехода.'
else
  systemctl reload "$STATSSVC" || die 'Collector hot-reload не выполнен.'
  systemctl reload "$SCANNERSVC" || die 'Scanner Guard hot-reload не выполнен.'
fi

wait_heartbeat(){
  local table="$1" unit="$2" key="${3:-heartbeat}" now h i
  for i in {1..12}; do
    now=$(date +%s); h=$(sqlite3 /var/lib/mtpadmin/stats.db "SELECT value FROM $table WHERE key='$key';" 2>/dev/null || true)
    if [[ "$h" =~ ^[0-9]+$ ]] && (( now-h < 25 )) && systemctl is-active --quiet "$unit"; then return 0; fi
    sleep 1
  done
  return 1
}
wait_heartbeat collector_meta "$STATSSVC" || { journalctl -u "$STATSSVC" -n 60 --no-pager; die 'Collector heartbeat после обновления отсутствует.'; }
wait_heartbeat scanner_meta "$SCANNERSVC" || { journalctl -u "$SCANNERSVC" -n 60 --no-pager; die 'Scanner Guard heartbeat после обновления отсутствует.'; }
nft list table inet mtpadmin_guard >/dev/null 2>&1 || die 'Scanner Guard nftables table отсутствует.'

write_web_unit(){
  local slot="$1" port="$2" app="$3" file="/etc/systemd/system/mtpadmin-web-$slot.service"
  cat > "$file" <<EOF
[Unit]
Description=MTPADMIN web panel ($slot slot)
After=network.target mtpadmin-telemt.service mtpadmin-stats.service
Wants=mtpadmin-telemt.service mtpadmin-stats.service

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/python3 $app --listen 127.0.0.1 --port $port
Restart=on-failure
RestartSec=2
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
ReadWritePaths=/etc/mtpadmin /var/lib/mtpadmin /var/backups/mtpadmin /run/systemd
UMask=0077
MemoryMax=160M
TasksMax=96
EOF
  chmod 0644 "$file"
}

caddy_current_port(){
  python3 - "$CADDYFILE" "$WEB_BEGIN" "$WEB_END" <<'PY'
import re,sys
p,begin,end=sys.argv[1:]; inside=False; ports=[]
for line in open(p,encoding='utf-8'):
    s=line.strip()
    if s==begin: inside=True; continue
    if s==end: inside=False; continue
    if inside:
        m=re.search(r'\breverse_proxy\s+127\.0\.0\.1:(\d+)\b',line)
        if m: ports.append(m.group(1))
if len(ports)!=1: raise SystemExit(2)
print(ports[0])
PY
}

build_caddy_candidate(){
  local old="$1" new="$2"
  python3 - "$CADDYFILE" "$TMP/Caddyfile.candidate" "$WEB_BEGIN" "$WEB_END" "$old" "$new" <<'PY'
import re,sys
src,dst,begin,end,old,new=sys.argv[1:]; inside=False; changed=0; out=[]
for line in open(src,encoding='utf-8'):
    s=line.strip()
    if s==begin: inside=True
    if inside:
        line,n=re.subn(r'(\breverse_proxy\s+127\.0\.0\.1:)'+re.escape(old)+r'\b',r'\g<1>'+new,line,count=1)
        changed+=n
    if s==end: inside=False
    out.append(line)
if changed!=1: raise SystemExit('managed Caddy upstream not changed exactly once')
open(dst,'w',encoding='utf-8').writelines(out)
PY
}

write_web_runtime(){
  local slot="$1" port="$2" svc="$3" rel="$4" t="$TMP/web-runtime.env"
  cat > "$t" <<EOF
WEB_ACTIVE_SLOT='$slot'
WEB_ACTIVE_PORT='$port'
WEB_ACTIVE_SERVICE='$svc'
WEB_ACTIVE_RELEASE='$rel'
EOF
  atomic_install "$t" "$WEB_RUNTIME" 0600
}

if (( WEB_INSTALLED == 1 )); then
  current_port=$(caddy_current_port) || die 'Не удалось определить текущий MTPADMIN upstream в Caddyfile.'
  [[ "$current_port" == 9199 || "$current_port" == 9200 ]] || die "Неожиданный web upstream port: $current_port"
  if [[ "$current_port" == 9199 ]]; then standby_port=9200; standby_slot=green; current_slot=blue; else standby_port=9199; standby_slot=blue; current_slot=green; fi
  standby_service="mtpadmin-web-$standby_slot.service"
  current_service="mtpadmin-web-$current_slot.service"
  if ! systemctl is-active --quiet "$current_service" 2>/dev/null; then
    if systemctl is-active --quiet mtpadmin-web.service 2>/dev/null; then current_service='mtpadmin-web.service';
    else die "Текущий web upstream $current_port есть в Caddy, но его service не активен."; fi
  fi

  # Never disturb the active slot while preparing the candidate.
  systemctl stop "$standby_service" >/dev/null 2>&1 || true
  if ss -H -ltn "sport = :$standby_port" 2>/dev/null | grep -q .; then
    ss -ltnp "sport = :$standby_port" || true
    die "Standby web port $standby_port занят посторонним процессом."
  fi
  mkdir -p "$WEB_RELEASES"
  release="$WEB_RELEASES/mtpadmin-web-$VERSION-$STAMP.py"
  atomic_install "$TMP/mtpadmin_web.py" "$release" 0700
  write_web_unit "$standby_slot" "$standby_port" "$release"
  systemctl daemon-reload
  systemctl start "$standby_service" || { journalctl -u "$standby_service" -n 80 --no-pager; die 'Standby web backend не стартовал.'; }
  for i in 1 2 3; do
    curl -fsS --max-time 5 -H 'X-MTPADMIN-User: seamless-health' "http://127.0.0.1:$standby_port/healthz" >/dev/null || { systemctl stop "$standby_service" || true; die 'Standby web healthcheck не прошёл.'; }
    sleep 1
  done
  ok "Standby web $standby_slot готов на 127.0.0.1:$standby_port"

  build_caddy_candidate "$current_port" "$standby_port"
  caddy validate --config "$TMP/Caddyfile.candidate" --adapter caddyfile >/dev/null || { systemctl stop "$standby_service" || true; die 'Caddy candidate не прошёл validate.'; }
  caddy_before="$TMP/Caddyfile.before-switch"; cp -a "$CADDYFILE" "$caddy_before"
  atomic_install "$TMP/Caddyfile.candidate" "$CADDYFILE" 0644
  if ! systemctl reload caddy; then
    cp -a "$caddy_before" "$CADDYFILE"; systemctl reload caddy || true; systemctl stop "$standby_service" || true
    die 'Caddy seamless switch не выполнен; старый upstream восстановлен.'
  fi
  # Keep old backend alive while the new path proves stable.
  for i in 1 2 3 4 5; do
    if ! systemctl is-active --quiet caddy || ! systemctl is-active --quiet "$standby_service" || ! curl -fsS --max-time 3 -H 'X-MTPADMIN-User: seamless-health' "http://127.0.0.1:$standby_port/healthz" >/dev/null; then
      cp -a "$caddy_before" "$CADDYFILE"; systemctl reload caddy || true; systemctl stop "$standby_service" || true
      die 'Новый web slot не прошёл стабилизацию; Caddy возвращён на старый backend.'
    fi
    sleep 1
  done
  write_web_runtime "$standby_slot" "$standby_port" "$standby_service" "$release"
  systemctl stop "$current_service" >/dev/null 2>&1 || true
  # Preserve the familiar mtpadmin-web.service name as an alias to active slot.
  rm -f "$WEB_ALIAS"
  ln -s "mtpadmin-web-$standby_slot.service" "$WEB_ALIAS"
  systemctl daemon-reload
  systemctl is-active --quiet "$standby_service" || die 'Активный web slot неожиданно остановился.'
  # Existing multi-user.target wants symlink points to mtpadmin-web.service and
  # therefore follows this alias after reboot. If it is absent, create it.
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sfn "$WEB_ALIAS" /etc/systemd/system/multi-user.target.wants/mtpadmin-web.service
  find "$WEB_RELEASES" -maxdepth 1 -type f -name 'mtpadmin-web-*.py' -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR>4{$1="";sub(/^ /,"");print}' | xargs -r rm -f --
  ok "Web blue/green переключён: $current_port -> $standby_port без остановки Caddy"
fi

systemctl is-active --quiet "$SERVICE" || die 'TeleMT неожиданно остановился.'
mtpadmin doctor
ok "MTPADMIN $VERSION обновлён. TeleMT не перезапускался; web использует blue/green; autoban=OFF."
