#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.9.0'
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

# Promote the proven 0.8.0 bootstrap directly to 0.9.0.
s=s.replace("VERSION='0.8.0'","VERSION='0.9.0'",1)
s=s.replace('s=s.replace(old_version,"VERSION=\'0.8.0\'",1)','s=s.replace(old_version,"VERSION=\'0.9.0\'",1)',1)
s=s.replace('grep -q "VERSION=\'0.8.0\'" "$TMP/update-engine.sh"','grep -q "VERSION=\'0.9.0\'" "$TMP/update-engine.sh"',1)
s=s.replace('Update bootstrap 0.8.0 transformation PASS','Update bootstrap 0.9.0 transformation PASS',1)

marker="p.write_text(s,encoding='utf-8')"
if s.count(marker)!=1:
    raise SystemExit('unexpected 0.8 bootstrap transform marker')
extra=r"""
# 0.9.0 keeps the 0.8.2 normalized CLI and adds online-history analytics.
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

# Inject the online-history extension before collector main().
old_collector=''' : > "$TMP/stats_collector.py"
for part in 00-core.py 10-runtime.py; do
  curl -fsSL --retry 3 "$RAW_BASE/src/stats_collector.d/$part" >> "$TMP/stats_collector.py" || die "Не удалось скачать collector fragment $part"
done
'''.lstrip()
new_collector=old_collector+'''curl -fsSL --retry 3 "$RAW_BASE/src/stats_collector.d/15-online-history.py" -o "$TMP/online-history.py" || die 'Не удалось скачать online-history extension'
python3 - "$TMP/stats_collector.py" "$TMP/online-history.py" <<'PYCOLLECTOREXT'
from pathlib import Path
import sys
app=Path(sys.argv[1]); ext=Path(sys.argv[2]).read_text(encoding='utf-8')
src=app.read_text(encoding='utf-8')
marker="if __name__=='__main__': raise SystemExit(main() or 0)"
if src.count(marker)!=1: raise SystemExit('unexpected collector main marker')
src=src.replace(marker,ext.rstrip()+"\\n\\n"+marker,1)
app.write_text(src,encoding='utf-8')
PYCOLLECTOREXT
'''
if s.count(old_collector)!=1: raise SystemExit('unexpected collector assembly block')
s=s.replace(old_collector,new_collector,1)

# Keep legacy web fragments contiguous and inject extensions in order:
# world-map first, analytics second, both before main().
old_web='''  for part in 00-core.py 10-ui.py 20-pages.py 30-actions.py; do
    curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/$part" >> "$TMP/mtpadmin_web.py" || die "Не удалось скачать web fragment $part"
  done
'''
new_web=old_web+'''  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/35-world-map.py" -o "$TMP/world-map-extension.py" || die 'Не удалось скачать world-map extension'
  curl -fsSL --retry 3 "$RAW_BASE/web/mtpadmin_web.d/36-analytics.py" -o "$TMP/analytics-extension.py" || die 'Не удалось скачать analytics extension'
  python3 - "$TMP/mtpadmin_web.py" "$TMP/world-map-extension.py" "$TMP/analytics-extension.py" <<'PYWEBEXT'
from pathlib import Path
import sys
app=Path(sys.argv[1]); src=app.read_text(encoding='utf-8')
marker="if __name__=='__main__': main()"
if src.count(marker)!=1: raise SystemExit('unexpected web main marker')
for ep in sys.argv[2:]:
    ext=Path(ep).read_text(encoding='utf-8')
    src=src.replace(marker,ext.rstrip()+"\\n\\n"+marker,1)
app.write_text(src,encoding='utf-8')
PYWEBEXT
'''
if s.count(old_web)!=1: raise SystemExit('unexpected web fragment loop')
s=s.replace(old_web,new_web,1)

# Preserve 0.8.2 quiet Caddy formatting/validation.
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

bash -n "$TMP/update-bootstrap.sh" || die '0.9.0 сформировал невалидный bootstrap.'
grep -q "VERSION='0.9.0'" "$TMP/update-bootstrap.sh" || die 'Версия bootstrap не обновилась.'
grep -q 'normalize_cli.py' "$TMP/update-bootstrap.sh" || die 'CLI normalizer не встроен.'
grep -q '15-online-history.py' "$TMP/update-bootstrap.sh" || die 'Online history не встроена.'
grep -q '35-world-map.py' "$TMP/update-bootstrap.sh" || die 'World map extension не встроен.'
grep -q '36-analytics.py' "$TMP/update-bootstrap.sh" || die 'Analytics extension не встроен.'
grep -q 'caddy fmt --overwrite' "$TMP/update-bootstrap.sh" || die 'Caddy formatting не встроен.'

case "${MTPADMIN_BOOTSTRAP_TEST:-0}" in
  2)
    MTPADMIN_BOOTSTRAP_TEST=1 bash "$TMP/update-bootstrap.sh" || die 'Вложенная сборка update-engine не прошла.'
    ok 'Nested update-engine transformation PASS'
    exit 0
    ;;
  1)
    ok 'Update bootstrap 0.9.0 transformation PASS'
    exit 0
    ;;
esac

bash "$TMP/update-bootstrap.sh"
