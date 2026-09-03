#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

STATE='/etc/mtpadmin/state.env'
TPROXY_REPO='https://github.com/telegramdesktop/tproxy-server.git'
TPROXY_API='https://api.github.com/repos/telegramdesktop/tproxy-server'
BINARY='/usr/local/bin/tproxy-server'
MARKER='/usr/local/lib/mtpadmin/tproxy-server.commit'
TELEMETRY_MARKER='/usr/local/lib/mtpadmin/tproxy-server.telemetry'
CFG='/etc/tproxy-server/config.json'
PROFILES='/etc/tproxy-server/profiles.json'
TOKEN_KEY='/etc/tproxy-server/token.key'
SERVICE='tproxy-server.service'
ADMIN='http://127.0.0.1:8081'
BUILD_ROOT=${MTPADMIN_TPROXY_BUILD_ROOT:-/var/tmp/mtpadmin-build}
MIN_FREE_KB=${MTPADMIN_TPROXY_BUILD_MIN_FREE_KB:-786432}
TELEMETRY='/usr/local/lib/mtpadmin/webproxy_telemetry_install.sh'
BACKEND='/usr/local/lib/mtpadmin/webproxy_backend_install.sh'
TMP=''

cleanup(){ [[ -z "${TMP:-}" || ! -d "$TMP" ]] || rm -rf -- "$TMP"; }
trap cleanup EXIT
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }
die(){ echo "[FAIL] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'WEB Proxy updater требует root.'
[[ -f "$STATE" && -f "$CFG" && -f "$PROFILES" && -x "$BINARY" ]] || die 'Telegram WEB Proxy установлен не полностью.'
id tproxy >/dev/null 2>&1 || die 'System user tproxy не найден.'
command -v git >/dev/null 2>&1 || die 'git не найден.'
command -v curl >/dev/null 2>&1 || die 'curl не найден.'
command -v runuser >/dev/null 2>&1 || die 'runuser не найден.'

state_set(){
  python3 - "$STATE" "$1" "$2" <<'PY'
from pathlib import Path
import os,sys,tempfile
p=Path(sys.argv[1]); key=sys.argv[2]; value=sys.argv[3]
lines=p.read_text(encoding='utf-8').splitlines(); out=[]; done=False
for line in lines:
    if line.startswith(key+'='):
        out.append(key+"='"+value.replace("'","'\\''")+"'"); done=True
    else:
        out.append(line)
if not done: out.append(key+"='"+value.replace("'","'\\''")+"'")
fd,tmp=tempfile.mkstemp(prefix='.state.',dir=str(p.parent),text=True)
with os.fdopen(fd,'w',encoding='utf-8') as f:
    f.write('\n'.join(out)+'\n'); f.flush(); os.fsync(f.fileno())
os.chmod(tmp,0o600); os.replace(tmp,p)
PY
}

resolve_go(){
  go_binary=''
  if command -v go >/dev/null 2>&1; then
    minor=$(go env GOVERSION 2>/dev/null | sed -E 's/^go1\.([0-9]+).*/\1/' || true)
    [[ "$minor" =~ ^[0-9]+$ ]] && (( minor >= 20 )) && go_binary=$(command -v go)
  fi
  if [[ -z "$go_binary" ]]; then
    for candidate in /opt/go*/bin/go; do
      [[ -x "$candidate" ]] || continue
      minor=$($candidate env GOVERSION 2>/dev/null | sed -E 's/^go1\.([0-9]+).*/\1/' || true)
      if [[ "$minor" =~ ^[0-9]+$ ]] && (( minor >= 20 )); then go_binary="$candidate"; break; fi
    done
  fi
  [[ -n "$go_binary" ]] || die 'Go 1.20+ не найден.'
}

wait_url(){
  local url="$1" i
  for i in {1..30}; do
    curl -fsS --max-time 3 "$url" >/dev/null 2>&1 && return 0
    systemctl is-failed --quiet "$SERVICE" && return 1
    sleep 1
  done
  return 1
}

ensure_token_key(){
  install -d -o root -g tproxy -m 0750 /etc/tproxy-server
  if [[ -L "$TOKEN_KEY" ]] || { [[ -e "$TOKEN_KEY" ]] && [[ ! -f "$TOKEN_KEY" ]]; }; then
    die "token key должен быть обычным файлом: $TOKEN_KEY"
  fi
  if [[ ! -e "$TOKEN_KEY" ]]; then
    local temporary
    temporary=$(mktemp "${TOKEN_KEY}.XXXXXXXX")
    head -c 32 /dev/urandom > "$temporary"
    chown tproxy:tproxy "$temporary"
    chmod 0400 "$temporary"
    if ! ln "$temporary" "$TOKEN_KEY"; then
      rm -f -- "$temporary"
      die 'token.key появился во время создания; отказ от замены.'
    fi
    rm -f -- "$temporary"
    ok 'Создан постоянный WEB relay token.key (значение не выводится)'
  fi
  [[ "$(wc -c < "$TOKEN_KEY")" -eq 32 ]] || die 'token.key должен содержать ровно 32 байта.'
  chown tproxy:tproxy "$TOKEN_KEY"
  chmod 0400 "$TOKEN_KEY"
}

enable_first_upgrade_drain(){
  [[ -e "$TOKEN_KEY" ]] && return 0
  local dir='/etc/systemd/system/tproxy-server.service.d' dropin="$dir/token-migration.conf" candidate="$TMP/token-migration.conf"
  install -d -m 0755 -o root -g root "$dir"
  cat > "$candidate" <<'EOF'
[Service]
Environment=TPROXY_LEGACY_TOKEN_DRAIN=1
EOF
  if [[ -L "$dropin" ]] || { [[ -e "$dropin" ]] && ! cmp -s "$candidate" "$dropin"; }; then
    die "Существующий $dropin отличается; автоматическая миграция остановлена."
  fi
  install -m 0644 -o root -g root "$candidate" "$dropin"
  systemctl daemon-reload
  ok 'Включён совместимый drain старых relay-токенов для первого обновления'
}

latest=${TPROXY_COMMIT_OVERRIDE:-}
if [[ -z "$latest" ]]; then
  latest=$(curl -fsSL --retry 3 "$TPROXY_API/branches/master" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("commit") or {}).get("sha", ""))')
fi
[[ "$latest" =~ ^[0-9a-f]{40}$ ]] || die 'Не удалось определить upstream commit tproxy-server.'
current=$(tr -d '\r\n' < "$MARKER" 2>/dev/null || true)
[[ -z "$current" || "$current" =~ ^[0-9a-f]{40}$ ]] || die 'Некорректный текущий marker tproxy-server.'

install -d -m 0711 -o root -g root "$BUILD_ROOT"
free_kb=$(df -Pk "$BUILD_ROOT" | awk 'NR==2{print $4}')
[[ "$free_kb" =~ ^[0-9]+$ ]] || die 'Не удалось проверить свободное место build filesystem.'
(( free_kb >= MIN_FREE_KB )) || die "Недостаточно места для безопасной сборки WEB Proxy: $((free_kb/1024)) MB."
TMP=$(mktemp -d "$BUILD_ROOT/webproxy-update.XXXXXXXX")
chmod 0711 "$TMP"
src="$TMP/tproxy-server"; buildhome="$TMP/buildhome"; gotmp="$buildhome/gotmp"

info "Получаю telegramdesktop/tproxy-server ${latest:0:12}..."
git init -q "$src"
git -C "$src" remote add origin "$TPROXY_REPO"
git -C "$src" fetch -q --depth=1 origin "$latest"
git -C "$src" checkout -q --detach FETCH_HEAD
[[ "$(git -C "$src" rev-parse HEAD)" == "$latest" ]] || die 'Не удалось зафиксировать upstream commit.'
resolve_go
install -d -o tproxy -g tproxy -m 0700 "$buildhome" "$gotmp"
chown -R tproxy:tproxy "$src" "$buildhome"

info 'Запускаю upstream tests и собираю relay без остановки текущего сервиса...'
(cd "$src" && runuser -u tproxy -- env HOME="$buildhome" TMPDIR="$gotmp" GOTMPDIR="$gotmp" GOCACHE="$buildhome/gocache" GOMODCACHE="$buildhome/gomod" GOMAXPROCS=1 GOTOOLCHAIN=local sh -c 'umask 022; exec "$@"' sh "$go_binary" test -p=1 ./...)
(cd "$src" && runuser -u tproxy -- env HOME="$buildhome" TMPDIR="$gotmp" GOTMPDIR="$gotmp" GOCACHE="$buildhome/gocache" GOMODCACHE="$buildhome/gomod" GOMAXPROCS=1 GOTOOLCHAIN=local sh -c 'umask 022; exec "$@"' sh "$go_binary" build -p=1 -trimpath -ldflags='-s -w' -o "$buildhome/tproxy-server.bin" ./cmd/tproxy-server)
chmod 0755 "$buildhome/tproxy-server.bin"
ok 'Upstream tests + build PASS'

enable_first_upgrade_drain
ensure_token_key
"$buildhome/tproxy-server.bin" -config "$CFG" -profiles-file "$PROFILES" -check >/dev/null || die 'Новый relay не принял production config/profile/token key.'
ok 'Новый relay принял production config + persistent token key'

install -d -m 0700 /var/backups/mtpadmin
stamp=$(date +%Y%m%d-%H%M%S)
backup="/var/backups/mtpadmin/tproxy-server-before-hardening-${latest:0:12}-$stamp"
cp -a "$BINARY" "$backup"
marker_backup="$TMP/marker.old"; [[ -f "$MARKER" ]] && cp -a "$MARKER" "$marker_backup" || true
telemetry_backup="$TMP/telemetry.old"; [[ -f "$TELEMETRY_MARKER" ]] && cp -a "$TELEMETRY_MARKER" "$telemetry_backup" || true
old_state_commit="$current"
was_ready=0; curl -fsS --max-time 3 "$ADMIN/readyz" >/dev/null 2>&1 && was_ready=1 || true

rollback(){
  warn 'Новый WEB Proxy не прошёл runtime/telemetry проверку; возвращаю предыдущий relay.'
  install -m 0755 -o root -g root "$backup" "$BINARY"
  if [[ -f "$marker_backup" ]]; then cp -a "$marker_backup" "$MARKER"; else rm -f "$MARKER"; fi
  if [[ -f "$telemetry_backup" ]]; then cp -a "$telemetry_backup" "$TELEMETRY_MARKER"; else rm -f "$TELEMETRY_MARKER"; fi
  [[ -z "$old_state_commit" ]] || state_set WEBPROXY_TPROXY_COMMIT "$old_state_commit"
  systemctl restart "$SERVICE" >/dev/null 2>&1 || true
}

install -m 0755 -o root -g root "$buildhome/tproxy-server.bin" "$BINARY"
if ! systemctl restart "$SERVICE"; then rollback; die 'Новый WEB relay не запустился; выполнен rollback.'; fi
if ! wait_url "$ADMIN/healthz"; then rollback; die 'Новый WEB relay не вышел в health; выполнен rollback.'; fi
if (( was_ready == 1 )) && ! wait_url "$ADMIN/readyz"; then rollback; die 'Новый WEB relay потерял readiness; выполнен rollback.'; fi

printf '%s\n' "$latest" > "$MARKER"; chmod 0644 "$MARKER"
state_set WEBPROXY_TPROXY_COMMIT "$latest"
rm -f "$TELEMETRY_MARKER"
ok "Upstream relay переключён ${current:0:12} → ${latest:0:12}"

if [[ -x "$BACKEND" ]]; then
  info 'Проверяю official MTProxy localhost backend...'
  bash "$BACKEND" || { rollback; die 'Official MTProxy backend repair не прошёл; выполнен rollback.'; }
fi
if [[ -x "$TELEMETRY" ]]; then
  info 'Пересобираю privacy-safe telemetry поверх нового upstream...'
  bash "$TELEMETRY" || { rollback; die 'Telemetry нового WEB Proxy не прошла; выполнен rollback.'; }
fi

wait_url "$ADMIN/readyz" || { rollback; die 'WEB Proxy не READY после финальной сборки; выполнен rollback.'; }
curl -fsS --max-time 4 "$ADMIN/mtpadmin/clients" | python3 -c 'import ipaddress,json,sys; d=json.load(sys.stdin); r=d.get("clients"); assert isinstance(r,list); [ipaddress.ip_address(str(x.get("ip"))) for x in r]' >/dev/null || { rollback; die 'WEB telemetry endpoint не READY; выполнен rollback.'; }

state_set WEBPROXY_READY '1'
ok "Telegram WEB Proxy ${latest:0:12} READY; token key persistent; telemetry PASS"
if [[ -f /etc/systemd/system/tproxy-server.service.d/token-migration.conf ]]; then
  info 'Первичная signed-token миграция работает в drain-режиме. Drop-in сохраняется намеренно до отдельного завершения миграции.'
fi
