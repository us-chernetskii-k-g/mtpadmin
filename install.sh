#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION='0.12.0'
BASE_01115_COMMIT='c874bc494881f8fa6870989ff0315bc39149abd2'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
API='https://api.github.com/repos/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запустите через sudo/root.'
command -v curl >/dev/null 2>&1 || die 'Не найден curl.'

# Fix one exact release before the wizard starts, so a moving main cannot mix
# files from different versions during a clean installation.
if [[ "$RELEASE_REF" == main ]]; then
  resolved=$(curl -fsSL --retry 3 "$API/branches/main" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("commit") or {}).get("sha", ""))' 2>/dev/null || true)
  [[ "$resolved" =~ ^[0-9a-f]{40}$ ]] || die 'Не удалось зафиксировать версию для установки.'
  RELEASE_REF="$resolved"
fi

curl -fsSL --retry 3 "$ROOT/$BASE_01115_COMMIT/install.sh" -o "$TMP/install-01115.sh" || die 'Не удалось скачать проверенный мастер установки 0.11.15.'
python3 - "$TMP/install-01115.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "VERSION='0.11.15'" not in s or 'MTPADMIN CLEAN INSTALL' not in s:
    raise SystemExit('unexpected immutable clean installer')
s=s.replace('0.11.15','0.12.0')
# For a public installer an unresolved/wrong DNS warning must require an
# explicit decision rather than continuing on Enter.
s=s.replace("confirm 'Продолжить даже если выше были DNS WARN?' 'Y'","confirm 'Продолжить даже если выше были предупреждения DNS?' 'N'",1)
# The wizard creates only its private build directory before final approval;
# packages and services are untouched. Keep the wording literally accurate.
s=s.replace('До подтверждения система не изменяется.','До подтверждения пакеты и службы системы не изменяются.',1)
p.write_text(s,encoding='utf-8')
PY
chmod 0700 "$TMP/install-01115.sh"
bash -n "$TMP/install-01115.sh" || die 'Мастер установки не прошёл проверку синтаксиса.'
grep -q "VERSION='0.12.0'" "$TMP/install-01115.sh" || die 'Мастер не обновлён до 0.12.0.'
grep -q 'Домен веб-админки' "$TMP/install-01115.sh" || die 'Настройка домена панели потеряна.'
grep -q 'Повторите пароль веб-админки' "$TMP/install-01115.sh" || die 'Проверка пароля панели потеряна.'
grep -q 'Домен Telegram WEB Proxy' "$TMP/install-01115.sh" || die 'Настройка WEB Proxy потеряна.'

MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/install-01115.sh"
ok 'Чистая установка MTPADMIN 0.12.0 завершена.'
