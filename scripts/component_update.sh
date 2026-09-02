#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

STATE='/etc/mtpadmin/state.env'
STATUS='/var/lib/mtpadmin/component-update-status.json'
CHECKER='/usr/local/lib/mtpadmin/update_check.py'
WEBINSTALL='/usr/local/lib/mtpadmin/webproxy_install.sh'
WEBBACKEND='/usr/local/lib/mtpadmin/webproxy_backend_install.sh'
WEBTELEMETRY='/usr/local/lib/mtpadmin/webproxy_telemetry_install.sh'
REPO_API='https://api.github.com/repos/us-chernetskii-k-g/mtpadmin'
RAW='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
LOCK='/run/mtpadmin-component-update.lock'
TMP=''
COMPONENT='unknown'
STATUS_TERMINAL=0

log_status(){
  local component="$1" state="$2" detail="${3:-}"
  install -d -m 0750 -o root -g mtpadmin /var/lib/mtpadmin 2>/dev/null || true
  python3 - "$STATUS" "$component" "$state" "$detail" <<'PY'
import json,os,sys,tempfile,time
p,comp,state,detail=sys.argv[1:]
fd,tmp=tempfile.mkstemp(prefix='.component-update.',dir=os.path.dirname(p),text=True)
with os.fdopen(fd,'w') as f:
    json.dump({'component':comp,'state':state,'detail':detail,'ts':int(time.time())},f,ensure_ascii=False); f.write('\n'); f.flush(); os.fsync(f.fileno())
os.chmod(tmp,0o644); os.replace(tmp,p)
PY
  [[ "$state" == success || "$state" == failed ]] && STATUS_TERMINAL=1 || true
}

die(){ log_status "${COMPONENT:-unknown}" failed "$*" || true; echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
cleanup(){
  local rc=$?
  [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf "$TMP" || true
  if (( rc != 0 )) && (( STATUS_TERMINAL == 0 )); then
    log_status "${COMPONENT:-unknown}" failed "Операция аварийно завершилась, rc=$rc" || true
  fi
  return "$rc"
}
trap cleanup EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo '[FAIL] root required' >&2; exit 1; }
[[ -f "$STATE" ]] || { echo '[FAIL] MTPADMIN not installed' >&2; exit 1; }
# shellcheck disable=SC1090
source "$STATE"

acquire_lock(){
  exec 9>"$LOCK"
  flock -n 9 || die 'Уже выполняется другая операция обновления. Дождитесь её завершения.'
}

wait_telemt(){
  local i
  for i in {1..30}; do
    systemctl is-active --quiet mtpadmin-telemt.service && curl -fsS --max-time 3 http://127.0.0.1:9091/v1/health/ready >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

update_telemt(){
  COMPONENT='telemt'; acquire_lock; log_status "$COMPONENT" running 'Проверяю последний release TeleMT'
  TMP=$(mktemp -d)
  local arch libc latest cur base archive sumurl expected actual backup bin
  case "$(uname -m)" in x86_64|amd64) arch='x86_64';; aarch64|arm64) arch='aarch64';; *) die "Unsupported arch $(uname -m)";; esac
  libc='gnu'; ldd --version 2>&1 | grep -qi musl && libc='musl'
  latest=$(curl -fsSL --retry 3 https://api.github.com/repos/telemt/telemt/releases/latest | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name", ""))')
  [[ "$latest" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || die 'Не удалось определить последний release TeleMT'
  cur=$(/usr/local/bin/telemt --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [[ "$cur" == "$latest" ]]; then
    systemctl is-active --quiet mtpadmin-telemt.service || systemctl restart mtpadmin-telemt.service
    wait_telemt || die "TeleMT $cur установлен, но не вышел в READY"
    log_status "$COMPONENT" success "TeleMT $cur актуален и READY"; ok "TeleMT $cur актуален и READY"; return
  fi
  base="telemt-${arch}-linux-${libc}.tar.gz"; archive="$TMP/$base"; sumurl="https://github.com/telemt/telemt/releases/download/$latest/$base.sha256"
  curl -fL --retry 3 "https://github.com/telemt/telemt/releases/download/$latest/$base" -o "$archive"
  expected=$(curl -fsSL --retry 3 "$sumurl" | awk '{print $1}' | head -1); actual=$(sha256sum "$archive" | awk '{print $1}')
  [[ "$expected" =~ ^[0-9a-f]{64}$ && "$actual" == "$expected" ]] || die 'Checksum нового TeleMT не совпал'
  tar -xzf "$archive" -C "$TMP"; bin=$(find "$TMP" -type f -name telemt -print -quit); [[ -n "$bin" ]] || die 'В release archive нет telemt'
  chmod 0755 "$bin"; "$bin" --help >/dev/null 2>&1 || die 'Новый TeleMT binary не запускается'
  install -d -m 0700 /var/backups/mtpadmin; backup="/var/backups/mtpadmin/telemt-before-${latest}-$(date +%Y%m%d-%H%M%S)"; cp -a /usr/local/bin/telemt "$backup"
  log_status "$COMPONENT" running "Устанавливаю TeleMT $latest; будет короткий restart proxy"
  install -m 0755 -o root -g root "$bin" /usr/local/bin/telemt; systemctl restart mtpadmin-telemt.service
  if ! wait_telemt; then cp -a "$backup" /usr/local/bin/telemt; systemctl restart mtpadmin-telemt.service || true; wait_telemt || true; die "TeleMT $latest не вышел в READY; восстановлен предыдущий binary"; fi
  "$CHECKER" >/dev/null 2>&1 || true; log_status "$COMPONENT" success "TeleMT обновлён ${cur:-?} → $latest"; ok "TeleMT обновлён ${cur:-?} → $latest"
}

repair_webproxy(){
  local commit="$1"
  [[ -x "$WEBINSTALL" ]] || die 'WEB Proxy installer не установлен'
  [[ -x "$WEBBACKEND" ]] || die 'Official MTProxy backend installer не установлен'
  [[ -x "$WEBTELEMETRY" ]] || die 'WEB client telemetry installer не установлен'
  log_status "$COMPONENT" running "Проверяю relay ${commit:0:12}, конфиг и HTTPS"
  TPROXY_COMMIT_OVERRIDE="$commit" bash "$WEBINSTALL"
  log_status "$COMPONENT" running 'Проверяю official MTProxy localhost backend'
  bash "$WEBBACKEND"
  log_status "$COMPONENT" running 'Проверяю privacy-safe WEB client telemetry'
  bash "$WEBTELEMETRY"
  curl -fsS --max-time 3 http://127.0.0.1:8081/readyz >/dev/null || die 'WEB relay не READY после repair'
  curl -fsS --max-time 3 http://127.0.0.1:8081/mtpadmin/clients | python3 -c 'import ipaddress,json,sys; d=json.load(sys.stdin); rows=d.get("clients"); assert isinstance(rows,list); [ipaddress.ip_address(str(x.get("ip"))) for x in rows]' >/dev/null || die 'WEB client telemetry не READY после repair'
  systemctl is-active --quiet mtpadmin-webproxy-mtproxy.service || die 'Official WEB MTProxy backend не active'
  ss -H -ltn 'sport = :2398' | grep -q . || die 'Official WEB MTProxy backend не слушает localhost:2398'
  python3 - /etc/tproxy-server/config.json <<'PY'
import json,sys
with open(sys.argv[1],encoding='utf-8') as f: d=json.load(f)
v=((d.get('limits') or {}).get('max_pending_items_per_session'))
if int(v or 0) < 16384: raise SystemExit(f'unsafe max_pending_items_per_session={v}')
PY
}

update_webproxy(){
  COMPONENT='webproxy'; acquire_lock; log_status "$COMPONENT" running 'Проверяю upstream Telegram WEB Proxy'
  local latest cur
  latest=$(curl -fsSL --retry 3 https://api.github.com/repos/telegramdesktop/tproxy-server/branches/master | python3 -c 'import json,sys; print((json.load(sys.stdin).get("commit") or {}).get("sha", ""))')
  [[ "$latest" =~ ^[0-9a-f]{40}$ ]] || die 'Не удалось определить upstream commit tproxy-server'
  cur=$(cat /usr/local/lib/mtpadmin/tproxy-server.commit 2>/dev/null || true)
  repair_webproxy "$latest"
  "$CHECKER" >/dev/null 2>&1 || true
  if [[ "$cur" == "$latest" ]]; then
    log_status "$COMPONENT" success "WEB Proxy ${latest:0:12} актуален; relay/config/backend/telemetry восстановлены"; ok 'WEB Proxy актуален; полный repair PASS'
  else
    log_status "$COMPONENT" success "WEB Proxy обновлён ${cur:0:12} → ${latest:0:12}; полный repair + telemetry PASS"; ok "WEB Proxy обновлён → ${latest:0:12}; repair PASS"
  fi
}

set_webproxy_host(){
  COMPONENT='webproxy-host'; acquire_lock; local host="${1:-}" cur
  [[ "$host" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$host" == *.* ]] || die 'Некорректный WEB Proxy hostname'
  cur=$(cat /usr/local/lib/mtpadmin/tproxy-server.commit 2>/dev/null || true)
  [[ "$cur" =~ ^[0-9a-f]{40}$ ]] || die 'Не найден установленный commit tproxy-server'
  log_status "$COMPONENT" running "Применяю hostname $host"
  WEBPROXY_HOST_OVERRIDE="$host" TPROXY_COMMIT_OVERRIDE="$cur" bash "$WEBINSTALL"
  bash "$WEBBACKEND"
  bash "$WEBTELEMETRY"
  curl -fsS --max-time 3 http://127.0.0.1:8081/readyz >/dev/null || die 'WEB relay не READY после hostname change'
  curl -fsS --max-time 3 http://127.0.0.1:8081/mtpadmin/clients >/dev/null || die 'WEB telemetry не READY после hostname change'
  "$CHECKER" >/dev/null 2>&1 || true
  log_status "$COMPONENT" success "WEB Proxy hostname: $host; backend + telemetry READY"; ok "WEB Proxy hostname: $host"
}

update_mtpadmin(){
  COMPONENT='mtpadmin'; acquire_lock; log_status "$COMPONENT" running 'Определяю проверенный commit MTPADMIN main'
  TMP=$(mktemp -d)
  local sha version applied
  sha=$(curl -fsSL --retry 3 "$REPO_API/branches/main" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("commit") or {}).get("sha", ""))')
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die 'Не удалось определить commit main'
  curl -fsSL --retry 3 "$REPO_API/contents/VERSION?ref=$sha" | python3 -c 'import base64,json,sys; d=json.load(sys.stdin); print(base64.b64decode(d["content"]).decode().strip())' > "$TMP/version"
  version=$(cat "$TMP/version"); [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'VERSION выбранного commit некорректна'
  log_status "$COMPONENT" running "MTPADMIN $version · commit ${sha:0:12} · blue/green"
  curl -fsSL --retry 3 "$RAW/$sha/update.sh" -o "$TMP/update.sh" || die 'Не удалось скачать commit-pinned update.sh'
  chmod 0700 "$TMP/update.sh"; bash -n "$TMP/update.sh" || die 'update.sh syntax invalid'
  grep -q "VERSION='$version'" "$TMP/update.sh" || die 'Версия commit-pinned updater не совпадает с Update Center'
  if ! MTPADMIN_RELEASE_REF="$sha" bash "$TMP/update.sh"; then
    applied=''
    if [[ -f "$STATE" ]]; then
      applied=$(awk -F= '/^MTPADMIN_VERSION=/{gsub(/[\x27\x22]/,"",$2);print $2}' "$STATE" | tail -1)
    fi
    if [[ "$applied" == "$version" ]]; then
      die "MTPADMIN $version уже применён, но post-update validation/repair не завершился. Основные сервисы оставлены в текущем состоянии; повторите после исправления причины."
    fi
    die "MTPADMIN $version не завершил обновление; post-update installer rc!=0."
  fi
  [[ -x "$CHECKER" ]] && "$CHECKER" >/dev/null 2>&1 || true
  /usr/local/bin/mtpadmin doctor >/dev/null || die 'MTPADMIN обновился, но doctor не прошёл'
  log_status "$COMPONENT" success "MTPADMIN обновлён до $version · ${sha:0:12}"
}

dispatch(){
  local component="${1:-}"; shift || true
  [[ "$component" =~ ^(mtpadmin|telemt|webproxy|webproxy-host)$ ]] || die 'Unknown component'
  local unit="mtpadmin-component-${component//[^a-zA-Z0-9]/-}-$(date +%s)-$$"
  log_status "$component" queued "Задача $unit поставлена в очередь"
  if ! systemd-run --quiet --no-block --collect --unit="$unit" --property=Type=oneshot --property=TimeoutStartSec=1800 /usr/local/lib/mtpadmin/component_update.sh "$component" "$@"; then
    log_status "$component" failed "Не удалось запустить systemd job $unit"
    return 1
  fi
  echo "$unit"
}

case "${1:-}" in
  dispatch) shift; dispatch "$@" ;;
  mtpadmin) update_mtpadmin ;;
  telemt) update_telemt ;;
  webproxy) update_webproxy ;;
  webproxy-host) shift; set_webproxy_host "${1:-}" ;;
  check) COMPONENT='check'; "$CHECKER" ;;
  *) echo 'Usage: component_update.sh {dispatch COMPONENT [ARG]|mtpadmin|telemt|webproxy|webproxy-host HOST|check}' >&2; exit 2 ;;
esac
