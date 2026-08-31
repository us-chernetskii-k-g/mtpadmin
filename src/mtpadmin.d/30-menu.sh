geo_rebuild_cmd(){
  header
  echo
  echo 'Переопределяю географию и ASN для всех сохранённых полных IP...'
  systemctl restart "$STATSSVC"
  sleep 6
  systemctl is-active --quiet "$STATSSVC" || { fail 'Collector не запустился'; return 1; }
  local ts
  ts=$(dbq "SELECT value FROM collector_meta WHERE key='geo_reenriched_at';")
  [[ -n "$ts" ]] && ok "Переобогащение выполнено: $(date -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$ts")"
  echo
  geo_cmd today
}

geo_update_cmd(){
  [[ -x /usr/local/lib/mtpadmin/geo_update.sh ]] || { fail 'Модуль обновления геобазы не найден'; return 1; }
  /usr/local/lib/mtpadmin/geo_update.sh
  systemctl restart "$STATSSVC"
  sleep 4
  ok 'Геобаза обновлена, collector перезапущен'
}

geo_setup_cmd(){
  header
  echo
  echo 'Будут установлены локальные базы DB-IP Lite:'
  echo '  • City — страна / регион / город (~124 МБ)'
  echo '  • ASN  — оператор сети / ASN (~10 МБ)'
  echo 'IP клиентов не отправляются в DB-IP; наружу скачиваются только файлы баз.'
  echo
  local yn
  read -r -p 'Установить/обновить геобазы сейчас? [Y/n]: ' yn || true
  [[ -z "$yn" || "$yn" =~ ^[YyДд]$ ]] || return 0

  if ! python3 -c 'import maxminddb' >/dev/null 2>&1; then
    echo 'Устанавливаю небольшой пакет python3-maxminddb из репозитория Ubuntu...'
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3-maxminddb || {
      fail 'Не удалось установить python3-maxminddb'
      return 1
    }
  fi

  geo_update_cmd || return 1

  read -r -p 'Включить автоматическое обновление геобаз раз в месяц? [Y/n]: ' yn || true
  if [[ -z "$yn" || "$yn" =~ ^[YyДд]$ ]]; then
    systemctl enable --now mtpadmin-geo-update.timer
    ok 'Ежемесячное автообновление включено'
  fi

  echo
  geo_status_cmd
}

dashboard_cmd(){
  ( trap 'echo; exit 0' INT TERM
    while true; do clear||true; status_cmd; echo; echo -e "${BOLD}Страны сегодня${NC}"; dbq "SELECT printf('%-3s %-24s %5d',country_code,substr(country_name,1,24),count(DISTINCT ip_hash)) FROM anon_visits WHERE day=date('now','localtime') GROUP BY country_code,country_name ORDER BY count(DISTINCT ip_hash) DESC LIMIT 6;"; echo; echo -e "${BOLD}Активные источники${NC}"; current_users_json|jq -r '.data[]?|select((.current_connections//0)>0)|[.username,.current_connections,.active_unique_ips]|@tsv'|awk 'BEGIN{print "SOURCE\tCONNS\tIPS"}{print}'|column -t; echo; echo -e "${DIM}Обновление 3 сек · Ctrl+C — выход${NC}"; sleep 3; done
  )
}

menu(){
  while true; do clear||true; status_cmd; cat <<'EOF'

 [1] Живой монитор
 [2] Статистика по периодам
 [3] История трафика
 [4] Клиенты / история IP
 [5] География / города / провайдеры
 [6] Источники / секреты
 [7] Ссылки / QR
 [8] Реклама
 [9] Безопасность
[10] Ресурсы сервера
[11] Логи
[12] Диагностика
[13] Настройки
[14] Резервная копия
[15] Обновить TeleMT
[16] Обслуживание / очистка
[17] Настройка геобазы
 [0] Выход
EOF
    read -r -p '> ' n||exit 0; case "$n" in
      1) dashboard_cmd;;2) read -r -p 'Период [today/yesterday/7d/30d/all]: ' p; stats_cmd "${p:-today}";;3) read -r -p 'Период [today/yesterday/7d/30d/all]: ' p; traffic_cmd "${p:-7d}";;4) clear; ips_cmd;;5) read -r -p 'Период [today/yesterday/7d/30d/all]: ' p; geo_cmd "${p:-today}";;6) sources_menu;;7) clear; links_cmd;;8) clear; advertising_cmd;;9) clear; security_cmd;;10) clear; resources_cmd;;11) clear; logs_cmd 150;;12) clear; doctor_cmd||true;;13) settings_cmd;;14) echo "Backup: $(backup_cmd)";;15) update_cmd;;16) purge_cmd;;17) clear; geo_setup_cmd;;0) exit 0;;*)continue;;esac
    echo; read -r -p 'Нажмите Enter...' _||true
  done
}

cmd="${1:-menu}"; shift || true
case "$cmd" in
  menu) menu;; status) status_cmd;; dashboard|live) dashboard_cmd;; stats) stats_cmd "${1:-today}";; traffic) traffic_cmd "${1:-7d}";; ips|clients) ips_cmd;; api-ips|online) api_ips_cmd;; geo) geo_cmd "${1:-today}";; geo-rebuild) geo_rebuild_cmd;; geo-setup) geo_setup_cmd;; geo-update) geo_update_cmd;; geo-status) geo_status_cmd;; sources) sources_cmd;; source-add) source_add_cmd "${1:-}";; source-edit) source_edit_cmd "${1:-}";; source-disable) source_disable_cmd "${1:-}";; source-enable) source_enable_cmd "${1:-}";; source-rotate) source_rotate_cmd "${1:-}";; source-delete) source_delete_cmd "${1:-}";; source-links) source_links_cmd "${1:-$PROFILE}";; links) links_cmd "${1:-}";; qr) qr_cmd "${1:-$PROFILE}" "${2:-tls}";; advertising|ads) advertising_cmd;; security) security_cmd;; resources) resources_cmd;; logs) logs_cmd "${1:-120}";; logs-live|follow) logs_live_cmd;; doctor) doctor_cmd;; restart) restart_cmd;; start) systemctl start "$SERVICE" "$STATSSVC";; stop) systemctl stop "$STATSSVC" "$SERVICE";; settings) settings_cmd;; backup) backup_cmd;; update) update_cmd;; purge) purge_cmd;; config) cat "$CFG";; version) echo "${MTPADMIN_VERSION:-0.4.4}";; *) echo 'Usage: mtpadmin [status|dashboard|stats PERIOD|traffic PERIOD|ips|api-ips|geo PERIOD|geo-rebuild|geo-setup|geo-update|geo-status|sources|source-add|source-edit|source-disable|source-enable|source-rotate|source-delete|source-links|links|qr|advertising|security|resources|logs|doctor|restart|settings|backup|update|purge]'; exit 2;; esac
