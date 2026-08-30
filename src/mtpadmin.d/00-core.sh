#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
STATE=/etc/mtpadmin/state.env
DB=/var/lib/mtpadmin/stats.db
CFG=/etc/mtpadmin/config/config.toml
SERVICE=mtpadmin-telemt.service
STATSSVC=mtpadmin-stats.service
USERCFG=/usr/local/lib/mtpadmin/user_config.py
API=http://127.0.0.1:9091
METRICS=http://127.0.0.1:9090/metrics

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
ok(){ echo -e "${GREEN}PASS${NC}  $*"; }
fail(){ echo -e "${RED}FAIL${NC}  $*"; }
warn(){ echo -e "${YELLOW}WARN${NC}  $*"; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Запустите mtpadmin от root или через sudo.' >&2; exit 1; }
[[ -r "$STATE" ]] || { echo "Файл состояния MTPADMIN не найден: $STATE" >&2; exit 1; }
. "$STATE"
reload_state(){ . "$STATE"; }
header(){ echo -e "${BOLD}MTPADMIN ${MTPADMIN_VERSION:-0.4.4}${NC}  profile=${CYAN}${PROFILE}${NC}  ${PUBLIC_HOST}:${PORT}"; }
api(){ curl -fsS --max-time "${2:-4}" "$API$1" 2>/dev/null; }
metric_text(){ curl -fsS --max-time 3 "$METRICS" 2>/dev/null || true; }
metric(){ metric_text | awk -v n="$1" '$1==n{print $2; exit}'; }
metric_user(){ metric_text | awk -v p="$1" -v u="$2" 'index($1,p"{")==1 && index($1,"user=\"" u "\"")>0 {print $2; exit}'; }
fmt_bytes(){ python3 - "$1" <<'PY'
import sys
try:n=float(sys.argv[1] or 0)
except:n=0
for u in ['B','KB','MB','GB','TB','PB']:
    if n<1024 or u=='PB': print(f'{n:.1f} {u}'); break
    n/=1024
PY
}
fmt_uptime(){ python3 - "$1" <<'PY'
import sys
try:s=int(float(sys.argv[1] or 0))
except:s=0
d,r=divmod(s,86400);h,r=divmod(r,3600);m,_=divmod(r,60)
print((f'{d}d ' if d else '')+f'{h:02d}h {m:02d}m')
PY
}
fmt_epoch(){ date -d "@${1:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '-'; }
dbq(){ [[ -f "$DB" ]] && sqlite3 "$DB" "$1" 2>/dev/null || true; }

period_resolve(){
  local p="${1:-today}"; PERIOD="$p"
  case "$p" in
    today|day) START_DAY=$(date +%F); END_DAY=$START_DAY; PERIOD_LABEL='Сегодня' ;;
    yesterday|yday) START_DAY=$(date -d yesterday +%F); END_DAY=$START_DAY; PERIOD_LABEL='Вчера' ;;
    7|7d|week) START_DAY=$(date -d '6 days ago' +%F); END_DAY=$(date +%F); PERIOD_LABEL='Последние 7 дней' ;;
    30|30d|month) START_DAY=$(date -d '29 days ago' +%F); END_DAY=$(date +%F); PERIOD_LABEL='Последние 30 дней' ;;
    all) START_DAY='1970-01-01'; END_DAY='9999-12-31'; PERIOD_LABEL='Вся сохранённая история' ;;
    *)
      if [[ "$p" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then START_DAY="$p"; END_DAY="$p"; PERIOD_LABEL="$p";
      else echo 'Период: today | yesterday | 7d | 30d | all | YYYY-MM-DD' >&2; return 2; fi ;;
  esac
}

current_users_json(){ api /v1/users 4 || echo '{"ok":false,"data":[]}' ; }
current_online(){ current_users_json | jq '[.data[]? | .current_connections // 0] | add // 0'; }
current_unique(){ api /v1/stats/users/active-ips 4 | jq '[.data[]?.active_ips[]?] | unique | length' 2>/dev/null || echo 0; }
active_sources(){ current_users_json | jq '[.data[]? | select((.current_connections//0)>0)] | length'; }

status_cmd(){
  reload_state; header; echo
  local users online uniq active uptime rss ram_avail swap_used today_unique tx rx
  users=$(current_users_json); online=$(printf '%s' "$users" | jq '[.data[]?|.current_connections//0]|add//0'); active=$(printf '%s' "$users" | jq '[.data[]?|select((.current_connections//0)>0)]|length'); uniq=$(current_unique)
  uptime=$(metric telemt_uptime_seconds); rss=$(ps -C telemt -o rss= 2>/dev/null | awk '{s+=$1}END{print s+0}'); ram_avail=$(awk '/MemAvailable:/{print $2*1024}' /proc/meminfo); swap_used=$(free -b | awk '/Swap:/{print $3}')
  today_unique=$(dbq "SELECT count(DISTINCT ip_hash) FROM anon_visits WHERE day=date('now','localtime');"); today_unique=${today_unique:-0}
  rx=$(dbq "SELECT coalesce(sum(bytes_from_client),0) FROM daily_traffic WHERE day=date('now','localtime') AND username!='__GLOBAL__';"); tx=$(dbq "SELECT coalesce(sum(bytes_to_client),0) FROM daily_traffic WHERE day=date('now','localtime') AND username!='__GLOBAL__';")
  printf '  Прокси:              %b\n' "$(systemctl is-active --quiet "$SERVICE" && echo -e "${GREEN}● ONLINE${NC}" || echo -e "${RED}● OFFLINE${NC}")"
  printf '  Сейчас онлайн:         %s соединений / %s IP / %s источников\n' "$online" "$uniq" "$active"
  printf '  Уникальных сегодня:       %s\n' "$today_unique"
  printf '  Трафик сегодня:      ↑ %s   ↓ %s\n' "$(fmt_bytes "${rx:-0}")" "$(fmt_bytes "${tx:-0}")"
  printf '  Аптайм TeleMT:      %s\n' "$(fmt_uptime "${uptime:-0}")"
  printf '  Память TeleMT:         %s\n' "$(fmt_bytes $(( ${rss:-0} * 1024 )))"
  printf '  RAM доступно:      %s\n' "$(fmt_bytes "${ram_avail:-0}")"
  printf '  Swap занято:          %s\n' "$(fmt_bytes "${swap_used:-0}")"
  printf '  Fake-TLS:           %s\n' "$FAKE_TLS_DOMAIN"
  printf '  Рекламный tag:      %s\n' "${AD_TAG:-disabled}"
}

stats_cmd(){
  reload_state; period_resolve "${1:-today}" || return; header; echo; echo -e "${BOLD}${PERIOD_LABEL}${NC}  ${START_DAY} .. ${END_DAY}"
  [[ -f "$DB" ]] || { echo 'База статистики пока пуста.'; return; }
  local uniq obs conn bad rx tx peakc peaki
  uniq=$(dbq "SELECT count(DISTINCT ip_hash) FROM anon_visits WHERE day BETWEEN '$START_DAY' AND '$END_DAY';"); obs=$(dbq "SELECT coalesce(sum(observations),0) FROM anon_visits WHERE day BETWEEN '$START_DAY' AND '$END_DAY';")
  conn=$(dbq "SELECT coalesce(sum(connections),0) FROM daily_traffic WHERE day BETWEEN '$START_DAY' AND '$END_DAY' AND username!='__GLOBAL__';"); bad=$(dbq "SELECT coalesce(sum(bad_connections),0) FROM daily_traffic WHERE day BETWEEN '$START_DAY' AND '$END_DAY' AND username='__GLOBAL__';")
  rx=$(dbq "SELECT coalesce(sum(bytes_from_client),0) FROM daily_traffic WHERE day BETWEEN '$START_DAY' AND '$END_DAY' AND username!='__GLOBAL__';"); tx=$(dbq "SELECT coalesce(sum(bytes_to_client),0) FROM daily_traffic WHERE day BETWEEN '$START_DAY' AND '$END_DAY' AND username!='__GLOBAL__';")
  peakc=$(dbq "SELECT coalesce(max(peak_connections),0) FROM daily_traffic WHERE day BETWEEN '$START_DAY' AND '$END_DAY' AND username='__GLOBAL__';"); peaki=$(dbq "SELECT coalesce(max(peak_unique_ips),0) FROM daily_traffic WHERE day BETWEEN '$START_DAY' AND '$END_DAY' AND username='__GLOBAL__';")
  printf '  Уникальных IP:          %s\n' "${uniq:-0}"
  printf '  Сеансов подключения: %s\n' "${obs:-0}"
  printf '  Подключений:    %s\n' "${conn:-0}"
  printf '  Ошибок/отклонено:        %s\n' "${bad:-0}"
  printf '  От клиента:      %s\n' "$(fmt_bytes "${rx:-0}")"
  printf '  К клиенту:    %s\n' "$(fmt_bytes "${tx:-0}")"
  printf '  Пик соединений:    %s\n' "${peakc:-0}"
  printf '  Пик уникальных IP:     %s\n' "${peaki:-0}"
  echo; echo 'По источникам:'
  sqlite3 -column -header "$DB" "SELECT username AS source, count(DISTINCT ip_hash) AS unique_ips, sum(observations) AS episodes FROM anon_visits WHERE day BETWEEN '$START_DAY' AND '$END_DAY' GROUP BY username ORDER BY unique_ips DESC, episodes DESC;" 2>/dev/null || true
}

traffic_cmd(){
  period_resolve "${1:-7d}" || return; header; echo; echo -e "${BOLD}Трафик — ${PERIOD_LABEL}${NC}"
  [[ -f "$DB" ]] || return
  echo; echo 'По дням:'
  sqlite3 -column -header "$DB" "SELECT day, sum(CASE WHEN username!='__GLOBAL__' THEN connections ELSE 0 END) AS conns, printf('%.2f MB',sum(CASE WHEN username!='__GLOBAL__' THEN bytes_from_client ELSE 0 END)/1048576.0) AS up, printf('%.2f MB',sum(CASE WHEN username!='__GLOBAL__' THEN bytes_to_client ELSE 0 END)/1048576.0) AS down, max(CASE WHEN username='__GLOBAL__' THEN peak_connections ELSE 0 END) AS peak FROM daily_traffic WHERE day BETWEEN '$START_DAY' AND '$END_DAY' GROUP BY day ORDER BY day DESC;" || true
  echo; echo 'По источникам:'
  sqlite3 -column -header "$DB" "SELECT username AS source, sum(connections) AS conns, printf('%.2f MB',sum(bytes_from_client)/1048576.0) AS up, printf('%.2f MB',sum(bytes_to_client)/1048576.0) AS down, max(peak_connections) AS peak FROM daily_traffic WHERE username!='__GLOBAL__' AND day BETWEEN '$START_DAY' AND '$END_DAY' GROUP BY username ORDER BY (sum(bytes_from_client)+sum(bytes_to_client)) DESC;" || true
}

ips_cmd(){
  header; [[ -f "$DB" ]] || { echo 'Данных по IP пока нет.'; return; }; echo
  sqlite3 -column -header "$DB" "SELECT c.ip, coalesce(group_concat(DISTINCT uv.username),'?') AS source, c.country_code AS cc, substr(coalesce(c.city,''),1,20) AS city, coalesce(c.asn,'') AS asn, substr(coalesce(c.org,''),1,28) AS provider, datetime(c.first_seen,'unixepoch','localtime') AS first_seen, datetime(c.last_seen,'unixepoch','localtime') AS last_seen, c.hits FROM clients c LEFT JOIN user_visits uv ON uv.ip=c.ip GROUP BY c.ip ORDER BY c.last_seen DESC LIMIT 100;"
}

api_ips_cmd(){ header; echo; echo 'Активные IP по данным TeleMT:'; api /v1/stats/users/active-ips 3 | jq -r 'if (.data|length)==0 then "Нет активных IP" else .data[]|.username as $u|.active_ips[]?|"\($u)\t\(.)" end' | column -t; }

geo_cmd(){
