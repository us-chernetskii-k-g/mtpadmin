#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# MTPADMIN component update compatibility wrapper 0.12.5.
# The legacy dispatcher remains authoritative for MTPADMIN/TeleMT/jobs. Only the
# direct WEB Proxy worker is replaced because upstream c0e9+ requires a persistent
# token signing key and first-upgrade drain handling.
LEGACY='/usr/local/lib/mtpadmin/component_update_legacy.sh'
HARDENING='/usr/local/lib/mtpadmin/webproxy_update_hardening.sh'
LANDINGS='/usr/local/lib/mtpadmin/public_landings_install.sh'

[[ -x "$LEGACY" ]] || { echo '[FAIL] legacy component updater missing' >&2; exit 1; }

case "${1:-}" in
  webproxy)
    [[ -x "$HARDENING" ]] || { echo '[FAIL] WEB Proxy hardening updater missing' >&2; exit 1; }
    "$HARDENING"
    [[ ! -x "$LANDINGS" ]] || "$LANDINGS" --webproxy-only
    ;;
  webproxy-host)
    "$LEGACY" "$@"
    [[ ! -x "$LANDINGS" ]] || "$LANDINGS" --webproxy-only
    ;;
  *)
    exec "$LEGACY" "$@"
    ;;
esac
