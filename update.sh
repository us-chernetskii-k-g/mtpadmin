#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.8.1'
BASE_BOOTSTRAP_COMMIT='36e6d6b14bdc3f6c6dad13d1f183f3f2b4328e31'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }

curl -fsSL --retry 3 "$ROOT/$BASE_BOOTSTRAP_COMMIT/update.sh" -o "$TMP/update-bootstrap.sh" || die 'Не удалось скачать базовый update bootstrap.'

python3 - "$TMP/update-bootstrap.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')

# Promote the proven 0.8.0 bootstrap to 0.8.1.
s=s.replace("VERSION='0.8.0'","VERSION='0.8.1'",1)
s=s.replace('s=s.replace(old_version,"VERSION=\'0.8.0\'",1)','s=s.replace(old_version,"VERSION=\'0.8.1\'",1)',1)
s=s.replace('grep -q "VERSION=\'0.8.0\'" "$TMP/update-engine.sh"','grep -q "VERSION=\'0.8.1\'" "$TMP/update-engine.sh"',1)
s=s.replace('Update bootstrap 0.8.0 transformation PASS','Update bootstrap 0.8.1 transformation PASS',1)

marker="p.write_text(s,encoding='utf-8')"
if s.count(marker)!=1:
    raise SystemExit('unexpected 0.8 bootstrap transform marker')
extra=r"""
# 0.8.1: the legacy 20-admin fragment ends inside a PYASN heredoc. Close it
# before runtime extensions, otherwise Guard/doctor text is swallowed by Python.
old_cli="for part in 00-core.sh 10-sources.sh 20-admin.sh 22-guard.sh 25-doctor-runtime.sh 29-guard-dispatch.sh 30-menu.sh; do"
new_cli="for part in 00-core.sh 10-sources.sh 20-admin.sh 21-admin-tail.sh 22-guard.sh 25-doctor-runtime.sh 29-guard-dispatch.sh 30-menu.sh; do"
if s.count(old_cli)!=1: raise SystemExit('unexpected CLI fragment loop')
s=s.replace(old_cli,new_cli,1)

# Keep the old web fragments contiguous, then inject the 0.8.1 extension just
# before main() is invoked. This preserves the intentionally split classes.
old_web='''  for part in 00-core.py 10-ui.py 20-pages.py 30-actions.py; do
    curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/$part" >> "$TMP/mtpadmin_web.py" || die "Не удалось скачать web fragment $part"
  done
'''
new_web=old_web+'''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/35-world-map.py" -o "$TMP/world-map-extension.py" || die 'Не удалось скачать world-map extension'
  python3 - "$TMP/mtpadmin_web.py" "$TMP/world-map-extension.py" <<'PYWEBEXT'
from pathlib import Path
import sys
app=Path(sys.argv[1]); ext=Path(sys.argv[2]).read_text(encoding='utf-8')
src=app.read_text(encoding='utf-8')
marker="if __name__=='__main__': main()"
if src.count(marker)!=1: raise SystemExit('unexpected web main marker')
src=src.replace(marker,ext.rstrip()+"\\n\\n"+marker,1)
app.write_text(src,encoding='utf-8')
PYWEBEXT
'''
if s.count(old_web)!=1: raise SystemExit('unexpected web fragment loop')
s=s.replace(old_web,new_web,1)
"""
s=s.replace(marker,extra+'\n'+marker,1)
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-bootstrap.sh" || die '0.8.1 сформировал невалидный bootstrap.'
grep -q "VERSION='0.8.1'" "$TMP/update-bootstrap.sh" || die 'Версия bootstrap не обновилась.'
grep -q '21-admin-tail.sh' "$TMP/update-bootstrap.sh" || die 'CLI boundary fix не встроен.'
grep -q '35-world-map.py' "$TMP/update-bootstrap.sh" || die 'World map extension не встроен.'

if [[ "${MTPADMIN_BOOTSTRAP_TEST:-0}" == 1 ]]; then
  ok 'Update bootstrap 0.8.1 transformation PASS'
  exit 0
fi

bash "$TMP/update-bootstrap.sh"
