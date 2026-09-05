#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.12.5'
BASE_COMMIT='579aef84a1e58c4768357ab7ed238a8b787d4a8a'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
STATE='/etc/mtpadmin/state.env'
CADDYFILE='/etc/caddy/Caddyfile'
WEB_BEGIN='# BEGIN MTPADMIN WEB - managed by mtpadmin'
WEB_END='# END MTPADMIN WEB - managed by mtpadmin'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

download(){
  local url="$1" dst="$2" label="$3" part="${dst}.part"
  rm -f "$part"
  curl -fL --proto '=https' --tlsv1.2 \
    --connect-timeout 10 --max-time 180 \
    --retry 5 --retry-delay 2 --retry-all-errors \
    "$url" -o "$part" || die "Не удалось скачать $label."
  [[ -s "$part" ]] || die "Скачанный $label пуст."
  mv -f "$part" "$dst"
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запустите через sudo/root.'
[[ -f "$STATE" ]] || die 'Сначала установите MTPADMIN.'
command -v curl >/dev/null 2>&1 || die 'Не найден curl.'
command -v caddy >/dev/null 2>&1 || die 'Caddy не найден. Clean install.sh устанавливает его автоматически.'
[[ -f "$CADDYFILE" ]] || die "Не найден $CADDYFILE"

get_update(){
  local dst="$1"
  download "$ROOT/$RELEASE_REF/update.sh" "$dst" 'update.sh'
  chmod 0700 "$dst"
  bash -n "$dst" || die 'Скачанный update.sh не прошёл проверку синтаксиса.'
  grep -Fq "VERSION='0.12.5'" "$dst" || die 'Скачанный update.sh не соответствует MTPADMIN 0.12.5.'
}
run_update(){ MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$1"; }

# Existing installation: only run the release-pinned updater. It already uses
# blue/green switching and all production checks.
if grep -Fq "$WEB_BEGIN" "$CADDYFILE" && grep -Fq "$WEB_END" "$CADDYFILE"; then
  info 'Веб-панель уже установлена — выполняю безопасное обновление.'
  get_update "$TMP/update-existing.sh"
  run_update "$TMP/update-existing.sh"
  ok "MTPADMIN Web $VERSION обновлён."
  exit 0
fi

# Fresh installation: first create the minimal local web service and Caddy
# block. Only after that run the current updater, because the blue/green update
# chain expects an existing web runtime to migrate.
info 'Создаю базовую веб-панель...'
download "$ROOT/$BASE_COMMIT/web-install.sh" "$TMP/base-web-install.sh" 'базовый web-installer'
python3 - "$TMP/base-web-install.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
checks=["VERSION='0.5.0'","PORT=9199","RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"]
for marker in checks:
    if marker not in s: raise SystemExit('unexpected immutable web installer: '+marker)
s=s.replace("VERSION='0.5.0'", "VERSION='0.12.5'", 1)
s=s.replace("PORT=9199", "WEB_PORT=9199", 1)
s=s.replace('$PORT', '$WEB_PORT')
s=s.replace('RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX','RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK',1)
p.write_text(s,encoding='utf-8')
PY
chmod 0700 "$TMP/base-web-install.sh"
bash -n "$TMP/base-web-install.sh" || die 'Базовый web-installer не прошёл проверку синтаксиса.'
bash "$TMP/base-web-install.sh"

info 'Включаю актуальную веб-панель, мобильное приложение, статистику и Telegram WEB Proxy MTPADMIN 0.12.5...'
get_update "$TMP/update-after-web.sh"
run_update "$TMP/update-after-web.sh"

ok "MTPADMIN Web $VERSION готов: адаптивный интерфейс, установка на телефон, WEB Proxy, статистика и Центр обновлений включены."
