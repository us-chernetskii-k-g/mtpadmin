#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.12.2'
BASE_0120_COMMIT='6e6a7593b60452c1883e72269a340e97d088c0f3'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_0120_COMMIT/update.sh" -o "$TMP/update-0120.sh" || die 'Не удалось скачать проверенный updater 0.12.0.'

python3 - "$TMP/update-0120.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
if "VERSION='0.12.0'" not in s:
    raise SystemExit('unexpected immutable 0.12.0 updater')
s=s.replace('0.12.0','0.12.2')
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-0120.sh" || die '0.12.2 сформировал невалидный updater.'
grep -q "VERSION='0.12.2'" "$TMP/update-0120.sh" || die 'Версия updater не обновилась до 0.12.2.'
grep -q 'WEB_IDENTITY_BEFORE' "$TMP/update-0120.sh" || die 'Проверка сохранения WEB-ссылки потеряна.'
grep -q 'Telemetry видит активный WEB IP, но /active его не отображает' "$TMP/update-0120.sh" || die 'Проверка WEB-клиента потеряна.'
grep -q 'mtpadmin-client-ui' "$TMP/update-0120.sh" || die 'Проверка нового интерфейса потеряна.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0120.sh" || die 'Nested 0.12.2 updater transformation failed.'
    ok 'Nested 0.12.2 updater transformation PASS'; exit 0 ;;
  1)
    MTPADMIN_BOOTSTRAP_TEST=1 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0120.sh" || die '0.12.2 wrapper transformation failed.'
    ok '0.12.2 wrapper transformation PASS'; exit 0 ;;
esac

# Run the complete proven production chain first. All mutable fragments are
# pinned by Update Center to the exact release commit.
MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0120.sh"

# Add the browser render-loop safety layer and the mobile application layer to
# the active blue/green copy. Neither extension changes TeleMT, tproxy-server,
# Caddy routing, WEB Proxy secrets or source configuration.
info 'Устанавливаю мобильное приложение MTPADMIN 0.12.2...'
FIX="$TMP/45-ui-loop-fix.py"
PWA="$TMP/46-pwa.py"
curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/web/mtpadmin_web.d/45-ui-loop-fix.py" -o "$FIX" || die 'Не удалось скачать защиту интерфейса.'
curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/web/mtpadmin_web.d/46-pwa.py" -o "$PWA" || die 'Не удалось скачать модуль мобильного приложения.'
grep -Fq '_UI_LOOP_OBSERVER' "$FIX" || die 'Некорректный файл защиты интерфейса.'
grep -Fq '_PWA_MANIFEST' "$PWA" || die 'Некорректный модуль мобильного приложения.'
grep -Fq "navigator.serviceWorker.register('/mtpadmin-sw.js'" "$PWA" || die 'В мобильном модуле нет регистрации приложения.'
grep -Fq 'Продолжить в браузере' "$PWA" || die 'В мобильном модуле нет безопасного отказа от установки.'

[[ -f /etc/mtpadmin/web-runtime.env ]] || die 'Не найдено состояние активной веб-панели.'
# shellcheck disable=SC1091
source /etc/mtpadmin/web-runtime.env
WEB_SERVICE=${WEB_ACTIVE_SERVICE:?}
WEB_RELEASE=${WEB_ACTIVE_RELEASE:?}
WEB_PORT=${WEB_ACTIVE_PORT:?}
[[ "$WEB_PORT" =~ ^[0-9]+$ ]] || die 'Некорректный порт активной веб-панели.'
[[ -f "$WEB_RELEASE" ]] || die 'Не найдена активная копия веб-панели.'

PATCHED="$TMP/mtpadmin-web-patched.py"
python3 - "$WEB_RELEASE" "$FIX" "$PWA" "$PATCHED" <<'PY'
from pathlib import Path
import sys
src,fix,pwa,dst=map(Path,sys.argv[1:])
s=src.read_text(encoding='utf-8')
marker="if __name__=='__main__': main()"
for path, unique in (
    (fix, '# MTPADMIN 0.12.1 browser UI safety hotfix.'),
    (pwa, '# MTPADMIN 0.12.2 mobile application layer.'),
):
    if unique in s:
        continue
    if s.count(marker)!=1:
        raise SystemExit(f'unexpected main marker count={s.count(marker)}')
    ext=path.read_text(encoding='utf-8').rstrip()
    s=s.replace(marker,ext+'\n\n'+marker,1)
dst.write_text(s,encoding='utf-8')
PY
python3 -m py_compile "$PATCHED" || die 'Обновлённая веб-панель не прошла проверку Python.'
grep -Fq '# MTPADMIN 0.12.2 mobile application layer.' "$PATCHED" || die 'Мобильный модуль не встроился в веб-панель.'

BACKUP="${WEB_RELEASE}.before-0.12.2-pwa-$(date +%Y%m%d-%H%M%S)"
cp -a "$WEB_RELEASE" "$BACKUP"
install -m 0700 -o root -g root "$PATCHED" "$WEB_RELEASE"
systemctl restart "$WEB_SERVICE" || { cp -a "$BACKUP" "$WEB_RELEASE"; systemctl restart "$WEB_SERVICE" || true; die 'Веб-панель не перезапустилась; восстановлена предыдущая копия.'; }

ready=0
for _ in {1..30}; do
  if curl -fsS --max-time 3 -H 'X-MTPADMIN-User: release-pwa' "http://127.0.0.1:$WEB_PORT/healthz" >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if (( ready != 1 )); then
  cp -a "$BACKUP" "$WEB_RELEASE"
  systemctl restart "$WEB_SERVICE" || true
  die 'Веб-панель не вышла в READY после установки приложения; выполнен откат веб-файла.'
fi

OVERVIEW=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-pwa' "http://127.0.0.1:$WEB_PORT/") || die 'Главная страница не отвечает после обновления.'
grep -Fq 'mtpadmin-client-ui' <<<"$OVERVIEW" || die 'Адаптивный интерфейс не активен.'
grep -Fq 'self-triggering MutationObserver disabled' <<<"$OVERVIEW" || die 'Защита от цикла отрисовки не попала в HTML.'
grep -Fq 'rel="manifest" href="/manifest.webmanifest"' <<<"$OVERVIEW" || die 'Манифест приложения не подключён к странице.'
grep -Fq 'id="m-pwa-sheet"' <<<"$OVERVIEW" || die 'Экран предложения установки не попал в страницу.'
if grep -Fq 'new MutationObserver(enhance).observe(document.documentElement,{childList:true,subtree:true});' <<<"$OVERVIEW"; then
  die 'Опасный MutationObserver всё ещё попадает в HTML.'
fi

MANIFEST=$(curl -fsS --max-time 5 "http://127.0.0.1:$WEB_PORT/manifest.webmanifest") || die 'Манифест приложения не отвечает.'
python3 - "$MANIFEST" <<'PY'
import json,sys
m=json.loads(sys.argv[1])
assert m.get('name')=='MTPADMIN'
assert m.get('display')=='standalone'
assert m.get('scope')=='/'
icons=m.get('icons') or []
assert any(x.get('sizes')=='192x192' for x in icons)
assert any(x.get('sizes')=='512x512' for x in icons)
print('PWA manifest PASS')
PY

SW=$(curl -fsS --max-time 5 "http://127.0.0.1:$WEB_PORT/mtpadmin-sw.js") || die 'Служебный файл приложения не отвечает.'
grep -Fq "VERSION='mtpadmin-0.12.2'" <<<"$SW" || die 'Служебный файл приложения имеет неверную версию.'
grep -Fq 'event.respondWith(fetch(event.request))' <<<"$SW" || die 'Приложение не использует безопасный сетевой режим.'
if grep -Eq 'caches\.(open|match)|CacheStorage' <<<"$SW"; then
  die 'Мобильное приложение не должно кэшировать данные админки.'
fi

python3 - "$WEB_PORT" <<'PY'
import sys,urllib.request
port=sys.argv[1]
for name in ('pwa-icon-192.png','pwa-icon-512.png'):
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/{name}',timeout=5) as r:
        data=r.read(8)
    assert data==b'\x89PNG\r\n\x1a\n', (name,data)
print('PWA icons PASS')
PY

OPERATIONS=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-pwa' "http://127.0.0.1:$WEB_PORT/operations") || die 'Страница управления не отвечает.'
grep -Fq 'Управление сервисом' <<<"$OPERATIONS" || die 'Страница управления не отрисовалась.'
ACTIVE=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-pwa' "http://127.0.0.1:$WEB_PORT/active") || die 'Страница активных клиентов не отвечает.'
grep -Fq 'WEB потоки' <<<"$ACTIVE" || die 'WEB-клиенты потеряны после установки приложения.'

if ! /usr/local/bin/mtpadmin doctor; then
  die 'MTPADMIN 0.12.2 установлен, но итоговая проверка обнаружила ошибку.'
fi
ok 'MTPADMIN 0.12.2 установлен: на телефоне предлагается установка приложения, данные админки не кэшируются.'
