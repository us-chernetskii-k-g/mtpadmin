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
# intentionally skipped here because analytics-plus owns the real `/` route and
# kept a stale renderer snapshot. 0.12.4 repairs that route explicitly below
# and then validates the actual browser-visible page.
curl -fsSL --retry 3 "$ROOT/$BASE_0120_COMMIT/update.sh" -o "$TMP/update-0120.sh" || die 'Не удалось скачать проверенный updater 0.12.0.'

python3 - "$TMP/update-0120.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "VERSION='0.12.0'" not in s:
    raise SystemExit('unexpected immutable 0.12.0 updater')
s=s.replace('0.12.0','0.12.4')
s=s.replace('loopback-only telemetry tproxy-server','Обычные MTProto-клиенты и WEB-клиенты показываются в одном списке')
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

info 'Подключаю исправление реального маршрута обзора и мобильное приложение...'
FIX="$TMP/45-ui-loop-fix.py"
PWA="$TMP/46-pwa.py"
DASH="$TMP/47-dashboard-route-fix.py"
curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/web/mtpadmin_web.d/45-ui-loop-fix.py" -o "$FIX" || die 'Не удалось скачать защиту интерфейса.'
curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/web/mtpadmin_web.d/46-pwa.py" -o "$PWA" || die 'Не удалось скачать модуль мобильного приложения.'
curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/web/mtpadmin_web.d/47-dashboard-route-fix.py" -o "$DASH" || die 'Не удалось скачать исправление маршрута обзора.'
grep -Fq '_CLIENT_SCRIPT = _CLIENT_SCRIPT.replace' "$FIX" || die 'Некорректная защита браузерной отрисовки.'
grep -Fq '_PWA_MANIFEST' "$PWA" || die 'Некорректный модуль мобильного приложения.'
grep -Fq '_a_dashboard_html = dashboard_html' "$DASH" || die 'Некорректное исправление маршрута обзора.'

PATCHED="$TMP/mtpadmin-web-patched.py"
python3 - "$WEB_RELEASE" "$FIX" "$PWA" "$DASH" "$PATCHED" <<'PY'
from pathlib import Path
import sys
src,fix,pwa,dash,dst=map(Path,sys.argv[1:])
s=src.read_text(encoding='utf-8')
marker="if __name__=='__main__': main()"
for path, unique in (
    (fix, '# MTPADMIN 0.12.3 browser render-loop safety.'),
    (pwa, '# MTPADMIN 0.12.2 mobile application layer.'),
    (dash, '# MTPADMIN 0.12.4 dashboard route binding fix.'),
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

BACKUP="${WEB_RELEASE}.before-0.12.4-dashboard-fix-$(date +%Y%m%d-%H%M%S)"
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

OVERVIEW=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-0124' "http://127.0.0.1:$WEB_PORT/") || die 'Главная страница не отвечает после 0.12.4.'
DANGEROUS='new MutationObserver(enhance).observe(document.documentElement,{childList:true,subtree:true});'
if grep -Fq "$DANGEROUS" <<<"$OVERVIEW"; then
  die 'Опасный MutationObserver всё ещё попадает в браузерный HTML.'
fi
grep -Fq 'Сервис работает стабильно' <<<"$OVERVIEW" || die 'Реальный маршрут обзора всё ещё использует старый renderer.'
grep -Fq 'Быстрые действия' <<<"$OVERVIEW" || die 'Новая главная страница не отрисовалась полностью.'
grep -Fq 'mtpadmin-client-ui' <<<"$OVERVIEW" || die 'Пользовательский интерфейс не активен.'
grep -Fq 'rel="manifest" href="/manifest.webmanifest"' <<<"$OVERVIEW" || die 'PWA потерян после исправления маршрута.'
grep -Fq 'версия 0.12.4' <<<"$OVERVIEW" || die 'Активная веб-панель показывает неверную версию.'

OPERATIONS=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-0124' "http://127.0.0.1:$WEB_PORT/operations") || die 'Страница управления не отвечает после 0.12.4.'
grep -Fq 'Управление сервисом' <<<"$OPERATIONS" || die 'Страница управления не отрисовалась.'
ACTIVE=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-0124' "http://127.0.0.1:$WEB_PORT/active") || die 'Страница активных клиентов не отвечает после 0.12.4.'
grep -Fq 'WEB потоки' <<<"$ACTIVE" || die 'WEB-клиенты потеряны после исправления маршрута.'

/usr/local/bin/mtpadmin doctor || die 'Итоговая проверка MTPADMIN 0.12.4 обнаружила ошибку.'
ok 'MTPADMIN 0.12.4 установлен: реальный маршрут обзора использует новый интерфейс, PWA сохранён, цикл браузера устранён.'
