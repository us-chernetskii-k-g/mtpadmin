#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
VERSION='0.5.0'
RAW_BASE='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main'
STATE='/etc/mtpadmin/state.env'
CADDYFILE='/etc/caddy/Caddyfile'
WEBAPP='/usr/local/lib/mtpadmin/web/mtpadmin_web.py'
WEBSVC='/etc/systemd/system/mtpadmin-web.service'
CSRF='/etc/mtpadmin/web.csrf'
PORT=9199
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="/var/backups/mtpadmin/web-install-$STAMP"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }
die(){ echo "[FAIL] $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запустите через sudo/root.'
[[ -f "$STATE" ]] || die 'Сначала установите MTPADMIN.'
command -v caddy >/dev/null 2>&1 || die 'Caddy не найден.'
[[ -f "$CADDYFILE" ]] || die "Не найден $CADDYFILE"
command -v python3 >/dev/null 2>&1 || die 'Python3 не найден.'

# shellcheck disable=SC1090
source "$STATE"
TTY=/dev/tty; [[ -r "$TTY" ]] || TTY=/dev/stdin
ask(){ local prompt="$1" def="${2:-}" out; printf '%s [%s]: ' "$prompt" "$def" >"$TTY"; IFS= read -r out <"$TTY" || true; printf '%s' "${out:-$def}"; }
ask_secret(){ local prompt="$1" out; printf '%s' "$prompt" >"$TTY"; IFS= read -r -s out <"$TTY" || true; printf '\n' >"$TTY"; printf '%s' "$out"; }
WEB_HOST="${MTPADMIN_WEB_HOST:-$(ask 'Домен веб-панели' "${PUBLIC_HOST:-}")}"
WEB_USER="${MTPADMIN_WEB_USER:-$(ask 'Логин администратора' 'admin')}"
WEB_PASS="${MTPADMIN_WEB_PASSWORD:-}"
if [[ -z "$WEB_PASS" ]]; then WEB_PASS=$(ask_secret 'Пароль веб-панели (минимум 10 символов): '); fi
[[ "$WEB_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die 'Некорректный домен.'
[[ "$WEB_USER" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]] || die 'Некорректный логин.'
((${#WEB_PASS} >= 10)) || die 'Пароль должен быть не короче 10 символов.'

mkdir -p "$BACKUP" /usr/local/lib/mtpadmin/web /var/backups/mtpadmin
cp -a "$CADDYFILE" "$BACKUP/Caddyfile.before"
[[ -e "$WEBAPP" ]] && cp -a "$WEBAPP" "$BACKUP/mtpadmin_web.py.before"
[[ -e "$WEBSVC" ]] && cp -a "$WEBSVC" "$BACKUP/mtpadmin-web.service.before"
[[ -e "$CSRF" ]] && cp -a "$CSRF" "$BACKUP/web.csrf.before"
ok "Backup: $BACKUP"

: > "$TMP/mtpadmin_web.py"
for part in 00-core.py 10-ui.py 20-pages.py 30-actions.py; do
  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/$part" >> "$TMP/mtpadmin_web.py" || die "Не удалось скачать web fragment $part"
done
python3 -m py_compile "$TMP/mtpadmin_web.py"
ok 'Web backend прошёл py_compile'

if [[ ! -s "$CSRF" ]]; then
  python3 - <<'PY' > "$CSRF"
import secrets
print(secrets.token_hex(32))
PY
  chmod 0600 "$CSRF"
fi
install -m 0700 "$TMP/mtpadmin_web.py" "$WEBAPP"

cat > "$WEBSVC" <<EOF
[Unit]
Description=MTPADMIN lightweight web panel
After=network.target mtpadmin-telemt.service mtpadmin-stats.service
Wants=mtpadmin-telemt.service mtpadmin-stats.service

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/bin/python3 $WEBAPP --listen 127.0.0.1 --port $PORT
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
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
ReadWritePaths=/etc/mtpadmin /var/lib/mtpadmin /var/backups/mtpadmin /run/systemd
UMask=0077
MemoryMax=160M
TasksMax=96

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$WEBSVC"

if systemctl cat mtpadmin-web.service >/dev/null 2>&1; then systemctl stop mtpadmin-web.service || true; fi
if ss -H -ltn "sport = :$PORT" 2>/dev/null | grep -q .; then
  ss -ltnp "sport = :$PORT" || true
  die "Порт $PORT уже занят другим процессом."
fi
systemctl daemon-reload
systemctl enable --now mtpadmin-web.service
sleep 1
systemctl is-active --quiet mtpadmin-web.service || { journalctl -u mtpadmin-web.service -n 80 --no-pager; die 'Web service не запустился.'; }
curl -fsS --max-time 5 -H 'X-MTPADMIN-User: local-health' "http://127.0.0.1:$PORT/healthz" >/dev/null || die 'Web backend healthcheck не прошёл.'
ok "Backend работает только на 127.0.0.1:$PORT"

CV=$(caddy version 2>/dev/null | sed 's/^v//' | head -1)
MINOR=$(printf '%s' "$CV" | cut -d. -f2 | tr -cd '0-9')
AUTH_DIRECTIVE='basicauth'
[[ "${MINOR:-0}" =~ ^[0-9]+$ ]] && (( MINOR >= 8 )) && AUTH_DIRECTIVE='basic_auth'
HASH=$(printf '%s\n' "$WEB_PASS" | caddy hash-password 2>/dev/null) || die 'Caddy не смог создать bcrypt hash.'
unset WEB_PASS MTPADMIN_WEB_PASSWORD
[[ -n "$HASH" ]] || die 'Пустой password hash.'

BEGIN='# BEGIN MTPADMIN WEB - managed by mtpadmin'
END='# END MTPADMIN WEB - managed by mtpadmin'
python3 - "$CADDYFILE" "$TMP/Caddyfile.base" "$BEGIN" "$END" <<'PY'
import sys
src,dst,begin,end=sys.argv[1:]
text=open(src,encoding='utf-8').read().splitlines()
out=[]; skip=False
for line in text:
    if line.strip()==begin: skip=True; continue
    if skip and line.strip()==end: skip=False; continue
    if not skip: out.append(line)
open(dst,'w',encoding='utf-8').write('\n'.join(out).rstrip()+'\n')
PY
if python3 - "$TMP/Caddyfile.base" "$WEB_HOST" <<'PY'
import re,sys
text=open(sys.argv[1],encoding='utf-8').read()
host=re.escape(sys.argv[2])
raise SystemExit(0 if re.search(r'(?m)^\s*'+host+r'\s*\{',text) else 1)
PY
then
  systemctl stop mtpadmin-web.service || true
  die "В Caddyfile уже есть отдельный блок $WEB_HOST, который не принадлежит MTPADMIN. Автоматически менять его небезопасно."
fi

cat "$TMP/Caddyfile.base" > "$TMP/Caddyfile.new"
cat >> "$TMP/Caddyfile.new" <<EOF

$BEGIN
$WEB_HOST {
    encode zstd gzip

    $AUTH_DIRECTIVE {
        $WEB_USER $HASH
    }

    header {
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "no-referrer"
        Permissions-Policy "camera=(), microphone=(), geolocation=()"
        Cache-Control "no-store"
        -Server
    }

    reverse_proxy 127.0.0.1:$PORT {
        header_up X-MTPADMIN-User {http.auth.user.id}
        header_up -Authorization
    }

    log {
        output file /var/log/caddy/mtpadmin-access.log {
            roll_size 10MiB
            roll_keep 5
            roll_keep_for 168h
        }
    }
}
$END
EOF

caddy validate --config "$TMP/Caddyfile.new" --adapter caddyfile >/dev/null || {
  systemctl stop mtpadmin-web.service || true
  die 'Новый Caddyfile не прошёл validate; рабочий Caddyfile не изменён.'
}
ok 'Новый Caddyfile прошёл validate'
install -m 0644 -o root -g root "$TMP/Caddyfile.new" "$CADDYFILE"
if ! systemctl reload caddy; then
  warn 'Caddy reload failed — rollback'
  cp -a "$BACKUP/Caddyfile.before" "$CADDYFILE"
  systemctl reload caddy || true
  systemctl stop mtpadmin-web.service || true
  die 'Установка web отменена.'
fi
sleep 2
systemctl is-active --quiet caddy || {
  cp -a "$BACKUP/Caddyfile.before" "$CADDYFILE"
  systemctl restart caddy || true
  systemctl stop mtpadmin-web.service || true
  die 'Caddy после reload не работает; выполнен rollback.'
}

ok "MTPADMIN Web $VERSION установлен"
echo
echo "Адрес: https://$WEB_HOST/"
echo "Логин: $WEB_USER"
echo 'Пароль в открытом виде нигде не сохранён.'
echo
info 'Первый сертификат Caddy может получить через несколько секунд.'
echo 'Проверка:'
echo "  systemctl status mtpadmin-web.service --no-pager"
echo "  curl -I https://$WEB_HOST/"
