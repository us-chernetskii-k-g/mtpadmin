#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.12.1'
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
s=s.replace('0.12.0','0.12.1')
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-0120.sh" || die '0.12.1 сформировал невалидный updater.'
grep -q "VERSION='0.12.1'" "$TMP/update-0120.sh" || die 'Версия updater не обновилась до 0.12.1.'
grep -q 'WEB_IDENTITY_BEFORE' "$TMP/update-0120.sh" || die 'Проверка сохранения WEB-ссылки потеряна.'
grep -q 'Telemetry видит активный WEB IP, но /active его не отображает' "$TMP/update-0120.sh" || die 'Проверка WEB-клиента потеряна.'
grep -q 'mtpadmin-client-ui' "$TMP/update-0120.sh" || die 'Проверка нового интерфейса потеряна.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0120.sh" || die 'Nested 0.12.1 updater transformation failed.'
    ok 'Nested 0.12.1 updater transformation PASS'; exit 0 ;;
  1)
    MTPADMIN_BOOTSTRAP_TEST=1 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0120.sh" || die '0.12.1 wrapper transformation failed.'
    ok '0.12.1 wrapper transformation PASS'; exit 0 ;;
esac

# First run the complete proven 0.12.0 production chain, but with all mutable
# fragments pinned to the exact 0.12.1 commit selected by Update Center.
MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0120.sh"

# 0.12.1 browser hotfix. The 0.12.0 UI added a document-wide
# MutationObserver(enhance). enhance() itself writes navigation textContent,
# which can create another mutation and trap the browser in a render loop.
# Add a final, tiny Python extension that strips only that observer from the
# generated HTML. Server-side handlers, TeleMT, WEB Proxy and secrets are not
# changed by this step.
info 'Устанавливаю исправление отрисовки веб-панели 0.12.1...'
FIX="$TMP/45-ui-loop-fix.py"
curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/web/mtpadmin_web.d/45-ui-loop-fix.py" -o "$FIX" || die 'Не удалось скачать исправление интерфейса 0.12.1.'
grep -Fq '_UI_LOOP_OBSERVER' "$FIX" || die 'Некорректный файл исправления интерфейса.'
grep -Fq 'self-triggering MutationObserver disabled' "$FIX" || die 'В исправлении отсутствует защитный маркер.'

[[ -f /etc/mtpadmin/web-runtime.env ]] || die 'Не найдено состояние активной веб-панели.'
# shellcheck disable=SC1091
source /etc/mtpadmin/web-runtime.env
WEB_SERVICE=${WEB_ACTIVE_SERVICE:?}
WEB_RELEASE=${WEB_ACTIVE_RELEASE:?}
WEB_PORT=${WEB_ACTIVE_PORT:?}
[[ "$WEB_PORT" =~ ^[0-9]+$ ]] || die 'Некорректный порт активной веб-панели.'
[[ -f "$WEB_RELEASE" ]] || die 'Не найдена активная копия веб-панели.'

PATCHED="$TMP/mtpadmin-web-patched.py"
python3 - "$WEB_RELEASE" "$FIX" "$PATCHED" <<'PY'
from pathlib import Path
import sys
src,fix,dst=map(Path,sys.argv[1:])
s=src.read_text(encoding='utf-8')
e=fix.read_text(encoding='utf-8').rstrip()
marker="if __name__=='__main__': main()"
fix_marker='# MTPADMIN 0.12.1 browser UI safety hotfix.'
if fix_marker not in s:
    if s.count(marker)!=1:
        raise SystemExit(f'unexpected main marker count={s.count(marker)}')
    s=s.replace(marker,e+'\n\n'+marker,1)
dst.write_text(s,encoding='utf-8')
PY
python3 -m py_compile "$PATCHED" || die 'Исправленная веб-панель не прошла проверку Python.'
grep -Fq '# MTPADMIN 0.12.1 browser UI safety hotfix.' "$PATCHED" || die 'Исправление не встроилось в веб-панель.'

BACKUP="${WEB_RELEASE}.before-0.12.1-ui-fix-$(date +%Y%m%d-%H%M%S)"
cp -a "$WEB_RELEASE" "$BACKUP"
install -m 0700 -o root -g root "$PATCHED" "$WEB_RELEASE"
systemctl restart "$WEB_SERVICE" || { cp -a "$BACKUP" "$WEB_RELEASE"; systemctl restart "$WEB_SERVICE" || true; die 'Веб-панель не перезапустилась; восстановлена предыдущая копия.'; }

ready=0
for _ in {1..30}; do
  if curl -fsS --max-time 3 -H 'X-MTPADMIN-User: release-ui' "http://127.0.0.1:$WEB_PORT/healthz" >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
if (( ready != 1 )); then
  cp -a "$BACKUP" "$WEB_RELEASE"
  systemctl restart "$WEB_SERVICE" || true
  die 'Веб-панель не вышла в READY после исправления; выполнен откат UI-файла.'
fi

OVERVIEW=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-ui' "http://127.0.0.1:$WEB_PORT/") || die 'Главная страница не отвечает после исправления.'
grep -Fq 'mtpadmin-client-ui' <<<"$OVERVIEW" || die 'Адаптивный интерфейс не активен.'
grep -Fq 'Сервис работает стабильно' <<<"$OVERVIEW" || die 'Новая главная страница не активна.'
grep -Fq 'self-triggering MutationObserver disabled' <<<"$OVERVIEW" || die 'Защита от цикла отрисовки не попала в HTML.'
if grep -Fq 'new MutationObserver(enhance).observe(document.documentElement,{childList:true,subtree:true});' <<<"$OVERVIEW"; then
  die 'Опасный MutationObserver всё ещё попадает в HTML.'
fi

OPERATIONS=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-ui' "http://127.0.0.1:$WEB_PORT/operations") || die 'Страница управления не отвечает.'
grep -Fq 'Управление сервисом' <<<"$OPERATIONS" || die 'Страница управления не отрисовалась после исправления.'

ACTIVE=$(curl -fsS --max-time 8 -H 'X-MTPADMIN-User: release-ui' "http://127.0.0.1:$WEB_PORT/active") || die 'Страница активных клиентов не отвечает.'
grep -Fq 'WEB потоки' <<<"$ACTIVE" || die 'WEB-клиенты потеряны после исправления интерфейса.'

if ! /usr/local/bin/mtpadmin doctor; then
  die 'MTPADMIN 0.12.1 установлен, но итоговая проверка обнаружила ошибку.'
fi
ok 'MTPADMIN 0.12.1 установлен: цикл отрисовки устранён, серверные функции и WEB Proxy сохранены.'
