#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.8.2'
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

# Promote the proven 0.8.0 bootstrap directly to 0.8.2.
s=s.replace("VERSION='0.8.0'","VERSION='0.8.2'",1)
s=s.replace('s=s.replace(old_version,"VERSION=\'0.8.0\'",1)','s=s.replace(old_version,"VERSION=\'0.8.2\'",1)',1)
s=s.replace('grep -q "VERSION=\'0.8.0\'" "$TMP/update-engine.sh"','grep -q "VERSION=\'0.8.2\'" "$TMP/update-engine.sh"',1)
s=s.replace('Update bootstrap 0.8.0 transformation PASS','Update bootstrap 0.8.2 transformation PASS',1)

marker="p.write_text(s,encoding='utf-8')"
if s.count(marker)!=1:
    raise SystemExit('unexpected 0.8 bootstrap transform marker')
extra=r"""
# 0.8.2: close the historical PYASN boundary before runtime extensions and
# normalize the assembled CLI so legacy runtime overrides are physically absent
# from /usr/local/bin/mtpadmin.
old_cli=''' : > "$TMP/mtpadmin"
for part in 00-core.sh 10-sources.sh 20-admin.sh 22-guard.sh 25-doctor-runtime.sh 29-guard-dispatch.sh 30-menu.sh; do
  curl -fsSL --retry 3 "$RAW_BASE/src/mtpadmin.d/$part" >> "$TMP/mtpadmin" || die "Не удалось скачать CLI fragment $part"
done
'''.lstrip()
new_cli=''' : > "$TMP/mtpadmin"
for part in 00-core.sh 10-sources.sh 20-admin.sh 21-admin-tail.sh 22-guard.sh 25-doctor-runtime.sh 29-guard-dispatch.sh 30-menu.sh; do
  curl -fsSL --retry 3 "$RAW_BASE/src/mtpadmin.d/$part" >> "$TMP/mtpadmin" || die "Не удалось скачать CLI fragment $part"
done
curl -fsSL --retry 3 "$RAW_BASE/scripts/normalize_cli.py" -o "$TMP/normalize_cli.py" || die 'Не удалось скачать CLI normalizer'
python3 "$TMP/normalize_cli.py" "$TMP/mtpadmin" || die 'Финальная нормализация CLI не прошла'
'''.lstrip()
if s.count(old_cli)!=1: raise SystemExit('unexpected CLI assembly block')
s=s.replace(old_cli,new_cli,1)

# Keep the old web fragments contiguous, then inject the map extension just
# before main() is invoked. This preserves intentionally split classes.
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

# Format the candidate before validation. Normal updates stay quiet; on a real
# validation failure rerun Caddy visibly so the operator gets diagnostics.
old_caddy='''  build_caddy_candidate "$current_port" "$standby_port"
  caddy validate --config "$TMP/Caddyfile.candidate" --adapter caddyfile >/dev/null || { systemctl stop "$standby_service" || true; die 'Caddy candidate не прошёл validate.'; }
  caddy_before="$TMP/Caddyfile.before-switch"; cp -a "$CADDYFILE" "$caddy_before"
'''
new_caddy='''  build_caddy_candidate "$current_port" "$standby_port"
  caddy fmt --overwrite "$TMP/Caddyfile.candidate" >/dev/null 2>&1 || { systemctl stop "$standby_service" || true; die 'Caddy candidate не удалось отформатировать.'; }
  if ! caddy validate --config "$TMP/Caddyfile.candidate" --adapter caddyfile >/dev/null 2>&1; then
    caddy validate --config "$TMP/Caddyfile.candidate" --adapter caddyfile || true
    systemctl stop "$standby_service" || true
    die 'Caddy candidate не прошёл validate.'
  fi
  caddy_before="$TMP/Caddyfile.before-switch"; cp -a "$CADDYFILE" "$caddy_before"
'''
if s.count(old_caddy)!=1: raise SystemExit('unexpected Caddy validation block')
s=s.replace(old_caddy,new_caddy,1)
"""
s=s.replace(marker,extra+'\n'+marker,1)
p.write_text(s,encoding='utf-8')
PY

bash -n "$TMP/update-bootstrap.sh" || die '0.8.2 сформировал невалидный bootstrap.'
grep -q "VERSION='0.8.2'" "$TMP/update-bootstrap.sh" || die 'Версия bootstrap не обновилась.'
grep -q '21-admin-tail.sh' "$TMP/update-bootstrap.sh" || die 'CLI boundary fix не встроен.'
grep -q 'normalize_cli.py' "$TMP/update-bootstrap.sh" || die 'CLI normalizer не встроен.'
grep -q '35-world-map.py' "$TMP/update-bootstrap.sh" || die 'World map extension не встроен.'
grep -q 'caddy fmt --overwrite' "$TMP/update-bootstrap.sh" || die 'Caddy formatting не встроен.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=1 bash "$TMP/update-bootstrap.sh" || die 'Вложенная сборка update-engine не прошла.'
    ok 'Nested update-engine transformation PASS'
    exit 0
    ;;
  1)
    ok 'Update bootstrap 0.8.2 transformation PASS'
    exit 0
    ;;
esac

bash "$TMP/update-bootstrap.sh"
