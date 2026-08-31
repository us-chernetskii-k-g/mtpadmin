#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.11.8'
BASE_0116_COMMIT='36c0a0e1ad6d21404922c15842fc357b339e6f7f'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_0116_COMMIT/update.sh" -o "$TMP/update-0116.sh" || die 'Не удалось скачать базовый update 0.11.6.'

python3 - "$TMP/update-0116.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "VERSION='0.11.6'" not in s: raise SystemExit('unexpected immutable 0.11.6 updater')
s=s.replace('0.11.6','0.11.8')

# The immutable 0.11.6 wrapper itself transforms the older 0.9 updater.
# Inject one extra transformation into that inner Python block. Doing this at
# the transformation layer is intentionally more robust than trying to match
# the escaped 0.11.6 source string from the outer wrapper.
write_marker="p.write_text(s,encoding='utf-8')"
if s.count(write_marker)!=1:
    raise SystemExit('0.11.6 transform write marker not found')
extra=r'''
# 0.11.8: assemble the audited source lifecycle fragment in the generated CLI.
cli_old='for part in 00-core.sh 10-sources.sh 20-admin.sh 21-admin-tail.sh 22-guard.sh 25-doctor-runtime.sh 29-guard-dispatch.sh 30-menu.sh; do'
cli_new='for part in 00-core.sh 10-sources.sh 11-source-stability.sh 20-admin.sh 21-admin-tail.sh 22-guard.sh 25-doctor-runtime.sh 29-guard-dispatch.sh 30-menu.sh; do'
if s.count(cli_old)!=1: raise SystemExit('0.11.8 CLI assembly marker not found')
s=s.replace(cli_old,cli_new,1)

# 0.11.6 has already expanded the 0.9 web assembly through fragment 41 by the
# time this code runs. Extend that already-generated shell block through 43.
web_fetch='''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/41-webproxy-links-ui.py" -o "$TMP/webproxy-links-ui-extension.py" || die 'Не удалось скачать WEB Proxy links UI extension'\n'''
web_fetch_new=web_fetch+'''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/42-stability.py" -o "$TMP/stability-extension.py" || die 'Не удалось скачать stability extension'\n  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/43-db-safety.py" -o "$TMP/db-safety-extension.py" || die 'Не удалось скачать DB safety extension'\n'''
if s.count(web_fetch)!=1: raise SystemExit('0.11.8 web fetch marker not found')
s=s.replace(web_fetch,web_fetch_new,1)

web_args='''  python3 - "$TMP/mtpadmin_web.py" "$TMP/world-map-extension.py" "$TMP/analytics-extension.py" "$TMP/analytics-plus-extension.py" "$TMP/operations-extension.py" "$TMP/compact-ui-extension.py" "$TMP/async-update-ui-extension.py" "$TMP/webproxy-links-ui-extension.py" <<'PYWEBEXT'\n'''
web_args_new='''  python3 - "$TMP/mtpadmin_web.py" "$TMP/world-map-extension.py" "$TMP/analytics-extension.py" "$TMP/analytics-plus-extension.py" "$TMP/operations-extension.py" "$TMP/compact-ui-extension.py" "$TMP/async-update-ui-extension.py" "$TMP/webproxy-links-ui-extension.py" "$TMP/stability-extension.py" "$TMP/db-safety-extension.py" <<'PYWEBEXT'\n'''
if s.count(web_args)!=1: raise SystemExit('0.11.8 web argument marker not found')
s=s.replace(web_args,web_args_new,1)
'''
s=s.replace(write_marker,extra+'\n'+write_marker,1)
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-0116.sh" || die '0.11.8 сформировал невалидный updater.'
grep -q "VERSION='0.11.8'" "$TMP/update-0116.sh" || die 'Версия updater не обновилась.'
grep -q '11-source-stability.sh' "$TMP/update-0116.sh" || die 'Source stability CLI не встроен.'
grep -q '42-stability.py' "$TMP/update-0116.sh" || die 'Web stability extension не встроен.'
grep -q '43-db-safety.py' "$TMP/update-0116.sh" || die 'DB safety extension не встроен.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 bash "$TMP/update-0116.sh" || die 'Вложенная сборка update-engine не прошла.'
    [[ ! -f scripts/webproxy_install.sh ]] || bash -n scripts/webproxy_install.sh
    [[ ! -f scripts/webproxy_backend_install.sh ]] || bash -n scripts/webproxy_backend_install.sh
    ok 'Nested 0.11.8 updater transformation PASS'; exit 0 ;;
  1)
    MTPADMIN_BOOTSTRAP_TEST=1 bash "$TMP/update-0116.sh" || die 'Update wrapper test не прошёл.'
    ok 'Update wrapper 0.11.8 transformation PASS'; exit 0 ;;
esac

# Proven blue/green engine, now transformed to assemble audited 0.11.8 fragments.
bash "$TMP/update-0116.sh"

CACHE_BUST="${VERSION}-$(date +%s)"
for file in webproxy_install.sh webproxy_backend_install.sh update_check.py component_update.sh; do
  curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/scripts/$file?mtpadmin=$CACHE_BUST" -o "$TMP/$file" || die "Не удалось скачать scripts/$file"
done
bash -n "$TMP/webproxy_install.sh" || die 'WEB Proxy installer syntax invalid.'
bash -n "$TMP/webproxy_backend_install.sh" || die 'WEB backend installer syntax invalid.'
bash -n "$TMP/component_update.sh" || die 'Component updater syntax invalid.'
python3 -m py_compile "$TMP/update_check.py" || die 'Update checker syntax invalid.'
install -d -m 0755 /usr/local/lib/mtpadmin
install -m 0700 -o root -g root "$TMP/webproxy_install.sh" /usr/local/lib/mtpadmin/webproxy_install.sh
install -m 0700 -o root -g root "$TMP/webproxy_backend_install.sh" /usr/local/lib/mtpadmin/webproxy_backend_install.sh
install -m 0700 -o root -g root "$TMP/component_update.sh" /usr/local/lib/mtpadmin/component_update.sh
install -m 0755 -o root -g root "$TMP/update_check.py" /usr/local/lib/mtpadmin/update_check.py

info 'Проверяю/восстанавливаю Telegram WEB Proxy...'
bash /usr/local/lib/mtpadmin/webproxy_install.sh
bash /usr/local/lib/mtpadmin/webproxy_backend_install.sh

# If a historical hot reload left config/runtime out of sync, repair once with a
# full TeleMT restart. Do not rotate or delete any source.
if ! python3 - <<'PY'
import json,tomllib,urllib.request
with open('/etc/mtpadmin/config/config.toml','rb') as f: cfg=set(((tomllib.load(f).get('access') or {}).get('users') or {}))
with urllib.request.urlopen('http://127.0.0.1:9091/v1/users',timeout=4) as r: run={str(x.get('username')) for x in (json.load(r).get('data') or [])}
raise SystemExit(0 if cfg==run else 1)
PY
then
  warn 'TeleMT config/runtime sources расходятся; выполняю один repair restart.'
  systemctl restart mtpadmin-telemt.service
  ready=0
  for i in {1..30}; do systemctl is-active --quiet mtpadmin-telemt.service && curl -fsS --max-time 2 http://127.0.0.1:9091/v1/health/ready >/dev/null 2>&1 && { ready=1; break; }; sleep 1; done
  (( ready == 1 )) || die 'TeleMT не вышел в READY после source repair restart.'
  python3 - <<'PY' || die 'После restart config/runtime sources всё ещё расходятся.'
import json,tomllib,urllib.request
with open('/etc/mtpadmin/config/config.toml','rb') as f: cfg=set(((tomllib.load(f).get('access') or {}).get('users') or {}))
with urllib.request.urlopen('http://127.0.0.1:9091/v1/users',timeout=4) as r: run={str(x.get('username')) for x in (json.load(r).get('data') or [])}
assert cfg==run,(sorted(cfg),sorted(run))
PY
  systemctl restart mtpadmin-scanner.service >/dev/null 2>&1 || true
fi

info 'Проверяю базу статистики...'
[[ "$(sqlite3 /var/lib/mtpadmin/stats.db 'PRAGMA quick_check;' 2>/dev/null | head -1)" == ok ]] || die 'SQLite stats.db quick_check failed.'

info 'Проверяю WEB relay data-path contract...'
python3 - <<'PY' || exit 1
import json
with open('/etc/tproxy-server/config.json',encoding='utf-8') as f:d=json.load(f)
v=int((d.get('limits') or {}).get('max_pending_items_per_session') or 0)
assert v>=16384,v
PY
systemctl is-active --quiet tproxy-server.service || die 'tproxy-server не active.'
systemctl is-active --quiet mtpadmin-webproxy-mtproxy.service || die 'official MTProxy backend не active.'
ss -H -ltn 'sport = :2398' | grep -q . || die 'official MTProxy backend не слушает 2398.'
curl -fsS --max-time 3 http://127.0.0.1:8081/readyz >/dev/null || die 'WEB relay не READY.'

info 'FD regression активного blue/green web...'
if [[ -f /etc/mtpadmin/web-runtime.env ]]; then
  # shellcheck disable=SC1091
  source /etc/mtpadmin/web-runtime.env
  svc=${WEB_ACTIVE_SERVICE:-}; port=${WEB_ACTIVE_PORT:-}
  if [[ -n "$svc" && -n "$port" ]]; then
    pid=$(systemctl show -p MainPID --value "$svc" 2>/dev/null || true)
    if [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 && -d "/proc/$pid/fd" ]]; then
      before=$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 | wc -l)
      for i in {1..30}; do curl -fsS -H 'X-MTPADMIN-User: release-fd-test' --max-time 5 "http://127.0.0.1:$port/" >/dev/null; done
      sleep 1; after=$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 | wc -l); delta=$((after-before))
      (( delta <= 5 )) || die "Web FD regression: before=$before after=$after delta=$delta"
      ok "Web FD stable: before=$before after=$after delta=$delta"
    fi
  fi
fi

/usr/local/lib/mtpadmin/update_check.py >/dev/null 2>&1 || true
systemctl restart mtpadmin-scanner.service >/dev/null 2>&1 || true
sleep 2

echo
info 'Финальная проверка MTPADMIN 0.11.8...'
/usr/local/bin/mtpadmin doctor
ok 'MTPADMIN 0.11.8 установлен: source lifecycle, persistent stats, WEB Proxy repair, FD regression и VPN BOSS integration.'
