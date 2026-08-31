#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.11.10'
BASE_0118_COMMIT='d99aade365007f83c82a05948010ccd1f12feeec'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_0118_COMMIT/update.sh" -o "$TMP/update-0118.sh" || die 'Не удалось скачать immutable update 0.11.8.'

python3 - "$TMP/update-0118.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
if "VERSION='0.11.8'" not in s:
    raise SystemExit('unexpected immutable 0.11.8 updater')
s=s.replace('0.11.8','0.11.10')

# Keep the proven 0.11.9 SQLite quick-check hardening.
old="""info 'Проверяю базу статистики...'
[[ "$(sqlite3 /var/lib/mtpadmin/stats.db 'PRAGMA quick_check;' 2>/dev/null | head -1)" == ok ]] || die 'SQLite stats.db quick_check failed.'
"""
new="""info 'Проверяю базу статистики...'
python3 - <<'PYDB' || die 'SQLite stats.db quick_check failed.'
import sqlite3,time
path='/var/lib/mtpadmin/stats.db'
last=None
for attempt in range(6):
    try:
        con=sqlite3.connect(f'file:{path}?mode=ro', uri=True, timeout=5.0)
        try:
            con.execute('PRAGMA busy_timeout=5000')
            rows=con.execute('PRAGMA quick_check').fetchall()
        finally:
            con.close()
        if rows and all(str(row[0]).lower()=='ok' for row in rows):
            print('ok')
            raise SystemExit(0)
        last=RuntimeError(f'quick_check returned {rows!r}')
    except sqlite3.OperationalError as exc:
        last=exc
    time.sleep(0.5)
raise SystemExit(f'quick_check failed after retries: {last!r}')
PYDB
ok 'Statistics DB quick_check PASS'
"""
if s.count(old)!=1:
    raise SystemExit(f'0.11.8 DB quick_check marker count={s.count(old)}')
s=s.replace(old,new,1)

# 0.11.10: append the WEB activity layer after db-safety in the generated
# blue/green web release. The layer reads only loopback tproxy metrics and does
# not expose or invent client IP data.
fetch_marker='''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/43-db-safety.py" -o "$TMP/db-safety-extension.py" || die 'Не удалось скачать DB safety extension'\\n'''
fetch_extra='''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/44-webproxy-activity.py" -o "$TMP/webproxy-activity-extension.py" || die 'Не удалось скачать WEB activity extension'\\n'''
if s.count(fetch_marker)!=1:
    raise SystemExit(f'0.11.10 web activity fetch marker count={s.count(fetch_marker)}')
s=s.replace(fetch_marker,fetch_marker+fetch_extra,1)

args_marker='''"$TMP/stability-extension.py" "$TMP/db-safety-extension.py" <<'PYWEBEXT'\\n'''
args_new='''"$TMP/stability-extension.py" "$TMP/db-safety-extension.py" "$TMP/webproxy-activity-extension.py" <<'PYWEBEXT'\\n'''
if s.count(args_marker)!=1:
    raise SystemExit(f'0.11.10 web activity args marker count={s.count(args_marker)}')
s=s.replace(args_marker,args_new,1)

p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-0118.sh" || die '0.11.10 сформировал невалидный updater.'
grep -q "VERSION='0.11.10'" "$TMP/update-0118.sh" || die 'Версия updater не обновилась до 0.11.10.'
grep -q 'PRAGMA busy_timeout=5000' "$TMP/update-0118.sh" || die 'Надёжный SQLite check не встроен.'
grep -q 'repair-misplaced' "$TMP/update-0118.sh" || die 'Source TOML migration потеряна.'
grep -q '44-webproxy-activity.py' "$TMP/update-0118.sh" || die 'WEB activity UI layer не встроен.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0118.sh" || die 'Nested 0.11.10 updater transformation failed.'
    ok 'Nested 0.11.10 updater transformation PASS'; exit 0 ;;
  1)
    MTPADMIN_BOOTSTRAP_TEST=1 MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0118.sh" || die '0.11.10 wrapper transformation failed.'
    ok '0.11.10 wrapper transformation PASS'; exit 0 ;;
esac

MTPADMIN_RELEASE_REF="$RELEASE_REF" bash "$TMP/update-0118.sh"

ok 'MTPADMIN 0.11.10 updater завершён.'
