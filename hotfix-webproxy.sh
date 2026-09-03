#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
LIB='/usr/local/lib/mtpadmin'
CURRENT="$LIB/component_update.sh"
LEGACY="$LIB/component_update_legacy.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok(){ echo "[PASS] $*"; }
die(){ echo "[FAIL] $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запустите через sudo/root.'
[[ -f /etc/mtpadmin/state.env && -x "$CURRENT" ]] || die 'MTPADMIN/component updater не найден.'

for file in scripts/webproxy_update_hardening.sh scripts/component_update_wrapper.sh scripts/public_landings_install.sh; do
  dst="$TMP/$(basename "$file")"
  curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/$file" -o "$dst" || die "Не удалось скачать $file"
  bash -n "$dst" || die "Syntax error: $file"
done

install -d -m 0755 -o root -g root "$LIB"
if ! grep -Fq 'component update compatibility wrapper 0.12.5' "$CURRENT"; then
  cp -a "$CURRENT" "$LEGACY"
else
  [[ -x "$LEGACY" ]] || die 'Wrapper уже активен, но legacy updater отсутствует.'
fi
install -m 0755 -o root -g root "$TMP/webproxy_update_hardening.sh" "$LIB/webproxy_update_hardening.sh"
install -m 0755 -o root -g root "$TMP/public_landings_install.sh" "$LIB/public_landings_install.sh"
install -m 0755 -o root -g root "$TMP/component_update_wrapper.sh" "$CURRENT"
ok 'Component updater переключён на hardening-compatible WEB Proxy path'

"$LIB/public_landings_install.sh"
ok 'Public landing pages applied'

TPROXY_COMMIT_OVERRIDE="${TPROXY_COMMIT_OVERRIDE:-}" "$LIB/webproxy_update_hardening.sh"

[[ -x "$LIB/update_check.py" ]] && "$LIB/update_check.py" >/dev/null 2>&1 || true
/usr/local/bin/mtpadmin doctor
ok 'WEB Proxy hardening hotfix PASS'
