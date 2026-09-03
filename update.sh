#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.12.3'
BASE_0122_COMMIT='00fdcb5c44e20cdae932f5eefe95687adcb1860d'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

# Reuse the fully audited 0.12.2 production chain, but build the runtime from
# the exact 0.12.3 release ref selected by Update Center. 0.12.3 changes the
# browser safety layer itself: the dangerous observer is removed from
# _CLIENT_SCRIPT before any page can be rendered.
curl -fsSL --retry 3 "$ROOT/$BASE_0122_COMMIT/update.sh" -o "$TMP/update-0122.sh" || die 'Не удалось скачать проверенный updater 0.12.2.'

python3 - "$TMP/update-0122.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "VERSION='0.12.2'" not in s:
    raise SystemExit('unexpected immutable 0.12.2 updater')

# Promote the core/web release version to 0.12.3.
s=s.replace('0.12.2','0.12.3')

# The PWA layer itself is unchanged in this stability release. Keep its own
# asset/cache version and source marker at 0.12.2 so the audited module is used
# byte-for-byte while the surrounding MTPADMIN runtime becomes 0.12.3.
s=s.replace('# MTPADMIN 0.12.3 mobile application layer.', '# MTPADMIN 0.12.2 mobile application layer.')
s=s.replace("VERSION='mtpadmin-0.12.3'", "VERSION='mtpadmin-0.12.2'")

p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-0122.sh" || die '0.12.3 сформировал невалидный updater.'
grep -q "VERSION='0.12.3'" "$TMP/update-0122.sh" || die 'Версия updater не обновилась до 0.12.3.'
grep -q 'WEB_IDENTITY_BEFORE' "$TMP/update-0122.sh" || die 'Проверка сохранения WEB-ссылки потеряна.'
grep -q 'mtpadmin-client-ui' "$TMP/update-0122.sh" || die 'Проверка пользовательского интерфейса потеряна.'
grep -q 'manifest.webmanifest' "$TMP/update-0122.sh" || die 'PWA-проверки потеряны.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0122.sh" || die 'Nested 0.12.3 updater transformation failed.'
    ok 'Nested 0.12.3 updater transformation PASS'; exit 0 ;;
  1)
    MTPADMIN_BOOTSTRAP_TEST=1 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0122.sh" || die '0.12.3 wrapper transformation failed.'
    ok '0.12.3 wrapper transformation PASS'; exit 0 ;;
esac

MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0122.sh"

[[ -f /etc/mtpadmin/web-runtime.env ]] || die 'Не найдено состояние активной веб-панели.'
# shellcheck disable=SC1091
source /etc/mtpadmin/web-runtime.env
WEB_SERVICE=${WEB_ACTIVE_SERVICE:?}
WEB_RELEASE=${WEB_ACTIVE_RELEASE:?}
WEB_PORT=${WEB_ACTIVE_PORT:?}
[[ "$WEB_PORT" =~ ^[0-9]+$ ]] || die 'Некорректный порт активной веб-панели.'
[[ -f "$WEB_RELEASE" ]] || die 'Не найдена активная копия веб-панели.'

# Release-level proof: the new direct safety layer must be present in the
# assembled runtime. This checks the actual active blue/green copy, not only
# repository source files.
grep -Fq '# MTPADMIN 0.12.3 browser render-loop safety.' "$WEB_RELEASE" || die 'Прямая защита интерфейса не попала в активный runtime.'
grep -Fq "_CLIENT_SCRIPT = _CLIENT_SCRIPT.replace(_UI_LOOP_OBSERVER, _UI_LOOP_REPLACEMENT, 1)" "$WEB_RELEASE" || die '0.12.3 не изменяет клиентский скрипт до отдачи страницы.'

OVERVIEW=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-0123' "http://127.0.0.1:$WEB_PORT/") || die 'Главная страница не отвечает после 0.12.3.'
DANGEROUS='new MutationObserver(enhance).observe(document.documentElement,{childList:true,subtree:true});'
if grep -Fq "$DANGEROUS" <<<"$OVERVIEW"; then
  die 'Опасный MutationObserver всё ещё попадает в браузерный HTML.'
fi
grep -Fq 'MTPADMIN 0.12.3: self-triggering MutationObserver disabled' <<<"$OVERVIEW" || die 'Маркер прямой защиты 0.12.3 отсутствует в HTML.'
grep -Fq 'mtpadmin-client-ui' <<<"$OVERVIEW" || die 'Пользовательский интерфейс не активен.'
grep -Fq 'rel="manifest" href="/manifest.webmanifest"' <<<"$OVERVIEW" || die 'PWA потерян после стабилизации интерфейса.'

OPERATIONS=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-0123' "http://127.0.0.1:$WEB_PORT/operations") || die 'Страница управления не отвечает после 0.12.3.'
grep -Fq 'Управление сервисом' <<<"$OPERATIONS" || die 'Страница управления не отрисовалась.'

ACTIVE=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-0123' "http://127.0.0.1:$WEB_PORT/active") || die 'Страница активных клиентов не отвечает после 0.12.3.'
grep -Fq 'WEB потоки' <<<"$ACTIVE" || die 'WEB-клиенты потеряны после стабилизации интерфейса.'

/usr/local/bin/mtpadmin doctor || die 'Итоговая проверка MTPADMIN 0.12.3 обнаружила ошибку.'
ok 'MTPADMIN 0.12.3 установлен: PWA сохранён, цикл браузерной отрисовки устранён до формирования HTML.'
