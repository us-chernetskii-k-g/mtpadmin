# Early dispatch for Scanner Guard commands. Loaded before the legacy main dispatcher.
case "${1:-}" in
  guard-status|scanner-status) shift || true; guard_status_cmd "$@"; exit $?;;
  suspicious) shift || true; suspicious_cmd "$@"; exit $?;;
  bans) shift || true; bans_cmd "$@"; exit $?;;
  ban) shift || true; ban_cmd "$@"; exit $?;;
  unban) shift || true; unban_cmd "$@"; exit $?;;
  whitelist) shift || true; whitelist_cmd "$@"; exit $?;;
  unwhitelist) shift || true; unwhitelist_cmd "$@"; exit $?;;
esac
