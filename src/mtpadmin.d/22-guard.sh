# Scanner Guard / manual firewall controls (MTPADMIN 0.6.0)
GUARD=/usr/local/lib/mtpadmin/scanner_guard.py
SCANNERSVC=mtpadmin-scanner.service

guard_available(){ [[ -x "$GUARD" ]]; }
guard_status_cmd(){ guard_available || { warn 'Scanner Guard не установлен'; return 1; }; "$GUARD" status; }
suspicious_cmd(){ guard_available || { warn 'Scanner Guard не установлен'; return 1; }; "$GUARD" suspicious; }
bans_cmd(){ guard_available || { warn 'Scanner Guard не установлен'; return 1; }; "$GUARD" bans; }
ban_cmd(){
  guard_available || { warn 'Scanner Guard не установлен'; return 1; }
  local ip="${1:-}" duration="${2:-24h}" reason='manual'
  [[ -n "$ip" ]] || { echo 'Usage: mtpadmin ban IP [24h|7d|permanent] [reason]'; return 2; }
  shift || true; [[ $# -gt 0 ]] && shift || true; [[ $# -gt 0 ]] && reason="$*"
  "$GUARD" ban "$ip" "$duration" --reason "$reason" --actor cli
}
unban_cmd(){ [[ -n "${1:-}" ]] || { echo 'Usage: mtpadmin unban IP'; return 2; }; "$GUARD" unban "$1" --actor cli; }
whitelist_cmd(){
  [[ -n "${1:-}" ]] || { echo 'Usage: mtpadmin whitelist IP [note]'; return 2; }
  local ip="$1"; shift || true; "$GUARD" whitelist "$ip" --note "${*:-manual}" --actor cli
}
unwhitelist_cmd(){ [[ -n "${1:-}" ]] || { echo 'Usage: mtpadmin unwhitelist IP'; return 2; }; "$GUARD" unwhitelist "$1" --actor cli; }

security_cmd(){
  header; echo
  echo 'Слушающие порты:'; ss -lntp | grep -E ":${PORT}|:9090|:9091|:9199" || true
  echo; echo "Ошибок/отклонено за время процесса: $(metric telemt_connections_bad_total)"
  echo 'Лимиты источников:'
  current_users_json | jq -r '.data[]?|[.username,(if .enabled then "ON" else "OFF" end),(.max_tcp_conns//"unlimited"),(.max_unique_ips//"unlimited"),(.data_quota_bytes//"unlimited")]|@tsv' | awk 'BEGIN{print "SOURCE\tSTATE\tMAX_CONNS\tMAX_IPS\tQUOTA"}{print}' | column -t
  if systemctl is-active --quiet fail2ban 2>/dev/null; then echo; echo 'Fail2ban:'; fail2ban-client status 2>/dev/null | head -20 || true; fi
  echo; printf 'Права на конфиг: '; stat -c '%A %U:%G %n' "$CFG"
  echo; echo -e "${BOLD}Scanner Guard${NC}"
  systemctl is-active --quiet "$SCANNERSVC" 2>/dev/null && ok 'Наблюдатель активен' || warn 'Наблюдатель не запущен'
  guard_available && "$GUARD" status || warn 'Модуль Scanner Guard отсутствует'
  echo; echo -e "${DIM}Автобан в 0.6.0 отключён. SCAN/HOSTING? — эвристика, а не доказательство принадлежности IP какой-либо организации.${NC}"
}
