  period_resolve "${1:-today}" || return
  header
  [[ -f "$DB" ]] || return
  echo
  echo -e "${BOLD}География — ${PERIOD_LABEL}${NC}"

  echo
  echo 'Страны:'
  sqlite3 -column -header "$DB" "SELECT country_code AS код, substr(country_name,1,30) AS страна, count(DISTINCT ip_hash) AS уникальных, sum(observations) AS сеансов FROM anon_visits WHERE day BETWEEN '$START_DAY' AND '$END_DAY' GROUP BY country_code,country_name ORDER BY уникальных DESC,сеансов DESC LIMIT 30;" || true

  echo
  echo 'Города:'
  local cities
  cities=$(dbq "SELECT count(*) FROM anon_visits WHERE day BETWEEN '$START_DAY' AND '$END_DAY' AND coalesce(city,'')!='';")
  if (( ${cities:-0} > 0 )); then
    sqlite3 -column -header "$DB" "SELECT substr(coalesce(city,'—'),1,28) AS город, substr(coalesce(region,''),1,24) AS регион, country_code AS код, count(DISTINCT ip_hash) AS уникальных, sum(observations) AS сеансов FROM anon_visits WHERE day BETWEEN '$START_DAY' AND '$END_DAY' AND coalesce(city,'')!='' GROUP BY country_code,region,city ORDER BY уникальных DESC,сеансов DESC LIMIT 40;"
  else
    echo '  Городская MMDB-база пока не установлена. Запустите: mtpadmin geo-setup'
  fi

  echo
  echo 'Провайдеры / сети (ASN):'
  local rows
  rows=$(dbq "SELECT count(*) FROM anon_visits WHERE day BETWEEN '$START_DAY' AND '$END_DAY' AND coalesce(asn,'')!='';")
  if (( ${rows:-0} > 0 )); then
    sqlite3 -column -header "$DB" "SELECT asn AS ASN, substr(org,1,42) AS провайдер_сеть, count(DISTINCT ip_hash) AS уникальных, sum(observations) AS сеансов FROM anon_visits WHERE day BETWEEN '$START_DAY' AND '$END_DAY' AND coalesce(asn,'')!='' GROUP BY asn,org ORDER BY уникальных DESC,сеансов DESC LIMIT 40;"
  else
    echo '  ASN-база пока не установлена. Запустите: mtpadmin geo-setup'
  fi

  if [[ -f /var/lib/mtpadmin/geo/dbip-city-lite.mmdb || -f /var/lib/mtpadmin/geo/dbip-asn-lite.mmdb ]]; then
    echo
    echo -e "${DIM}Геоданные: DB-IP Lite, CC BY 4.0 · город определяется приблизительно по IP.${NC}"
  fi
}

sources_cmd(){
  header; echo; local j; j=$(current_users_json)
  printf '%s' "$j" | jq -r '.data[]? | [.username,(if .enabled then "ON" else "OFF" end),(.current_connections//0),(.active_unique_ips//0),(.total_octets//0),(.max_tcp_conns//"-"),(.max_unique_ips//"-"),(if .user_ad_tag then "own" else "global" end)]|@tsv' | awk 'BEGIN{print "ИСТОЧНИК\tСТАТУС\tСОЕД\tIP\tБАЙТЫ\tМАКС_СОЕД\tМАКС_IP\tADTAG"}{print}' | column -t
}

source_backup(){ local out="/var/backups/mtpadmin/config-before-source-$(date +%Y%m%d-%H%M%S).toml"; cp -a "$CFG" "$out"; echo "$out"; }
reload_disk_config(){
  local body id state i; body=$(curl -fsS --max-time 8 -X POST -H 'Content-Type: application/json' -d '{"mode":"instant","failure_policy":"rollback"}' "$API/v1/system/reload" 2>/dev/null) || return 1
  id=$(printf '%s' "$body" | jq -r '.data.reload_id // empty'); [[ -n "$id" ]] || { echo "$body" >&2; return 1; }
  for i in {1..30}; do
    state=$(api "/v1/system/reload/$id" 3 | jq -r '.data.state // empty' 2>/dev/null || true)
    case "$state" in succeeded) return 0;; failed|rolled_back) return 1;; esac
    sleep 0.25
  done
  return 1
}
mutate_source(){
  local backup; backup=$(source_backup)
  if ! "$USERCFG" "$@"; then cp -a "$backup" "$CFG"; fail 'Config edit failed'; return 1; fi
  if reload_disk_config; then ok 'Конфигурация применена без перезапуска'; return 0; fi
  fail 'Ошибка применения; восстанавливаю предыдущий конфиг'; cp -a "$backup" "$CFG"; reload_disk_config >/dev/null 2>&1 || systemctl restart "$SERVICE"; return 1
}
source_add_cmd(){
  local name="${1:-}" ad maxc maxi secret
  [[ -n "$name" ]] || read -r -p 'Имя источника (например SITE / TG_AD_01): ' name
  read -r -p 'Отдельный ad tag [Enter = глобальный]: ' ad || true
  read -r -p 'Макс. одновременных соединений [Enter = без лимита]: ' maxc || true
  read -r -p 'Макс. уникальных IP [Enter = без лимита]: ' maxi || true
  local args=(add "$name"); [[ -n "$ad" ]] && args+=(--ad-tag "$ad"); [[ -n "$maxc" ]] && args+=(--max-conns "$maxc"); [[ -n "$maxi" ]] && args+=(--max-ips "$maxi")
  local backup; backup=$(source_backup)
  if ! secret=$("$USERCFG" "${args[@]}"); then cp -a "$backup" "$CFG"; return 1; fi
  if ! reload_disk_config; then cp -a "$backup" "$CFG"; reload_disk_config >/dev/null 2>&1 || true; fail 'Reload failed; rolled back'; return 1; fi
  ok "Источник $name создан"; echo "Secret: $secret"; source_links_cmd "$name"
}
source_disable_cmd(){ [[ -n "${1:-}" ]] || { echo 'Usage: mtpadmin source-disable NAME'; return 2; }; mutate_source disable "$1"; }
source_enable_cmd(){ [[ -n "${1:-}" ]] || { echo 'Usage: mtpadmin source-enable NAME'; return 2; }; mutate_source enable "$1"; }
source_rotate_cmd(){
  local n="${1:-}" c backup secret; [[ -n "$n" ]] || { echo 'Usage: mtpadmin source-rotate NAME'; return 2; }
  echo -e "${RED}Rotating the secret immediately invalidates all old links for $n.${NC}"; read -r -p 'Введите ROTATE для продолжения: ' c; [[ "$c" == ROTATE ]] || return 0
  backup=$(source_backup); secret=$("$USERCFG" rotate "$n") || { cp -a "$backup" "$CFG"; return 1; }
  if reload_disk_config; then ok 'Secret успешно изменён'; echo "New secret: $secret"; source_links_cmd "$n"; else cp -a "$backup" "$CFG"; reload_disk_config >/dev/null 2>&1 || true; fail 'Ошибка применения; старый secret восстановлен'; return 1; fi
}
source_delete_cmd(){
  local n="${1:-}" c; [[ -n "$n" ]] || { echo 'Usage: mtpadmin source-delete NAME'; return 2; }; [[ "$n" != "$PROFILE" ]] || { fail "Нельзя удалить защищённый основной профиль $PROFILE"; return 1; }
  read -r -p "Введите имя источника '$n' для окончательного удаления: " c; [[ "$c" == "$n" ]] || return 0; mutate_source delete "$n"
}
source_links_cmd(){
  local n="${1:-$PROFILE}" j; j=$(current_users_json); header; echo; echo "Ссылки источника: $n"
  printf '%s' "$j" | jq -r --arg n "$n" '.data[]?|select(.username==$n)|"state: \(if .enabled then "enabled" else "disabled" end)",(.links.classic[]?|"classic: \(.)"),(.links.secure[]?|"secure:  \(.)"),(.links.tls[]?|"FakeTLS: \(.)")'
  if [[ "$n" == "$PROFILE" ]]; then echo; echo 'Сохранённая историческая ссылка:'; echo "https://t.me/proxy?server=${PUBLIC_HOST}&port=${PORT}&secret=${LEGACY_SECRET}"; fi
}
sources_menu(){
  while true; do clear || true; sources_cmd; cat <<'EOF'

 [1] Добавить источник / secret
 [2] Показать ссылки источника
 [3] Отключить источник
 [4] Включить источник
 [5] Сменить secret источника
 [6] Удалить источник
 [0] Назад
EOF
    read -r -p '> ' n || return
    case "$n" in 1) source_add_cmd;;2) read -r -p 'Источник: ' x; source_links_cmd "$x";;3) read -r -p 'Источник: ' x; source_disable_cmd "$x";;4) read -r -p 'Источник: ' x; source_enable_cmd "$x";;5) read -r -p 'Источник: ' x; source_rotate_cmd "$x";;6) read -r -p 'Источник: ' x; source_delete_cmd "$x";;0) return;;esac
    echo; read -r -p 'Нажмите Enter...' _ || true
  done
}

links_cmd(){
  local filter="${1:-}"; header; echo; local j; j=$(current_users_json)
  if [[ -n "$filter" ]]; then source_links_cmd "$filter"; return; fi
  printf '%s' "$j" | jq -r '.data[]?|"[\(.username)] \(if .enabled then "ENABLED" else "DISABLED" end)",(.links.classic[]?|" classic  \(.)"),(.links.secure[]?|" secure   \(.)"),(.links.tls[]?|" FakeTLS  \(.)"),""'
  echo "Рекламируемый канал: $PROMOTED_CHANNEL"
}
qr_cmd(){
  local n="${1:-$PROFILE}" mode="${2:-tls}" link
  command -v qrencode >/dev/null 2>&1 || { warn 'qrencode не установлен. При желании: apt install qrencode'; return 1; }
  link=$(current_users_json | jq -r --arg n "$n" --arg m "$mode" '.data[]?|select(.username==$n)|.links[$m][0]//empty')
  [[ -n "$link" ]] || { fail "Нет ссылки режима $mode для $n"; return 1; }; echo "$link"; qrencode -t ANSIUTF8 "$link"
}

advertising_cmd(){
  header; echo
  printf 'Глобальный ad tag:       %s\n' "${AD_TAG:-disabled}"
