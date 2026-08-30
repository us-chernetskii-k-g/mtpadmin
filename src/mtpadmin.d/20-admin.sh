  printf 'Рекламируемый канал:    %s\n' "$PROMOTED_CHANNEL"
  printf 'Режим MiddleProxy:    %s\n' "$(grep -Eq '^use_middle_proxy\s*=\s*true' "$CFG" && echo enabled || echo disabled)"
  printf 'Активные ME writers:   %s\n' "$(metric telemt_me_writers_active_current)"
  printf 'Ошибки ME handshake:%s\n' " $(metric telemt_me_handshake_reject_total)"
  echo; echo 'Отдельные ad tag по источникам:'
  current_users_json | jq -r '.data[]?|[.username,(.user_ad_tag//"global")]|@tsv' | column -t
  echo; echo -e "${DIM}Фактический показ рекламного канала проверяется в клиенте Telegram.${NC}"
}

security_cmd(){
  header; echo
  echo 'Слушающие порты:'; ss -lntp | grep -E ':8443|:9090|:9091' || true
  echo; echo "Ошибок/отклонено за время процесса: $(metric telemt_connections_bad_total)"
  echo 'Лимиты источников:'
  current_users_json | jq -r '.data[]?|[.username,(if .enabled then "ON" else "OFF" end),(.max_tcp_conns//"unlimited"),(.max_unique_ips//"unlimited"),(.data_quota_bytes//"unlimited")]|@tsv' | awk 'BEGIN{print "SOURCE\tSTATE\tMAX_CONNS\tMAX_IPS\tQUOTA"}{print}' | column -t
  if systemctl is-active --quiet fail2ban 2>/dev/null; then echo; echo 'Fail2ban:'; fail2ban-client status 2>/dev/null | head -20 || true; fi
  echo; printf 'Права на конфиг: '; stat -c '%A %U:%G %n' "$CFG"
}

resources_cmd(){ header; echo; ps -o pid,user,%cpu,%mem,rss,vsz,etime,cmd -C telemt; echo; free -h; echo; uptime; echo; df -h /; }
logs_cmd(){ journalctl -u "$SERVICE" -n "${1:-120}" --no-pager; }
logs_live_cmd(){ journalctl -u "$SERVICE" -f; }

backup_cmd(){
  local ts out; ts=$(date +%Y%m%d-%H%M%S); out="/var/backups/mtpadmin/mtpadmin-${ts}.tar.gz"
  tar -czf "$out" /etc/mtpadmin /var/lib/mtpadmin /usr/local/bin/mtpadmin /usr/local/bin/telemt /usr/local/lib/mtpadmin /etc/systemd/system/mtpadmin-telemt.service /etc/systemd/system/mtpadmin-stats.service 2>/dev/null
  chmod 600 "$out"; echo "$out"
}

set_state_value(){
  local key="$1" value="$2" tmp; tmp=$(mktemp)
  awk -v k="$key" -v v="$value" 'BEGIN{d=0}$0~"^"k"="{print k"=\047"v"\047";d=1;next}{print}END{if(!d)print k"=\047"v"\047"}' "$STATE" > "$tmp"; install -m 600 "$tmp" "$STATE"; rm -f "$tmp"; reload_state
}
settings_cmd(){
  while true; do reload_state; clear||true; header; cat <<EOF

 [1] Публичный домен        $PUBLIC_HOST
 [2] Порт                  $PORT
 [3] Fake-TLS домен        $FAKE_TLS_DOMAIN
 [4] Глобальный ad tag     ${AD_TAG:-disabled}
 [5] Полные IP             $RETENTION_DAYS дней
 [6] Обезличенная история  ${ANON_RETENTION_DAYS:-400} дней
 [7] Публичный/NAT IPv4    $PUBLIC_IP
 [0] Назад
EOF
    read -r -p '> ' n || return; case "$n" in
      1) read -r -p 'Новый публичный домен: ' v; [[ "$v" =~ ^[A-Za-z0-9.-]+$ ]] && set_state_value PUBLIC_HOST "$v";;
      2) read -r -p 'Новый порт: ' v; [[ "$v" =~ ^[0-9]+$ ]]&&((v>=1&&v<=65535))&&set_state_value PORT "$v";;
      3) read -r -p 'Новый Fake-TLS домен: ' v; [[ "$v" =~ ^[A-Za-z0-9.-]+$ ]]&&set_state_value FAKE_TLS_DOMAIN "$v";;
      4) read -r -p 'Новый глобальный ad tag 32 hex [Enter = отключить]: ' v; [[ -z "$v"||"$v" =~ ^[0-9a-fA-F]{32}$ ]]&&set_state_value AD_TAG "${v,,}";;
      5) read -r -p 'Хранить полные IP, дней 1..365: ' v; [[ "$v" =~ ^[0-9]+$ ]]&&((v>=1&&v<=365))&&set_state_value RETENTION_DAYS "$v";;
      6) read -r -p 'Хранить обезличенную историю, дней 7..3650: ' v; [[ "$v" =~ ^[0-9]+$ ]]&&((v>=7&&v<=3650))&&set_state_value ANON_RETENTION_DAYS "$v";;
      7) read -r -p 'Новый публичный IPv4: ' v; set_state_value PUBLIC_IP "$v";; 0) return;;
    esac
    /usr/local/lib/mtpadmin/render_config.sh; echo 'Saved to disk. Use Restart proxy to apply port/NAT changes; source data is preserved.'; read -r -p 'Нажмите Enter...' _||true
  done
}

restart_cmd(){ /usr/local/lib/mtpadmin/render_config.sh; systemctl restart "$SERVICE"; systemctl restart "$STATSSVC"; sleep 3; doctor_cmd; }

doctor_cmd(){
  reload_state; header; echo; local f=0 w=0 dns hb now age rss avail swapused swaptotal
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
  sudo -u mtpadmin test -x /var/lib/mtpadmin/telemt&&ok 'TeleMT working directory permissions'||{ fail 'Working directory permissions';((f++))||true; }
  sudo -u mtpadmin test -r "$CFG"&&ok 'TeleMT config readable'||{ fail 'Config permissions';((f++))||true; }
  rss=$(ps -C telemt -o rss=|awk '{s+=$1}END{print s+0}'); ((rss<262144))&&ok "TeleMT RSS $(fmt_bytes $((rss*1024)))"||{ warn "High TeleMT RSS $(fmt_bytes $((rss*1024)))";((w++))||true; }
  avail=$(awk '/MemAvailable:/{print $2}' /proc/meminfo); ((avail>131072))&&ok "RAM available $(fmt_bytes $((avail*1024)))"||{ warn "Low available RAM $(fmt_bytes $((avail*1024)))";((w++))||true; }
  swaptotal=$(free -b | awk '/Swap:/{print $2}'); swapused=$(free -b | awk '/Swap:/{print $3}'); swaptotal=${swaptotal:-0}; swapused=${swapused:-0}; if (( swaptotal > 0 && swapused * 100 / swaptotal > 90 )); then warn "Swap >90% used ($(fmt_bytes "$swapused"))"; ((w++))||true; else ok "Swap pressure acceptable ($(fmt_bytes "$swapused") used)"; fi
  df -Pk /|awk 'NR==2{exit !($4>524288)}'&&ok 'Disk free >512 MB'||{ warn 'Low disk space';((w++))||true; }
  echo; if ((f==0)); then echo -e "RESULT: ${GREEN}HEALTHY${NC}  warnings=$w"; else echo -e "RESULT: ${RED}FAILED${NC} failures=$f warnings=$w"; return 1; fi
}

update_cmd(){
  reload_state; echo 'Обновление TeleMT'; read -r -p 'Обновить TeleMT с резервной копией и проверкой? [y/N]: ' yn; [[ "$yn" =~ ^[Yy]$ ]]||return 0
  local b tmp a arch libc url bin; b="/var/backups/mtpadmin/telemt-bin-$(date +%Y%m%d-%H%M%S)"; install -m755 /usr/local/bin/telemt "$b"
  case "$(uname -m)" in x86_64|amd64)arch=x86_64;;aarch64|arm64)arch=aarch64;;*)fail 'Unsupported arch';return 1;;esac; libc=gnu; ldd --version 2>&1|grep -qi musl&&libc=musl
  url="https://github.com/telemt/telemt/releases/latest/download/telemt-${arch}-linux-${libc}.tar.gz"; tmp=$(mktemp -d); a="$tmp/a.tgz"; curl -fL --retry 3 "$url" -o "$a"; tar -xzf "$a" -C "$tmp"; bin=$(find "$tmp" -type f -name telemt|head -1); install -m755 "$bin" /usr/local/bin/telemt; rm -rf "$tmp"; systemctl restart "$SERVICE"; sleep 4
  if api /v1/health/ready 3 >/dev/null; then ok 'TeleMT update successful'; else fail 'Healthcheck failed; rollback'; install -m755 "$b" /usr/local/bin/telemt; systemctl restart "$SERVICE"; return 1; fi
}

purge_cmd(){
  reload_state; [[ -f "$DB" ]]||return 0; sqlite3 "$DB" "DELETE FROM clients WHERE last_seen<strftime('%s','now','-${RETENTION_DAYS} days'); DELETE FROM visits WHERE day<date('now','localtime','-${RETENTION_DAYS} days'); DELETE FROM user_visits WHERE day<date('now','localtime','-${RETENTION_DAYS} days'); DELETE FROM anon_visits WHERE day<date('now','localtime','-${ANON_RETENTION_DAYS:-400} days');"; echo 'Очистка по срокам хранения завершена.'
}

geo_status_cmd(){
  header
  echo
  echo 'Локальная геобаза:'
  if python3 -c 'import maxminddb' >/dev/null 2>&1; then
    ok 'Python MMDB reader установлен'
  else
    warn 'python3-maxminddb не установлен'
  fi
  for f in /var/lib/mtpadmin/geo/dbip-city-lite.mmdb /var/lib/mtpadmin/geo/dbip-asn-lite.mmdb; do
    if [[ -f "$f" ]]; then
      printf '  %-28s %8s  %s\n' "$(basename "$f")" "$(du -h "$f"|awk '{print $1}')" "$(date -r "$f" '+%Y-%m-%d %H:%M')"
    else
      printf '  %-28s %s\n' "$(basename "$f")" 'НЕ УСТАНОВЛЕНА'
    fi
  done
  local tip
  tip=$(dbq "SELECT ip FROM clients ORDER BY last_seen DESC LIMIT 1;")
  if [[ -n "$tip" && -f /var/lib/mtpadmin/geo/dbip-asn-lite.mmdb ]]; then
    echo
    echo "Проверка ASN по сохранённому IP: $tip"
    python3 - "$tip" <<'PYASN'
import sys,maxminddb
ip=sys.argv[1]
with maxminddb.open_database('/var/lib/mtpadmin/geo/dbip-asn-lite.mmdb') as r:
