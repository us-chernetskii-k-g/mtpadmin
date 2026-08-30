#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.8.0'
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
s=s.replace(old_version,"VERSION='0.8.0'",1)

old_ready='''  systemctl start "$standby_service" || { journalctl -u "$standby_service" -n 80 --no-pager; die 'Standby web backend не стартовал.'; }
  for i in 1 2 3; do
    curl -fsS --max-time 5 -H 'X-MTPADMIN-User: seamless-health' "http://127.0.0.1:$standby_port/healthz" >/dev/null || { systemctl stop "$standby_service" || true; die 'Standby web healthcheck не прошёл.'; }
    sleep 1
  done
  ok "Standby web $standby_slot готов на 127.0.0.1:$standby_port"
'''
new_ready='''  systemctl start "$standby_service" || { journalctl -u "$standby_service" -n 80 --no-pager; die 'Standby web backend не стартовал.'; }
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
if s.count(old_ready) != 1:
    raise SystemExit('unexpected standby readiness block')
s=s.replace(old_ready,new_ready,1)

old_current='''  standby_service="mtpadmin-web-$standby_slot.service"
  current_service="mtpadmin-web-$current_slot.service"
  if ! systemctl is-active --quiet "$current_service" 2>/dev/null; then
    if systemctl is-active --quiet mtpadmin-web.service 2>/dev/null; then current_service='mtpadmin-web.service';
    else die "Текущий web upstream $current_port есть в Caddy, но его service не активен."; fi
  fi

  # Never disturb the active slot while preparing the candidate.
'''
new_current='''  standby_service="mtpadmin-web-$standby_slot.service"
  current_service="mtpadmin-web-$current_slot.service"

  # Self-heal a half-finished previous switch: Caddy may already point at a
  # canonical slot whose unit exists but was stopped by the old alias handover.
  if ! systemctl is-active --quiet "$current_service" 2>/dev/null && systemctl cat "$current_service" >/dev/null 2>&1; then
    info "Восстанавливаю текущий web slot $current_slot на 127.0.0.1:$current_port..."
    systemctl start "$current_service" >/dev/null 2>&1 || true
    for i in {1..12}; do
      if systemctl is-active --quiet "$current_service" 2>/dev/null && curl -fsS --max-time 2 -H 'X-MTPADMIN-User: recovery-health' "http://127.0.0.1:$current_port/healthz" >/dev/null 2>&1; then
        ok "Текущий web slot $current_slot восстановлен"
        break
      fi
      sleep 1
    done
  fi
  if ! systemctl is-active --quiet "$current_service" 2>/dev/null; then
    if systemctl is-active --quiet mtpadmin-web.service 2>/dev/null; then
      current_service='mtpadmin-web.service'
    else
      systemctl status "mtpadmin-web-$current_slot.service" --no-pager -l >&2 || true
      journalctl -u "mtpadmin-web-$current_slot.service" -n 80 --no-pager >&2 || true
      die "Текущий web upstream $current_port есть в Caddy, но его service не удалось восстановить."
    fi
  fi

  # Never disturb the active slot while preparing the candidate.
'''
if s.count(old_current) != 1:
    raise SystemExit('unexpected current web service resolution block')
s=s.replace(old_current,new_current,1)

old_alias='''  write_web_runtime "$standby_slot" "$standby_port" "$standby_service" "$release"
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
  find "$WEB_RELEASES" -maxdepth 1 -type f -name 'mtpadmin-web-*.py' -printf '%T@ %p\\n' 2>/dev/null | sort -nr | awk 'NR>4{$1="";sub(/^ /,"");print}' | xargs -r rm -f --
  ok "Web blue/green переключён: $current_port -> $standby_port без остановки Caddy"
'''
new_alias='''  write_web_runtime "$standby_slot" "$standby_port" "$standby_service" "$release"

  # Boot persistence points directly at the canonical active slot. Never turn
  # mtpadmin-web.service into a live alias: daemon-reload can merge the stopped
  # legacy unit state into the running slot and stop it.
  wants='/etc/systemd/system/multi-user.target.wants'
  mkdir -p "$wants"
  rm -f "$wants/mtpadmin-web.service" "$wants/mtpadmin-web-blue.service" "$wants/mtpadmin-web-green.service"
  ln -s "../mtpadmin-web-$standby_slot.service" "$wants/mtpadmin-web-$standby_slot.service"
  if [[ -L "$WEB_ALIAS" ]]; then rm -f "$WEB_ALIAS"; fi
  systemctl daemon-reload
  if ! systemctl is-active --quiet "$standby_service"; then
    cp -a "$caddy_before" "$CADDYFILE"
    systemctl reload caddy || true
    systemctl start "$current_service" >/dev/null 2>&1 || true
    die 'Новый web slot остановился при настройке автозапуска; Caddy возвращён назад.'
  fi

  # Only now may the old backend be stopped: Caddy and reboot persistence both
  # already point to the proven standby slot.
  systemctl stop "$current_service" >/dev/null 2>&1 || true
  systemctl is-active --quiet "$standby_service" || die 'Активный web slot неожиданно остановился после остановки старого backend.'
  find "$WEB_RELEASES" -maxdepth 1 -type f -name 'mtpadmin-web-*.py' -printf '%T@ %p\\n' 2>/dev/null | sort -nr | awk 'NR>4{$1="";sub(/^ /,"");print}' | xargs -r rm -f --
  ok "Web blue/green переключён: $current_port -> $standby_port без остановки Caddy"
'''
if s.count(old_alias) != 1:
    raise SystemExit('unexpected legacy web alias handover block')
s=s.replace(old_alias,new_alias,1)

p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-engine.sh" || die 'Хотфикс сформировал невалидный update engine.'
grep -q "VERSION='0.8.0'" "$TMP/update-engine.sh" || die 'Версия update engine не обновилась.'
grep -q 'standby_ready=0' "$TMP/update-engine.sh" || die 'Readiness wait не встроен.'
grep -q 'recovery-health' "$TMP/update-engine.sh" || die 'Recovery текущего slot не встроен.'
grep -q "wants='/etc/systemd/system/multi-user.target.wants'" "$TMP/update-engine.sh" || die 'Прямой boot target не встроен.'
if grep -q 'ln -s "mtpadmin-web-\$standby_slot.service" "\$WEB_ALIAS"' "$TMP/update-engine.sh"; then
  die 'Опасный live alias остался в update engine.'
fi

if [[ "${MTPADMIN_BOOTSTRAP_TEST:-0}" == 1 ]]; then
  ok 'Update bootstrap 0.8.0 transformation PASS'
  exit 0
fi

bash "$TMP/update-engine.sh"
