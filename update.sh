#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.7.2'
BASE_ENGINE_COMMIT='0ab3c3e067831e4343ce63a070e626a8ef1b1bf7'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_ENGINE_COMMIT/update.sh" -o "$TMP/update-engine.sh" || die 'Не удалось скачать базовый update engine.'

python3 - "$TMP/update-engine.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
old_version="VERSION='0.7.1'"
if s.count(old_version) != 1:
    raise SystemExit('unexpected base updater version marker')
s=s.replace(old_version,"VERSION='0.7.2'",1)
old='''  systemctl start "$standby_service" || { journalctl -u "$standby_service" -n 80 --no-pager; die 'Standby web backend не стартовал.'; }
  for i in 1 2 3; do
    curl -fsS --max-time 5 -H 'X-MTPADMIN-User: seamless-health' "http://127.0.0.1:$standby_port/healthz" >/dev/null || { systemctl stop "$standby_service" || true; die 'Standby web healthcheck не прошёл.'; }
    sleep 1
  done
  ok "Standby web $standby_slot готов на 127.0.0.1:$standby_port"
'''
new='''  systemctl start "$standby_service" || { journalctl -u "$standby_service" -n 80 --no-pager; die 'Standby web backend не стартовал.'; }
  standby_ready=0
  for i in {1..15}; do
    if systemctl is-active --quiet "$standby_service" 2>/dev/null && curl -fsS --max-time 2 -H 'X-MTPADMIN-User: seamless-health' "http://127.0.0.1:$standby_port/healthz" >/dev/null 2>&1; then
      standby_ready=1
      break
    fi
    systemctl is-failed --quiet "$standby_service" 2>/dev/null && break
    sleep 1
  done
  if (( standby_ready == 0 )); then
    echo '[INFO] Standby web не вышел в READY; диагностический вывод:' >&2
    systemctl status "$standby_service" --no-pager -l >&2 || true
    journalctl -u "$standby_service" -n 80 --no-pager >&2 || true
    systemctl stop "$standby_service" >/dev/null 2>&1 || true
    die 'Standby web backend не стал готов за 15 секунд.'
  fi
  for i in 1 2 3; do
    sleep 1
    curl -fsS --max-time 3 -H 'X-MTPADMIN-User: seamless-health' "http://127.0.0.1:$standby_port/healthz" >/dev/null 2>&1 || {
      journalctl -u "$standby_service" -n 80 --no-pager >&2 || true
      systemctl stop "$standby_service" >/dev/null 2>&1 || true
      die 'Standby web потерял READY во время стабилизации.'
    }
  done
  ok "Standby web $standby_slot готов на 127.0.0.1:$standby_port"
'''
if s.count(old) != 1:
    raise SystemExit('unexpected standby healthcheck block in pinned updater')
s=s.replace(old,new,1)
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-engine.sh" || die 'Хотфикс сформировал невалидный update engine.'
grep -q "VERSION='0.7.2'" "$TMP/update-engine.sh" || die 'Версия update engine не обновилась.'
grep -q 'standby_ready=0' "$TMP/update-engine.sh" || die 'Readiness wait не встроен.'
grep -q 'не стал готов за 15 секунд' "$TMP/update-engine.sh" || die 'Readiness timeout не встроен.'

if [[ "${MTPADMIN_BOOTSTRAP_TEST:-0}" == 1 ]]; then
  ok 'Update bootstrap 0.7.2 transformation PASS'
  exit 0
fi

bash "$TMP/update-engine.sh"
