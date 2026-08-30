#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Clean-install bootstrap: core -> Caddy -> WEB hostname -> web panel -> current release.
BASE_COMMIT='b5dcc69b9d4761e475c17ed7e692790c405d42f0'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
STATE='/etc/mtpadmin/state.env'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запустите через sudo/root.'
[[ ! -e "$STATE" ]] || die 'MTPADMIN уже установлен. Используйте update.sh.'
command -v curl >/dev/null 2>&1 || die 'Не найден curl.'

curl -fsSL --retry 3 "$ROOT/$BASE_COMMIT/install.sh" -o "$TMP/base-install.sh" || die 'Не удалось скачать базовый установщик.'
chmod 0700 "$TMP/base-install.sh"; bash -n "$TMP/base-install.sh"
# Interactive reads/password entry are handled by the real file, not the curl pipe.
bash "$TMP/base-install.sh"

if ! command -v caddy >/dev/null 2>&1; then
  info 'Устанавливаю Caddy для HTTPS веб-панели и Telegram WEB Proxy...'
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends caddy >/dev/null || die 'Не удалось установить Caddy из системного репозитория.'
fi
systemctl enable --now caddy >/dev/null 2>&1 || true
[[ -f /etc/caddy/Caddyfile ]] || die 'Caddy установлен, но /etc/caddy/Caddyfile отсутствует.'
ok 'Caddy готов'

# Ask for WEB Proxy hostname once on clean install. It can later be changed in Operations.
# shellcheck disable=SC1090
source "$STATE"
if [[ "${PUBLIC_HOST:-}" == *.*.* ]]; then WP_DEFAULT="webproxy.${PUBLIC_HOST#*.}"; else WP_DEFAULT="webproxy.${PUBLIC_HOST:-example.com}"; fi
WP_HOST="${MTPADMIN_WEBPROXY_HOST:-}"
if [[ -z "$WP_HOST" ]]; then
  [[ -r /dev/tty && -w /dev/tty ]] || die 'Нет доступного /dev/tty для настройки WEB Proxy hostname.'
  printf 'Hostname Telegram WEB Proxy [%s]: ' "$WP_DEFAULT" >/dev/tty
  IFS= read -r WP_HOST </dev/tty || true
  WP_HOST=${WP_HOST:-$WP_DEFAULT}
fi
WP_HOST=${WP_HOST,,}; WP_HOST=${WP_HOST#http://}; WP_HOST=${WP_HOST#https://}; WP_HOST=${WP_HOST%%/*}; WP_HOST=${WP_HOST%.}
[[ "$WP_HOST" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$WP_HOST" == *.* && "$WP_HOST" != *:* ]] || die 'Некорректный WEB Proxy hostname.'
python3 - "$STATE" "$WP_HOST" <<'PY'
from pathlib import Path
import os,sys,tempfile
p=Path(sys.argv[1]); value=sys.argv[2]; key='WEBPROXY_HOST'
lines=p.read_text(encoding='utf-8').splitlines(); out=[]; done=False
for line in lines:
    if line.startswith(key+'='): out.append(f"{key}='{value}'"); done=True
    else: out.append(line)
if not done: out.append(f"{key}='{value}'")
fd,tmp=tempfile.mkstemp(prefix='.state.',dir=str(p.parent),text=True)
with os.fdopen(fd,'w') as f: f.write('\n'.join(out)+'\n')
os.chmod(tmp,0o600); os.replace(tmp,p)
PY
ok "WEB Proxy hostname: $WP_HOST"

# web-install performs the current core update, creates the first panel, then
# switches it to the current blue/green runtime. WEB Proxy is provisioned by update.sh.
curl -fsSL --retry 3 "$ROOT/main/web-install.sh" -o "$TMP/web-install.sh" || die 'Не удалось скачать web-install.sh.'
chmod 0700 "$TMP/web-install.sh"; bash -n "$TMP/web-install.sh"
bash "$TMP/web-install.sh"

ok 'Чистая установка MTPADMIN завершена: TeleMT + Web + WEB Proxy + Update Center.'
