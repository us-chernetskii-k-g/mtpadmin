#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.11.7'
BASE_0116_COMMIT='36c0a0e1ad6d21404922c15842fc357b339e6f7f'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_0116_COMMIT/update.sh" -o "$TMP/update-0116.sh" || die 'Не удалось скачать базовый update 0.11.6.'
python3 - "$TMP/update-0116.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "VERSION='0.11.6'" not in s:
    raise SystemExit('unexpected immutable 0.11.6 updater')
s=s.replace('0.11.6','0.11.7')
p.write_text(s,encoding='utf-8')
PY
bash -n "$TMP/update-0116.sh" || die '0.11.7 сформировал невалидный updater.'
grep -q "VERSION='0.11.7'" "$TMP/update-0116.sh" || die 'Версия updater не обновилась.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 bash "$TMP/update-0116.sh" || die 'Вложенная сборка update-engine не прошла.'
    [[ ! -f scripts/webproxy_backend_install.sh ]] || bash -n scripts/webproxy_backend_install.sh
    ok 'Nested 0.11.7 updater transformation PASS'
    exit 0
    ;;
  1)
    MTPADMIN_BOOTSTRAP_TEST=1 bash "$TMP/update-0116.sh" || die 'Update wrapper test не прошёл.'
    [[ ! -f scripts/webproxy_backend_install.sh ]] || bash -n scripts/webproxy_backend_install.sh
    ok 'Update wrapper 0.11.7 transformation PASS'
    exit 0
    ;;
esac

# First update MTPADMIN/web/relay with the already proven 0.11.6 engine,
# transformed only for the new product version.
bash "$TMP/update-0116.sh"

CACHE_BUST="${VERSION}-$(date +%s)"
curl -fsSL --retry 3 "$ROOT/main/scripts/webproxy_backend_install.sh?mtpadmin=$CACHE_BUST" -o "$TMP/webproxy_backend_install.sh" \
  || die 'Не удалось скачать WEB Proxy official MTProxy backend installer.'
bash -n "$TMP/webproxy_backend_install.sh" || die 'WEB backend installer syntax invalid.'
install -m 0700 -o root -g root "$TMP/webproxy_backend_install.sh" /usr/local/lib/mtpadmin/webproxy_backend_install.sh

# Make every future WEB Proxy reinstall/update/hostname change repair the
# official local MTProxy backend after the relay writes its profile.
python3 - /usr/local/lib/mtpadmin/component_update.sh <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "WEBBACKEND='/usr/local/lib/mtpadmin/webproxy_backend_install.sh'" not in s:
    needle="WEBINSTALL='/usr/local/lib/mtpadmin/webproxy_install.sh'\n"
    if s.count(needle)!=1: raise SystemExit('component updater WEBINSTALL marker not found')
    s=s.replace(needle,needle+"WEBBACKEND='/usr/local/lib/mtpadmin/webproxy_backend_install.sh'\n",1)

old="""  if [[ \"$cur\" == \"$latest\" && -x /usr/local/bin/tproxy-server ]]; then log_status \"$COMPONENT\" success \"WEB Proxy уже актуален: ${cur:0:12}\"; ok 'WEB Proxy уже актуален'; return; fi
"""
new="""  if [[ \"$cur\" == \"$latest\" && -x /usr/local/bin/tproxy-server ]]; then
    [[ -x \"$WEBBACKEND\" ]] || die 'WEB Proxy backend installer не установлен'
    bash \"$WEBBACKEND\"
    log_status \"$COMPONENT\" success \"WEB Proxy уже актуален: ${cur:0:12}; official MTProxy backend READY\"; ok 'WEB Proxy уже актуален; backend READY'; return
  fi
"""
if old in s: s=s.replace(old,new,1)
elif 'official MTProxy backend READY' not in s: raise SystemExit('component updater current-WEB branch marker not found')

old='''  TPROXY_COMMIT_OVERRIDE="$latest" bash "$WEBINSTALL"
  "$CHECKER" >/dev/null 2>&1 || true; log_status "$COMPONENT" success "WEB Proxy обновлён ${cur:0:12} → ${latest:0:12}"; ok "WEB Proxy обновлён → ${latest:0:12}"
'''
new='''  TPROXY_COMMIT_OVERRIDE="$latest" bash "$WEBINSTALL"
  [[ -x "$WEBBACKEND" ]] || die 'WEB Proxy backend installer не установлен'
  bash "$WEBBACKEND"
  "$CHECKER" >/dev/null 2>&1 || true; log_status "$COMPONENT" success "WEB Proxy обновлён ${cur:0:12} → ${latest:0:12}; backend READY"; ok "WEB Proxy обновлён → ${latest:0:12}; backend READY"
'''
if old in s: s=s.replace(old,new,1)
elif 'backend READY"; ok "WEB Proxy обновлён' not in s: raise SystemExit('component updater WEB update marker not found')

old='''  log_status "$COMPONENT" running "Применяю hostname $host"; WEBPROXY_HOST_OVERRIDE="$host" bash "$WEBINSTALL"; "$CHECKER" >/dev/null 2>&1 || true
'''
new='''  log_status "$COMPONENT" running "Применяю hostname $host"; WEBPROXY_HOST_OVERRIDE="$host" bash "$WEBINSTALL"; [[ -x "$WEBBACKEND" ]] || die 'WEB Proxy backend installer не установлен'; bash "$WEBBACKEND"; "$CHECKER" >/dev/null 2>&1 || true
'''
if old in s: s=s.replace(old,new,1)
elif "bash \"$WEBBACKEND\"; \"$CHECKER\"" not in s: raise SystemExit('component updater hostname marker not found')
p.write_text(s,encoding='utf-8')
PY
bash -n /usr/local/lib/mtpadmin/component_update.sh || die 'Patched component updater syntax invalid.'

info 'Переключаю Telegram WEB Proxy на официальный локальный MTProxy backend...'
bash /usr/local/lib/mtpadmin/webproxy_backend_install.sh

# Explicit end-to-end local checks. TeleMT on :8443 remains untouched and serves
# ordinary MTProxy users; WEB transport now has its own stock backend on :2398.
systemctl is-active --quiet mtpadmin-webproxy-mtproxy.service || die 'Official WEB MTProxy backend service не активен.'
ss -H -ltn 'sport = :2398' | grep -q . || die 'Official WEB MTProxy backend не слушает 2398.'
nft list table inet mtpadmin_webproxy_backend >/dev/null 2>&1 || die 'WEB MTProxy backend firewall отсутствует.'
curl -fsS --max-time 3 http://127.0.0.1:8081/readyz >/dev/null || die 'WEB relay после backend migration не READY.'

/usr/local/lib/mtpadmin/update_check.py >/dev/null 2>&1 || true

echo
info 'Финальная проверка MTPADMIN + WEB Proxy...'
/usr/local/bin/mtpadmin doctor
ok 'MTPADMIN 0.11.7 установлен: Telegram WEB Proxy использует official MTProxy localhost:2398; TeleMT остаётся на 8443.'
