# Runtime-safe doctor helpers for MTPADMIN 0.7.0.
# The web panel runs with NoNewPrivileges=true, so sudo cannot be used there
# merely to drop privileges. runuser works without granting new privileges.
as_mtpadmin(){
  if command -v runuser >/dev/null 2>&1; then
    runuser -u mtpadmin -- "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -u mtpadmin "$@"
  else
    return 127
  fi
}

doctor_cmd(){
  reload_state; header; echo; local f=0 w=0 dns hb now age rss avail swapused swaptotal ghb gage webp websvc
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
  else
    warn 'Scanner Guard not installed'; ((w++))||true
  fi
  if [[ -f /etc/mtpadmin/web-runtime.env ]]; then
    webp=$(awk -F= '/^WEB_ACTIVE_PORT=/{gsub(/[\x27\x22]/,"",$2);print $2}' /etc/mtpadmin/web-runtime.env | tail -1)
    websvc=$(awk -F= '/^WEB_ACTIVE_SERVICE=/{gsub(/[\x27\x22]/,"",$2);print $2}' /etc/mtpadmin/web-runtime.env | tail -1)
    if [[ "$webp" =~ ^(9199|9200)$ && -n "$websvc" ]]; then
      systemctl is-active --quiet "$websvc"&&ok "Web active slot $webp"||{ fail "Web service $websvc";((f++))||true; }
      curl -fsS --max-time 4 -H 'X-MTPADMIN-User: doctor-health' "http://127.0.0.1:$webp/healthz" >/dev/null&&ok 'Web backend health'||{ fail 'Web backend health';((f++))||true; }
    else
      fail 'Web runtime state'; ((f++))||true
    fi
  fi
  rss=$(ps -C telemt -o rss=|awk '{s+=$1}END{print s+0}'); ((rss<262144))&&ok "TeleMT RSS $(fmt_bytes $((rss*1024)))"||{ warn "High TeleMT RSS $(fmt_bytes $((rss*1024)))";((w++))||true; }
  avail=$(awk '/MemAvailable:/{print $2}' /proc/meminfo); ((avail>131072))&&ok "RAM available $(fmt_bytes $((avail*1024)))"||{ warn "Low available RAM $(fmt_bytes $((avail*1024)))";((w++))||true; }
  swaptotal=$(free -b | awk '/Swap:/{print $2}'); swapused=$(free -b | awk '/Swap:/{print $3}'); swaptotal=${swaptotal:-0}; swapused=${swapused:-0}; if (( swaptotal > 0 && swapused * 100 / swaptotal > 90 )); then warn "Swap >90% used ($(fmt_bytes "$swapused"))"; ((w++))||true; else ok "Swap pressure acceptable ($(fmt_bytes "$swapused") used)"; fi
  df -Pk /|awk 'NR==2{exit !($4>524288)}'&&ok 'Disk free >512 MB'||{ warn 'Low disk space';((w++))||true; }
  echo; if ((f==0)); then echo -e "RESULT: ${GREEN}HEALTHY${NC}  warnings=$w"; else echo -e "RESULT: ${RED}FAILED${NC} failures=$f warnings=$w"; return 1; fi
}
