#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.11.15'
BASE_01114_COMMIT='35fca2b4e41b8f7bce580aa22013df6cd3caea37'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_01114_COMMIT/update.sh" -o "$TMP/update-01114.sh" || die 'Не удалось скачать immutable update 0.11.14.'

python3 - "$TMP/update-01114.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "VERSION='0.11.14'" not in s:
    raise SystemExit('unexpected immutable 0.11.14 updater')
s=s.replace('0.11.14','0.11.15')
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-01114.sh" || die '0.11.15 сформировал невалидный updater.'
grep -q "VERSION='0.11.15'" "$TMP/update-01114.sh" || die 'Версия updater не обновилась до 0.11.15.'
grep -q 'webproxy_telemetry_install.sh' "$TMP/update-01114.sh" || die 'WEB telemetry installer потерян.'
grep -q "prefix='/action/component-update/'" "$TMP/update-01114.sh" || die 'Route-safe Update Center потерян.'
grep -q 'PRAGMA busy_timeout=5000' "$TMP/update-01114.sh" || die 'SQLite hardening потерян.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01114.sh" || die 'Nested 0.11.15 updater transformation failed.'
    ok 'Nested 0.11.15 updater transformation PASS'; exit 0 ;;
  1)
    MTPADMIN_BOOTSTRAP_TEST=1 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01114.sh" || die '0.11.15 wrapper transformation failed.'
    ok '0.11.15 wrapper transformation PASS'; exit 0 ;;
esac

web_identity(){
  local state='/etc/mtpadmin/state.env' cfg='/etc/mtpadmin/config/config.toml'
  [[ -f "$state" && -f "$cfg" ]] || { printf '||\n'; return 0; }
  (
    set +u
    # shellcheck disable=SC1090
    source "$state"
    local host="${WEBPROXY_HOST:-}" source_name="${WEBPROXY_SOURCE:-WEB_PROXY}" secret_hash
    secret_hash=$(python3 - "$cfg" "$source_name" <<'PY'
import hashlib,sys,tomllib
path,name=sys.argv[1:3]
try:
    with open(path,'rb') as f: d=tomllib.load(f)
    secret=str((((d.get('access') or {}).get('users') or {}).get(name)) or '').lower()
except Exception:
    secret=''
if len(secret)==32 and all(c in '0123456789abcdef' for c in secret):
    print(hashlib.sha256(secret.encode('ascii')).hexdigest())
else:
    print('')
PY
)
    printf '%s|%s|%s\n' "$host" "$source_name" "$secret_hash"
  )
}

WEB_IDENTITY_BEFORE=$(web_identity)
IFS='|' read -r WEB_HOST_BEFORE WEB_SOURCE_BEFORE WEB_SECRET_HASH_BEFORE <<<"$WEB_IDENTITY_BEFORE"

# Reuse the proven 0.11.14 production chain, pinned to the exact selected
# release commit. The current runtime fragments are therefore assembled from
# this 0.11.15 commit while retaining all earlier rollback/blue-green checks.
MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01114.sh"

WEB_IDENTITY_AFTER=$(web_identity)
IFS='|' read -r WEB_HOST_AFTER WEB_SOURCE_AFTER WEB_SECRET_HASH_AFTER <<<"$WEB_IDENTITY_AFTER"
if [[ -n "$WEB_HOST_BEFORE" && "$WEB_HOST_AFTER" != "$WEB_HOST_BEFORE" ]]; then
  die 'WEB Proxy hostname unexpectedly changed during MTPADMIN update; old public links may be affected.'
fi
if [[ -n "$WEB_SOURCE_BEFORE" && -n "$WEB_SECRET_HASH_BEFORE" ]]; then
  [[ "$WEB_SOURCE_AFTER" == "$WEB_SOURCE_BEFORE" ]] || die 'WEB Proxy source unexpectedly changed during MTPADMIN update.'
  [[ "$WEB_SECRET_HASH_AFTER" == "$WEB_SECRET_HASH_BEFORE" ]] || die 'WEB Proxy secret unexpectedly changed during MTPADMIN update; old public links would stop working.'
  ok 'WEB Proxy public link identity preserved: hostname/source/secret unchanged'
fi

# 0.11.15 regression guard: analytics-plus owns the actual /active HTTP route.
# Verify the browser-visible route, not merely the helper function, so a stale
# extension snapshot cannot silently hide WEB clients again.
if [[ -f /etc/mtpadmin/web-runtime.env ]]; then
  # shellcheck disable=SC1091
  source /etc/mtpadmin/web-runtime.env
  port=${WEB_ACTIVE_PORT:-}
  [[ "$port" =~ ^[0-9]+$ ]] || die 'Не удалось определить active web port для WEB activity regression.'
  active_html=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-web-activity' "http://127.0.0.1:$port/active") || die 'Active web route не отвечает после blue/green update.'
  grep -Fq 'WEB потоки' <<<"$active_html" || die 'Active web route всё ещё использует TeleMT-only renderer: нет WEB потоки.'
  grep -Fq 'TeleMT + WEB Proxy' <<<"$active_html" || die 'Active web route не объединяет TeleMT + WEB Proxy.'
  grep -Fq 'loopback-only telemetry tproxy-server' <<<"$active_html" || die 'Active web route не использует WEB telemetry renderer.'
  web_live_ip=$(curl -fsS --max-time 3 http://127.0.0.1:8081/mtpadmin/clients 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); rows=d.get("clients") or []; print(str(rows[0].get("ip") or "") if rows else "")' 2>/dev/null || true)
  if [[ -n "$web_live_ip" ]]; then
    grep -Fq "$web_live_ip" <<<"$active_html" || die 'Telemetry видит активный WEB IP, но /active его не отображает.'
    ok 'Active web route показывает живой WEB client из telemetry'
  else
    ok 'Active web route использует WEB-aware renderer; живых WEB клиентов в момент проверки нет'
  fi
fi

[[ -x /usr/local/lib/mtpadmin/update_check.py ]] && /usr/local/lib/mtpadmin/update_check.py >/dev/null 2>&1 || true
if ! /usr/local/bin/mtpadmin doctor; then
  die 'MTPADMIN 0.11.15 установлен, но итоговый doctor обнаружил failure. Версия не откатывается автоматически; исправьте указанную проверку.'
fi

ok 'MTPADMIN 0.11.15 updater завершён: WEB /active route + public link identity + runtime source semantics PASS.'
