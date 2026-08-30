# Runtime-safe doctor helpers for MTPADMIN 0.11.1.
# The web panel runs with NoNewPrivileges=true, so sudo cannot be used there
# merely to drop privileges. runuser works without granting new privileges.
as_mtpadmin(){
  if command -v runuser >/dev/null 2>&1; then runuser -u mtpadmin -- "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo -u mtpadmin "$@"
  else return 127; fi
}

psi_avg10(){
  local kind="${1:-some}"
  [[ -r /proc/pressure/memory ]] || { echo 0; return; }
  awk -v k="$kind" '$1==k{for(i=1;i<=NF;i++)if($i~/^avg10=/){split($i,a,"=");print a[2];exit}}' /proc/pressure/memory
}

resources_cmd(){
  header; echo
  echo 'TeleMT:'; ps -o pid,user,%cpu,%mem,rss,vsz,etime,cmd -C telemt
  if [[ "${WEBPROXY_ENABLED:-0}" == 1 ]]; then echo; echo 'Telegram WEB Proxy:'; ps -o pid,user,%cpu,%mem,rss,vsz,etime,cmd -C tproxy-server || true; fi
  echo; echo 'Память:'; free -h; echo
  if [[ -r /proc/pressure/memory ]]; then echo 'Memory pressure PSI:'; cat /proc/pressure/memory; echo; fi
  echo 'Swap / major faults (накопительные счётчики):'
  awk '$1=="pswpin"||$1=="pswpout"||$1=="pgmajfault"{printf "  %-12s %s\n",$1,$2}' /proc/vmstat 2>/dev/null || true
  if command -v vmstat >/dev/null 2>&1; then echo; echo 'Текущая активность памяти, выборка 1 сек (si/so = swap in/out):'; vmstat 1 2 | tail -2; fi
  echo; uptime; echo; df -h /
}

doctor_cmd(){
  reload_state; header; echo
  local f=0 w=0 dns hb now age rss avail swapused swaptotal swappct ghb gage webp websvc psisome psifull wp_host wpdns
  [[ -x /usr/local/bin/telemt ]]&&ok 'TeleMT native binary'||{ fail 'TeleMT binary missing';((f++))||true; }
  systemctl is-active --quiet "$SERVICE"&&ok 'TeleMT systemd service'||{ fail 'TeleMT systemd service';((f++))||true; }
  systemctl is-active --quiet "$STATSSVC"&&ok 'Statistics collector'||{ fail 'Statistics collector';((f++))||true; }
  api /v1/health/ready 3 >/dev/null&&ok 'TeleMT API ready'||{ fail 'TeleMT API not ready';((f++))||true; }
  ss -H -ltn "sport = :$PORT"|grep -q .&&ok "TCP port $PORT listening"||{ fail "TCP $PORT not listening";((f++))||true; }
  ss -H -ltn "sport = :9090"|grep -q '127.0.0.1'&&ok 'Metrics bound to loopback'||{ warn 'Metrics bind should be checked';((w++))||true; }
  ss -H -ltn "sport = :9091"|grep -q '127.0.0.1'&&ok 'Admin API bound to loopback'||{ warn 'API bind should be checked';((w++))||true; }
  dns=$(getent ahostsv4 "$PUBLIC_HOST" 2>/dev/null|awk '{print $1}'|sort -u|paste -sd, -); echo ",$dns,"|grep -q ",$PUBLIC_IP,"&&ok "DNS A $PUBLIC_HOST -> $PUBLIC_IP"||{ warn "DNS: ${dns:-unresolved}, expected $PUBLIC_IP";((w++))||true; }
  [[ "$RAW_SECRET" =~ ^[0-9a-f]{32}$ ]]&&ok 'Protected migration secret format'||{ fail 'Secret format';((f++))||true; }
  if [[ -n "${AD_TAG:-}" ]]; then metric_text|grep -q '^telemt_me_'&&ok 'MiddleProxy metrics present'||{ warn 'MiddleProxy metrics absent';((w++))||true; }; fi
  [[ -f "$DB" ]] && [[ "$(sqlite3 "$DB" 'PRAGMA integrity_check;' 2>/dev/null)" == ok ]]&&ok 'Statistics DB integrity'||{ fail 'Statistics DB integrity';((f++))||true; }
  hb=$(dbq "SELECT value FROM collector_meta WHERE key='heartbeat';"); now=$(date +%s); age=$((now-${hb:-0})); ((age<30))&&ok "Collector heartbeat ${age}s"||{ warn "Collector heartbeat stale: ${age}s";((w++))||true; }
  as_mtpadmin test -x /var/lib/mtpadmin/telemt&&ok 'TeleMT working directory permissions'||{ fail 'Working directory permissions';((f++))||true; }
  as_mtpadmin test -r "$CFG"&&ok 'TeleMT config readable'||{ fail 'Config permissions';((f++))||true; }
  if [[ -x /usr/local/lib/mtpadmin/scanner_guard.py ]]; then
    systemctl is-active --quiet mtpadmin-scanner.service&&ok 'Scanner Guard service'||{ fail 'Scanner Guard service';((f++))||true; }
    nft list table inet mtpadmin_guard >/dev/null 2>&1&&ok 'Scanner Guard nftables table'||{ fail 'Scanner Guard nftables table';((f++))||true; }
    ghb=$(dbq "SELECT value FROM scanner_meta WHERE key='heartbeat';"); gage=$((now-${ghb:-0})); ((gage<40))&&ok "Scanner Guard heartbeat ${gage}s"||{ warn "Scanner Guard heartbeat stale: ${gage}s";((w++))||true; }
    [[ "$(dbq "SELECT value FROM scanner_meta WHERE key='autoban';")" != 1 ]]&&ok 'Scanner Guard autoban disabled'||{ warn 'Scanner Guard autoban is enabled';((w++))||true; }
  else warn 'Scanner Guard not installed'; ((w++))||true; fi
  if [[ -f /etc/mtpadmin/web-runtime.env ]]; then
    webp=$(awk -F= '/^WEB_ACTIVE_PORT=/{gsub(/[\x27\x22]/,"",$2);print $2}' /etc/mtpadmin/web-runtime.env | tail -1)
    websvc=$(awk -F= '/^WEB_ACTIVE_SERVICE=/{gsub(/[\x27\x22]/,"",$2);print $2}' /etc/mtpadmin/web-runtime.env | tail -1)
    if [[ "$webp" =~ ^(9199|9200)$ && -n "$websvc" ]]; then
      systemctl is-active --quiet "$websvc"&&ok "Web active slot $webp"||{ fail "Web service $websvc";((f++))||true; }
      curl -fsS --max-time 4 -H 'X-MTPADMIN-User: doctor-health' "http://127.0.0.1:$webp/healthz" >/dev/null&&ok 'Web backend health'||{ fail 'Web backend health';((f++))||true; }
    else fail 'Web runtime state'; ((f++))||true; fi
  fi
  if [[ "${WEBPROXY_ENABLED:-0}" == 1 ]]; then
    if [[ "${WEBPROXY_READY:-0}" != 1 ]]; then
      warn 'Telegram WEB Proxy provisioning incomplete; updater may safely resume it'; ((w++))||true
    else
      systemctl is-active --quiet tproxy-server.service&&ok 'Telegram WEB Proxy relay'||{ fail 'Telegram WEB Proxy relay';((f++))||true; }
      curl -fsS --max-time 4 http://127.0.0.1:8081/readyz >/dev/null&&ok 'WEB Proxy relay ready'||{ fail 'WEB Proxy relay ready';((f++))||true; }
      ss -H -ltn 'sport = :8080'|grep -q '127.0.0.1'&&ok 'WEB Proxy relay bound to loopback'||{ fail 'WEB Proxy relay bind';((f++))||true; }
      wp_host=${WEBPROXY_HOST:-}
      if [[ -n "$wp_host" && -f /etc/caddy/Caddyfile ]] && grep -Fq "$wp_host" /etc/caddy/Caddyfile; then ok "WEB Proxy Caddy host $wp_host"; else fail 'WEB Proxy Caddy host'; ((f++))||true; fi
      wpdns=$(getent ahostsv4 "$wp_host" 2>/dev/null|awk '{print $1}'|sort -u|paste -sd, -)
      if echo ",$wpdns,"|grep -q ",$PUBLIC_IP,"; then ok "DNS A $wp_host -> $PUBLIC_IP"; else warn "WEB Proxy DNS: ${wpdns:-unresolved}, expected $PUBLIC_IP"; ((w++))||true; fi
    fi
  fi
  rss=$(ps -C telemt -o rss=|awk '{s+=$1}END{print s+0}'); ((rss<262144))&&ok "TeleMT RSS $(fmt_bytes $((rss*1024)))"||{ warn "High TeleMT RSS $(fmt_bytes $((rss*1024)))";((w++))||true; }
  avail=$(awk '/MemAvailable:/{print $2}' /proc/meminfo); ((avail>131072))&&ok "RAM available $(fmt_bytes $((avail*1024)))"||{ warn "Low available RAM $(fmt_bytes $((avail*1024)))";((w++))||true; }
  psisome=$(psi_avg10 some); psifull=$(psi_avg10 full); psisome=${psisome:-0}; psifull=${psifull:-0}
  if awk -v s="$psisome" -v f="$psifull" 'BEGIN{exit !(s<10 && f<2)}'; then ok "Memory PSI healthy (some avg10=${psisome}%, full=${psifull}%)"; else warn "Memory pressure PSI elevated (some avg10=${psisome}%, full=${psifull}%)"; ((w++))||true; fi
  swaptotal=$(free -b | awk '/Swap:/{print $2}'); swapused=$(free -b | awk '/Swap:/{print $3}'); swaptotal=${swaptotal:-0}; swapused=${swapused:-0}; swappct=0
  if (( swaptotal > 0 )); then swappct=$((swapused*100/swaptotal)); fi
  if (( swaptotal > 0 && swappct > 90 && avail < 131072 )) || ! awk -v s="$psisome" 'BEGIN{exit !(s<20)}'; then warn "Swap occupancy ${swappct}% ($(fmt_bytes "$swapused") used) with active memory pressure"; ((w++))||true; else ok "Swap occupancy ${swappct}% ($(fmt_bytes "$swapused") used); active pressure low"; fi
  df -Pk /|awk 'NR==2{exit !($4>524288)}'&&ok 'Disk free >512 MB'||{ warn 'Low disk space';((w++))||true; }
  echo; if ((f==0)); then echo -e "RESULT: ${GREEN}HEALTHY${NC}  warnings=$w"; else echo -e "RESULT: ${RED}FAILED${NC} failures=$f warnings=$w"; return 1; fi
}
