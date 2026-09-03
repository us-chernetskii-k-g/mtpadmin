#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.12.0'
BASE_01115_COMMIT='c874bc494881f8fa6870989ff0315bc39149abd2'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_01115_COMMIT/update.sh" -o "$TMP/update-01115.sh" || die 'Не удалось скачать проверенный updater 0.11.15.'

python3 - "$TMP/update-01115.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "VERSION='0.11.15'" not in s:
    raise SystemExit('unexpected immutable 0.11.15 updater')
s=s.replace('0.11.15','0.12.0')
# 0.12.0 intentionally removes developer wording from the visible /active page.
# Keep the old safety check, but bind it to the new user-facing sentence.
s=s.replace('loopback-only telemetry tproxy-server','Обычные MTProto-клиенты и WEB-клиенты показываются в одном списке')
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-01115.sh" || die '0.12.0 сформировал невалидный updater.'
grep -q "VERSION='0.12.0'" "$TMP/update-01115.sh" || die 'Версия updater не обновилась до 0.12.0.'
grep -q 'WEB_IDENTITY_BEFORE' "$TMP/update-01115.sh" || die 'Проверка сохранения WEB-ссылки потеряна.'
grep -q 'Telemetry видит активный WEB IP, но /active его не отображает' "$TMP/update-01115.sh" || die 'Проверка WEB-клиента потеряна.'
grep -q 'Обычные MTProto-клиенты и WEB-клиенты показываются в одном списке' "$TMP/update-01115.sh" || die 'Новый маркер страницы активных клиентов не встроен.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01115.sh" || die 'Nested 0.12.0 updater transformation failed.'
    ok 'Nested 0.12.0 updater transformation PASS'; exit 0 ;;
  1)
    MTPADMIN_BOOTSTRAP_TEST=1 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01115.sh" || die '0.12.0 wrapper transformation failed.'
    ok '0.12.0 wrapper transformation PASS'; exit 0 ;;
esac

# Reuse the proven production chain. RELEASE_REF makes all current fragments,
# including the redesigned 44-webproxy-activity.py, come from one exact release.
MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-01115.sh"

# Browser-visible release guard: verify the real active blue/green slot, not
# merely source files in the repository.
[[ -f /etc/mtpadmin/web-runtime.env ]] || die 'Не найдено состояние активной веб-панели.'
# shellcheck disable=SC1091
source /etc/mtpadmin/web-runtime.env
port=${WEB_ACTIVE_PORT:-}
[[ "$port" =~ ^[0-9]+$ ]] || die 'Не удалось определить порт активной веб-панели.'
header=(-H 'X-MTPADMIN-User: release-ui')

overview=$(curl -fsS --max-time 8 "${header[@]}" "http://127.0.0.1:$port/") || die 'Главная страница не отвечает после обновления.'
grep -Fq 'mtpadmin-client-ui' <<<"$overview" || die 'Новый адаптивный интерфейс не попал в активную веб-панель.'
grep -Fq 'Сервис работает стабильно' <<<"$overview" || die 'Новая главная страница не активна.'
grep -Fq 'Исходный код' <<<"$overview" || die 'Ссылка на GitHub не попала в новый интерфейс.'
grep -Fq 'Помощь и сообщество' <<<"$overview" || die 'Ссылка на сообщество не попала в новый интерфейс.'

operations=$(curl -fsS --max-time 8 "${header[@]}" "http://127.0.0.1:$port/operations") || die 'Страница управления не отвечает.'
grep -Fq 'Управление сервисом' <<<"$operations" || die 'Новая страница управления не активна.'
grep -Fq 'Для специалистов' <<<"$operations" || die 'Раздел технических сведений отсутствует.'

active=$(curl -fsS --max-time 8 "${header[@]}" "http://127.0.0.1:$port/active") || die 'Страница активных клиентов не отвечает.'
grep -Fq 'WEB потоки' <<<"$active" || die 'WEB-сводка не отображается.'
grep -Fq 'Обычные MTProto-клиенты и WEB-клиенты показываются в одном списке' <<<"$active" || die 'Новая понятная WEB-сводка не активна.'

/usr/local/bin/mtpadmin doctor
ok 'MTPADMIN 0.12.0 установлен: новый адаптивный интерфейс + сохранение всех production-проверок PASS.'
