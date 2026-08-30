# MTPADMIN 0.11.8 source lifecycle overrides.
# Loaded after 10-sources.sh so later function definitions replace legacy hot-reload-only behavior.

source_runtime_match(){
  local name="$1"
  python3 - "$CFG" "$API" "$name" <<'PY'
import json,re,sys,tomllib,urllib.parse,urllib.request
cfg,api,name=sys.argv[1:]
with open(cfg,'rb') as f: d=tomllib.load(f)
a=d.get('access') or {}; users=a.get('users') or {}; en=a.get('user_enabled') or {}; tags=a.get('user_ad_tags') or {}; mc=a.get('user_max_tcp_conns') or {}; mi=a.get('user_max_unique_ips') or {}
try:
    with urllib.request.urlopen(api+'/v1/users',timeout=4) as r: payload=json.loads(r.read())
    rows={str(x.get('username')):x for x in (payload.get('data') or []) if x.get('username')}
except Exception:
    raise SystemExit(1)
if name not in users:
    raise SystemExit(0 if name not in rows else 1)
if name not in rows: raise SystemExit(1)
r=rows[name]
if bool(r.get('enabled',True)) != bool(en.get(name,True)): raise SystemExit(1)
for key,m in (('max_tcp_conns',mc),('max_unique_ips',mi)):
    cv=m.get(name); rv=r.get(key)
    if cv is not None: cv=int(cv)
    if rv is not None: rv=int(rv)
    if cv!=rv: raise SystemExit(1)
if str(tags.get(name) or '').lower()!=str(r.get('user_ad_tag') or '').lower(): raise SystemExit(1)
secret=str(users.get(name) or '').lower(); actual=''
for link in (r.get('links') or {}).get('classic') or []:
    q=urllib.parse.parse_qs(urllib.parse.urlsplit(str(link)).query); actual=(q.get('secret') or [''])[0].lower()
    if re.fullmatch(r'[0-9a-f]{32}',actual): break
if secret and actual and secret!=actual: raise SystemExit(1)
PY
}

source_wait_ready(){
  local i
  for i in {1..30}; do
    systemctl is-active --quiet "$SERVICE" && curl -fsS --max-time 2 "$API/v1/health/ready" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

source_full_restart(){
  systemctl restart "$SERVICE" || return 1
  source_wait_ready
}

source_apply_or_restart(){
  local name="$1"
  reload_disk_config >/dev/null 2>&1 || true
  if source_wait_ready && source_runtime_match "$name"; then
    ok 'Конфигурация подтверждена TeleMT runtime'
    return 0
  fi
  warn 'Hot reload не подтвердил изменение; выполняю короткий restart TeleMT'
  source_full_restart || return 1
  if source_runtime_match "$name"; then
    systemctl restart mtpadmin-scanner.service >/dev/null 2>&1 || true
    ok 'Конфигурация применена после restart и подтверждена runtime'
    return 0
  fi
  return 1
}

mutate_source(){
  local name="${2:-}" backup
  [[ -n "$name" ]] || { fail 'Не указано имя источника'; return 2; }
  backup=$(source_backup)
  if ! "$USERCFG" "$@"; then cp -a "$backup" "$CFG"; fail 'Config edit failed'; return 1; fi
  if source_apply_or_restart "$name"; then return 0; fi
  fail 'TeleMT не подтвердил изменение; восстанавливаю предыдущий config'
  cp -a "$backup" "$CFG"
  source_full_restart >/dev/null 2>&1 || true
  systemctl restart mtpadmin-scanner.service >/dev/null 2>&1 || true
  return 1
}

source_add_cmd(){
  local name="${1:-}" ad maxc maxi secret backup
  [[ -n "$name" ]] || read -r -p 'Имя источника (например SITE / TG_AD_01): ' name
  read -r -p 'Отдельный ad tag [Enter = глобальный]: ' ad || true
  read -r -p 'Макс. одновременных соединений [Enter = без лимита]: ' maxc || true
  read -r -p 'Макс. уникальных IP [Enter = без лимита]: ' maxi || true
  local args=(add "$name"); [[ -n "$ad" ]] && args+=(--ad-tag "$ad"); [[ -n "$maxc" ]] && args+=(--max-conns "$maxc"); [[ -n "$maxi" ]] && args+=(--max-ips "$maxi")
  backup=$(source_backup)
  if ! secret=$("$USERCFG" "${args[@]}"); then cp -a "$backup" "$CFG"; return 1; fi
  if ! source_apply_or_restart "$name"; then
    cp -a "$backup" "$CFG"; source_full_restart >/dev/null 2>&1 || true; fail 'Источник не появился в runtime; выполнен rollback'; return 1
  fi
  ok "Источник $name создан"; echo "Secret: $secret"; source_links_cmd "$name"
}

source_rotate_cmd(){
  local n="${1:-}" c backup secret
  [[ -n "$n" ]] || { echo 'Usage: mtpadmin source-rotate NAME'; return 2; }
  echo -e "${RED}Rotating the secret immediately invalidates all old links for $n.${NC}"; read -r -p 'Введите ROTATE для продолжения: ' c; [[ "$c" == ROTATE ]] || return 0
  backup=$(source_backup); secret=$("$USERCFG" rotate "$n") || { cp -a "$backup" "$CFG"; return 1; }
  if source_apply_or_restart "$n"; then ok 'Secret успешно изменён'; echo "New secret: $secret"; source_links_cmd "$n"; return 0; fi
  cp -a "$backup" "$CFG"; source_full_restart >/dev/null 2>&1 || true; fail 'Runtime не подтвердил новый secret; старый config восстановлен'; return 1
}

source_edit_cmd(){
  local n="${1:-}" ad maxc maxi
  [[ -n "$n" ]] || read -r -p 'Источник: ' n
  [[ -n "$n" ]] || { fail 'Не указано имя источника'; return 2; }
  echo 'Пустое значение снимает индивидуальную настройку и возвращает глобальное/безлимитное значение.'
  read -r -p 'Ad tag [пусто = глобальный]: ' ad || true
  read -r -p 'Макс. соединений [пусто = без лимита]: ' maxc || true
  read -r -p 'Макс. уникальных IP [пусто = без лимита]: ' maxi || true
  mutate_source edit "$n" --ad-tag "${ad:-none}" --max-conns "${maxc:-none}" --max-ips "${maxi:-none}"
}

sources_menu(){
  while true; do clear || true; sources_cmd; cat <<'EOF'

 [1] Добавить источник / secret
 [2] Показать ссылки источника
 [3] Отключить источник
 [4] Включить источник
 [5] Сменить secret источника
 [6] Удалить источник
 [7] Изменить ad tag / лимиты
 [0] Назад
EOF
    read -r -p '> ' n || return
    case "$n" in
      1) source_add_cmd;;2) read -r -p 'Источник: ' x; source_links_cmd "$x";;3) read -r -p 'Источник: ' x; source_disable_cmd "$x";;4) read -r -p 'Источник: ' x; source_enable_cmd "$x";;5) read -r -p 'Источник: ' x; source_rotate_cmd "$x";;6) read -r -p 'Источник: ' x; source_delete_cmd "$x";;7) read -r -p 'Источник: ' x; source_edit_cmd "$x";;0) return;;esac
    echo; read -r -p 'Нажмите Enter...' _ || true
  done
}
