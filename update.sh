#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.10.0'
BASE_090_COMMIT='e7475ec650eed8b85aebb2311b74a3ef09a115b2'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_090_COMMIT/update.sh" -o "$TMP/update-090.sh" || die 'Не удалось скачать базовый update 0.9.0.'

python3 - "$TMP/update-090.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')

# Promote the proven 0.9.0 updater to 0.10.0.
s=s.replace('0.9.0','0.10.0')

old='''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/36-analytics.py" -o "$TMP/analytics-extension.py" || die 'Не удалось скачать analytics extension'\n  python3 - "$TMP/mtpadmin_web.py" "$TMP/world-map-extension.py" "$TMP/analytics-extension.py" <<'PYWEBEXT'\n'''
new='''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/36-analytics.py" -o "$TMP/analytics-extension.py" || die 'Не удалось скачать analytics extension'\n  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/37-analytics-plus.py" -o "$TMP/analytics-plus-extension.py" || die 'Не удалось скачать analytics-plus extension'\n  python3 - "$TMP/mtpadmin_web.py" "$TMP/world-map-extension.py" "$TMP/analytics-extension.py" "$TMP/analytics-plus-extension.py" <<'PYWEBEXT'\n'''
if s.count(old)!=1:
    raise SystemExit('unexpected 0.9 web extension block')
s=s.replace(old,new,1)

# After a successful real update, persist one structured event. Test modes exit earlier.
needle='bash "$TMP/update-bootstrap.sh"\n'
if s.count(needle)!=1:
    raise SystemExit('unexpected final bootstrap invocation')
logger=r"""bash "$TMP/update-bootstrap.sh"
python3 - "$VERSION" <<'PYEV' || true
import sqlite3,sys,time
DB='/var/lib/mtpadmin/stats.db'
try:
    with sqlite3.connect(DB,timeout=5) as c:
        c.execute('''CREATE TABLE IF NOT EXISTS system_events(
          id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, category TEXT NOT NULL,
          action TEXT NOT NULL, actor TEXT, detail TEXT)''')
        c.execute('CREATE INDEX IF NOT EXISTS idx_system_events_ts ON system_events(ts DESC)')
        c.execute('INSERT INTO system_events(ts,category,action,actor,detail) VALUES(?,?,?,?,?)',
                  (int(time.time()),'update','MTPADMIN updated','update.sh','version '+sys.argv[1]))
        c.commit()
except Exception:
    pass
PYEV
"""
s=s.replace(needle,logger,1)
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-090.sh" || die '0.10.0 сформировал невалидный updater.'
grep -q "VERSION='0.10.0'" "$TMP/update-090.sh" || die 'Версия updater не обновилась.'
grep -q '37-analytics-plus.py' "$TMP/update-090.sh" || die 'Analytics-plus extension не встроен.'
grep -q 'system_events' "$TMP/update-090.sh" || die 'Event journal logger не встроен.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=2 bash "$TMP/update-090.sh" || die 'Вложенная сборка update-engine не прошла.'
    ok 'Nested 0.10.0 updater transformation PASS'
    exit 0
    ;;
  1)
    ok 'Update wrapper 0.10.0 transformation PASS'
    exit 0
    ;;
esac

bash "$TMP/update-090.sh"
