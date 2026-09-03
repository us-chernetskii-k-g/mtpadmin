#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.12.4'
BASE_0120_COMMIT='6e6a7593b60452c1883e72269a340e97d088c0f3'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

# Start from the audited 0.12.0 production chain. Its old dashboard guard is
# intentionally skipped because analytics-plus owns the real `/` route and had
# retained a stale renderer snapshot. 0.12.4 repairs the route and then applies
# a final browser-stability layer that removes legacy background DOM mutation.
curl -fsSL --retry 3 "$ROOT/$BASE_0120_COMMIT/update.sh" -o "$TMP/update-0120.sh" || die 'Не удалось скачать проверенный updater 0.12.0.'

python3 - "$TMP/update-0120.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "VERSION='0.12.0'" not in s:
    raise SystemExit('unexpected immutable 0.12.0 updater')
s=s.replace('0.12.0','0.12.4')
# Keep the 0.12.0 transform that maps the old /active text marker to the
# user-facing WEB-client sentence. Rewriting its source literal here would
# make the nested updater search for the new text instead of the old one.
old="grep -Fq 'Сервис работает стабильно' <<<\"$overview\" || die 'Новая главная страница не активна.'"
if old not in s:
    raise SystemExit('old dashboard guard not found')
s=s.replace(old, ": # 0.12.4 validates the repaired real dashboard route after rebinding", 1)
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-0120.sh" || die '0.12.4 сформировал невалидный базовый updater.'
grep -q "VERSION='0.12.4'" "$TMP/update-0120.sh" || die 'Версия базового updater не обновилась до 0.12.4.'
grep -q 'WEB_IDENTITY_BEFORE' "$TMP/update-0120.sh" || die 'Проверка сохранения WEB-ссылки потеряна.'
grep -q '0.12.4 validates the repaired real dashboard route' "$TMP/update-0120.sh" || die 'Старый ошибочный dashboard guard не отключён.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0120.sh" || die 'Nested 0.12.4 updater transformation failed.'
    ok 'Nested 0.12.4 updater transformation PASS'; exit 0 ;;
  1)
    MTPADMIN_BOOTSTRAP_TEST=1 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0120.sh" || die '0.12.4 wrapper transformation failed.'
    ok '0.12.4 wrapper transformation PASS'; exit 0 ;;
esac

MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0120.sh"

[[ -f /etc/mtpadmin/web-runtime.env ]] || die 'Не найдено состояние активной веб-панели.'
# shellcheck disable=SC1091
source /etc/mtpadmin/web-runtime.env
WEB_SERVICE=${WEB_ACTIVE_SERVICE:?}
WEB_RELEASE=${WEB_ACTIVE_RELEASE:?}
WEB_PORT=${WEB_ACTIVE_PORT:?}
[[ "$WEB_PORT" =~ ^[0-9]+$ ]] || die 'Некорректный порт активной веб-панели.'
[[ -f "$WEB_RELEASE" ]] || die 'Не найдена активная копия веб-панели.'

info 'Подключаю стабильный пользовательский интерфейс 0.12.4...'
FIX="$TMP/45-ui-loop-fix.py"
PWA="$TMP/46-pwa.py"
DASH="$TMP/47-dashboard-route-fix.py"
STABLE="$TMP/48-browser-stability.py"
curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/web/mtpadmin_web.d/45-ui-loop-fix.py" -o "$FIX" || die 'Не удалось скачать защиту интерфейса.'
curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/web/mtpadmin_web.d/46-pwa.py" -o "$PWA" || die 'Не удалось скачать модуль мобильного приложения.'
curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/web/mtpadmin_web.d/47-dashboard-route-fix.py" -o "$DASH" || die 'Не удалось скачать исправление маршрута обзора.'
curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/web/mtpadmin_web.d/48-browser-stability.py" -o "$STABLE" || die 'Не удалось скачать финальную защиту браузера.'
grep -Fq '_CLIENT_SCRIPT = _CLIENT_SCRIPT.replace' "$FIX" || die 'Некорректная защита браузерной отрисовки.'
grep -Fq '_PWA_MANIFEST' "$PWA" || die 'Некорректный модуль мобильного приложения.'
grep -Fq '_a_dashboard_html = dashboard_html' "$DASH" || die 'Некорректное исправление маршрута обзора.'
grep -Fq '_BS_REPLACEMENTS' "$STABLE" || die 'Некорректная финальная защита браузера.'

PATCHED="$TMP/mtpadmin-web-patched.py"
python3 - "$WEB_RELEASE" "$FIX" "$PWA" "$DASH" "$STABLE" "$PATCHED" <<'PY'
from pathlib import Path
import sys
src,fix,pwa,dash,stable,dst=map(Path,sys.argv[1:])
s=src.read_text(encoding='utf-8')
marker="if __name__=='__main__': main()"
for path, unique in (
    (fix, '# MTPADMIN 0.12.3 browser render-loop safety.'),
    (pwa, '# MTPADMIN 0.12.2 mobile application layer.'),
    (dash, '# MTPADMIN 0.12.4 dashboard route binding fix.'),
    (stable, '# MTPADMIN 0.12.4 browser stability guard.'),
):
    if unique in s:
        continue
    if s.count(marker)!=1:
        raise SystemExit(f'unexpected main marker count={s.count(marker)}')
    ext=path.read_text(encoding='utf-8').rstrip()
    s=s.replace(marker,ext+'\n\n'+marker,1)
dst.write_text(s,encoding='utf-8')
PY
python3 -m py_compile "$PATCHED" || die 'Исправленная веб-панель не прошла проверку Python.'
grep -Fq '# MTPADMIN 0.12.4 dashboard route binding fix.' "$PATCHED" || die 'Исправление маршрута обзора не встроилось.'
grep -Fq '# MTPADMIN 0.12.4 browser stability guard.' "$PATCHED" || die 'Финальная защита браузера не встроилась.'

BACKUP="${WEB_RELEASE}.before-0.12.4-browser-stability-$(date +%Y%m%d-%H%M%S)"
cp -a "$WEB_RELEASE" "$BACKUP"
install -m 0700 -o root -g root "$PATCHED" "$WEB_RELEASE"
if ! systemctl restart "$WEB_SERVICE"; then
    cp -a "$BACKUP" "$WEB_RELEASE"
    systemctl restart "$WEB_SERVICE" || true
    die 'Веб-панель не перезапустилась; восстановлена предыдущая копия.'
fi

ready=0
for _ in {1..30}; do
  if curl -fsS --max-time 3 -H 'X-MTPADMIN-User: release-0124' "http://127.0.0.1:$WEB_PORT/healthz" >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if (( ready != 1 )); then
  cp -a "$BACKUP" "$WEB_RELEASE"
  systemctl restart "$WEB_SERVICE" || true
  die 'Веб-панель не вышла в READY; выполнен откат веб-файла.'
fi

check_browser_page(){
  local path="$1" marker="$2" label="$3" html
  html=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-0124' "http://127.0.0.1:$WEB_PORT$path") || die "$label не отвечает после 0.12.4."
  grep -Fq "$marker" <<<"$html" || die "$label не содержит ожидаемый пользовательский интерфейс."
  if grep -Fq 'new MutationObserver(' <<<"$html"; then die "$label всё ещё содержит MutationObserver."; fi
  if grep -Fq 'setInterval(' <<<"$html"; then die "$label всё ещё содержит фоновый setInterval."; fi
  grep -Fq 'MTPADMIN 0.12.4: background full-page live refresh disabled' <<<"$html" || die "$label не содержит защиту от фоновой полной перерисовки."
  printf '%s' "$html"
}

OVERVIEW=$(check_browser_page '/' 'Сервис работает стабильно' 'Главная страница')
grep -Fq 'Быстрые действия' <<<"$OVERVIEW" || die 'Новая главная страница не отрисовалась полностью.'
grep -Fq 'mtpadmin-client-ui' <<<"$OVERVIEW" || die 'Пользовательский интерфейс не активен.'
grep -Fq 'rel="manifest" href="/manifest.webmanifest"' <<<"$OVERVIEW" || die 'PWA потерян после исправления интерфейса.'
grep -Fq '● по запросу' <<<"$OVERVIEW" || die 'Интерфейс всё ещё обещает фоновое обновление.'
grep -Fq 'версия 0.12.4' <<<"$OVERVIEW" || die 'Активная веб-панель показывает неверную версию.'

OPERATIONS=$(check_browser_page '/operations' 'Управление сервисом' 'Страница управления')
ACTIVE=$(check_browser_page '/active' 'WEB потоки' 'Страница активных клиентов')
GEO=$(check_browser_page '/geo' 'География' 'Страница географии')
grep -Fq 'world-map' <<<"$GEO" || die 'Карта потеряна после отключения MutationObserver.'

/usr/local/bin/mtpadmin doctor || die 'Итоговая проверка MTPADMIN 0.12.4 обнаружила ошибку.'
ok 'MTPADMIN 0.12.4 установлен: реальный маршрут обзора исправлен; фоновые DOM-перестройки отключены; PWA сохранён.'
