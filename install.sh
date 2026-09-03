#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION='0.12.1'
BASE_COMMIT='b5dcc69b9d4761e475c17ed7e692790c405d42f0'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
API='https://api.github.com/repos/us-chernetskii-k-g/mtpadmin'
RELEASE_REF=${MTPADMIN_RELEASE_REF:-main}
STATE='/etc/mtpadmin/state.env'
BUILD_ROOT='/var/tmp/mtpadmin-build'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; unset WEB_PASS WEB_PASS2 MTPADMIN_WEB_PASSWORD MTP_RAW_SECRET RAW_SECRET' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запустите через sudo/root.'
[[ ! -e "$STATE" ]] || die 'MTPADMIN уже установлен. Используйте Центр обновлений или update.sh.'
command -v curl >/dev/null 2>&1 || die 'Не найден curl.'
[[ -r /dev/tty && -w /dev/tty ]] || die 'Для первоначальной установки нужен интерактивный терминал (SSH/консоль).'
exec 3<>/dev/tty

if [[ "$RELEASE_REF" == main ]]; then
  resolved=$(curl -fsSL --retry 3 "$API/branches/main" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("commit") or {}).get("sha", ""))' 2>/dev/null || true)
  [[ "$resolved" =~ ^[0-9a-f]{40}$ ]] || die 'Не удалось зафиксировать версию main для установки.'
  RELEASE_REF="$resolved"
fi

ask(){
  local prompt="$1" def="${2:-}" out=''
  if [[ -n "$def" ]]; then printf '%s [%s]: ' "$prompt" "$def" >&3; else printf '%s: ' "$prompt" >&3; fi
  IFS= read -r -u 3 out || die 'Не удалось прочитать ответ.'
  printf '%s' "${out:-$def}"
}
ask_secret(){
  local prompt="$1" out=''
  printf '%s' "$prompt" >&3
  IFS= read -r -s -u 3 out || die 'Не удалось прочитать скрытое значение.'
  printf '\n' >&3
  printf '%s' "$out"
}
confirm(){
  local prompt="$1" def="${2:-Y}" out=''
  printf '%s [%s]: ' "$prompt" "$def" >&3
  IFS= read -r -u 3 out || die 'Не удалось прочитать подтверждение.'
  out=${out:-$def}
  [[ "$out" =~ ^[YyДд]$ ]]
}
normal_host(){ local x="${1,,}"; x=${x#http://}; x=${x#https://}; x=${x%%/*}; x=${x%.}; printf '%s' "$x"; }
valid_host(){ [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$1" == *.* && "$1" != *:* ]]; }
base_domain(){
  local h="$1" n
  n=$(awk -F. '{print NF-1}' <<<"$h")
  if (( n >= 2 )); then printf '%s' "${h#*.}"; else printf '%s' "$h"; fi
}

LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)
HOST_DEFAULT=$(hostname -f 2>/dev/null || hostname)
[[ "$HOST_DEFAULT" == *.* ]] || HOST_DEFAULT='proxy.example.com'

cat >&3 <<'BANNER'
╔════════════════════════════════════════════════════╗
║        MTPADMIN · ПЕРВОНАЧАЛЬНАЯ УСТАНОВКА        ║
║                 мастер настройки                  ║
╚════════════════════════════════════════════════════╝

Сначала мастер соберёт все параметры и покажет итоговую сводку.
До подтверждения пакеты и службы системы не изменяются.
Для HTTPS заранее создайте DNS-записи доменов на этот сервер.

BANNER

PUBLIC_HOST=$(normal_host "${MTP_PUBLIC_HOST:-$(ask 'Домен обычного MTProto Proxy' "$HOST_DEFAULT")}")
PUBLIC_IP="${MTP_PUBLIC_IP:-$(ask 'Публичный/NAT IPv4 сервера' "$LOCAL_IP")}"
PORT="${MTP_PORT:-$(ask 'Порт MTProto Proxy' '8443')}"
PROFILE="${MTP_PROFILE:-$(ask 'Имя первого источника' 'MAIN')}"
FAKE_TLS_DOMAIN=$(normal_host "${MTP_FAKE_TLS_DOMAIN:-$(ask 'Домен маскировки FakeTLS' 'google.com')}")
RETENTION_DAYS="${MTP_RETENTION_DAYS:-$(ask 'Хранить полные IP, дней' '7')}"
ANON_RETENTION_DAYS="${MTP_ANON_RETENTION_DAYS:-$(ask 'Хранить обезличенную историю, дней' '400')}"
PROMOTED_CHANNEL="${MTP_PROMOTED_CHANNEL-}"
if [[ -z "${MTP_PROMOTED_CHANNEL+x}" ]]; then PROMOTED_CHANNEL=$(ask 'Рекламируемый Telegram-канал (необязательно)' ''); fi

RAW_SECRET="${MTP_RAW_SECRET:-}"
RAW_SECRET_MODE='задан'
if [[ -z "$RAW_SECRET" ]]; then
  RAW_SECRET=$(ask_secret 'Существующий секрет 32 hex [Enter = создать новый]: ')
fi
if [[ -z "$RAW_SECRET" ]]; then RAW_SECRET=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n'); RAW_SECRET_MODE='создан автоматически'; fi
RAW_SECRET=${RAW_SECRET,,}

if [[ -n "${MTP_AD_TAG+x}" ]]; then AD_TAG=${MTP_AD_TAG,,}; else AD_TAG=$(ask 'Рекламная метка @MTProxyBot, 32 hex (необязательно)' ''); AD_TAG=${AD_TAG,,}; fi

BASE_DOMAIN=$(base_domain "$PUBLIC_HOST")
WEB_DEFAULT="mtpadmin.$BASE_DOMAIN"
WEBPROXY_DEFAULT="webproxy.$BASE_DOMAIN"
WEB_HOST=$(normal_host "${MTPADMIN_WEB_HOST:-$(ask 'Домен веб-админки' "$WEB_DEFAULT")}")
WEB_USER="${MTPADMIN_WEB_USER:-$(ask 'Логин администратора' 'admin')}"
WEB_PASS="${MTPADMIN_WEB_PASSWORD:-}"
if [[ -z "$WEB_PASS" ]]; then
  WEB_PASS=$(ask_secret 'Пароль веб-админки (минимум 10 символов): ')
  WEB_PASS2=$(ask_secret 'Повторите пароль веб-админки: ')
  [[ "$WEB_PASS" == "$WEB_PASS2" ]] || die 'Пароли веб-админки не совпадают.'
fi
WEBPROXY_HOST=$(normal_host "${MTPADMIN_WEBPROXY_HOST:-$(ask 'Домен Telegram WEB Proxy' "$WEBPROXY_DEFAULT")}")

valid_host "$PUBLIC_HOST" || die 'Некорректный домен MTProto Proxy.'
valid_host "$WEB_HOST" || die 'Некорректный домен веб-админки.'
valid_host "$WEBPROXY_HOST" || die 'Некорректный домен Telegram WEB Proxy.'
[[ "$WEB_HOST" != "$WEBPROXY_HOST" ]] || die 'Домен веб-админки и WEB Proxy должны отличаться.'
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'Некорректный IPv4.'
[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT>=1 && PORT<=65535)) || die 'Порт должен быть 1..65535.'
[[ "$PROFILE" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die 'Имя источника: A-Z a-z 0-9 _ . - до 64 символов.'
[[ "$RAW_SECRET" =~ ^[0-9a-f]{32}$ ]] || die 'Секрет должен быть ровно 32 hex.'
[[ -z "$AD_TAG" || "$AD_TAG" =~ ^[0-9a-f]{32}$ ]] || die 'Рекламная метка должна быть пустой или 32 hex.'
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && ((RETENTION_DAYS>=1 && RETENTION_DAYS<=365)) || die 'Полные IP: 1..365 дней.'
[[ "$ANON_RETENTION_DAYS" =~ ^[0-9]+$ ]] && ((ANON_RETENTION_DAYS>=RETENTION_DAYS && ANON_RETENTION_DAYS<=3650)) || die 'Обезличенная история должна храниться не меньше полных IP и не больше 3650 дней.'
[[ "$WEB_USER" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]] || die 'Некорректный логин администратора.'
((${#WEB_PASS}>=10)) || die 'Пароль веб-админки должен быть минимум 10 символов.'

FREE_BUILD_KB=$(df -Pk /var/tmp | awk 'NR==2{print $4}')
[[ "$FREE_BUILD_KB" =~ ^[0-9]+$ ]] || die 'Не удалось проверить свободное место.'
((FREE_BUILD_KB>=1048576)) || die "Для установки нужно минимум 1 ГиБ свободно на файловой системе /var/tmp; сейчас $((FREE_BUILD_KB/1024)) МБ."

cat >&3 <<EOF

──────────────── ПАРАМЕТРЫ УСТАНОВКИ ────────────────
MTProto Proxy:          $PUBLIC_HOST:$PORT
Публичный/NAT IPv4:     $PUBLIC_IP
Первый источник:        $PROFILE
Маскировка FakeTLS:     $FAKE_TLS_DOMAIN
Секрет:                 $RAW_SECRET_MODE (значение скрыто)
Рекламная метка:        $([[ -n "$AD_TAG" ]] && echo 'задана' || echo 'не задана')
Telegram-канал:         ${PROMOTED_CHANNEL:-не задан}
Полные IP:              $RETENTION_DAYS дней
Обезличенная история:   $ANON_RETENTION_DAYS дней

Веб-админка:            https://$WEB_HOST/
Логин:                  $WEB_USER
Пароль:                 задан (значение скрыто)
Telegram WEB Proxy:     https://$WEBPROXY_HOST/

Версия:                 $VERSION · ${RELEASE_REF:0:12}
Свободно на диске:      $((FREE_BUILD_KB/1024)) МБ
─────────────────────────────────────────────────────
EOF

confirm 'Начать установку с этими параметрами?' 'Y' || die 'Установка отменена пользователем.'

install -d -m 0711 -o root -g root "$BUILD_ROOT"

for host in "$PUBLIC_HOST" "$WEB_HOST" "$WEBPROXY_HOST"; do
  resolved=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}' || true)
  if [[ -z "$resolved" ]]; then warn "DNS $host пока не разрешается."; elif [[ "$resolved" != "$PUBLIC_IP" ]]; then warn "DNS $host -> $resolved, ожидался $PUBLIC_IP."; else ok "DNS $host -> $PUBLIC_IP"; fi
done
confirm 'Продолжить даже если выше были предупреждения DNS?' 'N' || die 'Установка остановлена для исправления DNS.'

curl -fsSL --retry 3 "$ROOT/$BASE_COMMIT/install.sh" -o "$TMP/base-install.sh" || die 'Не удалось скачать базовый установщик ядра.'
python3 - "$TMP/base-install.sh" "$ROOT/$RELEASE_REF" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); raw=sys.argv[2]
s=p.read_text(encoding='utf-8')
old="RAW_BASE='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main'"
assert s.count(old)==1
s=s.replace(old,"RAW_BASE='"+raw+"'",1)
s=s.replace('PROMOTED_CHANNEL="${MTP_PROMOTED_CHANNEL:-$(ask \'Рекламируемый канал (необязательно)\' \'\')}"','PROMOTED_CHANNEL="${MTP_PROMOTED_CHANNEL-$(ask \'Рекламируемый канал (необязательно)\' \'\')}"',1)
old_ad='''AD_TAG="${MTP_AD_TAG:-}"\nif [[ -z "$AD_TAG" ]]; then AD_TAG=$(ask 'Advertising tag @MTProxyBot 32 hex (необязательно)' ''); fi'''
new_ad='''if [[ -n "${MTP_AD_TAG+x}" ]]; then AD_TAG="$MTP_AD_TAG"; else AD_TAG=$(ask 'Advertising tag @MTProxyBot 32 hex (необязательно)' ''); fi'''
assert s.count(old_ad)==1
s=s.replace(old_ad,new_ad,1)
p.write_text(s,encoding='utf-8')
PY
chmod 0700 "$TMP/base-install.sh"; bash -n "$TMP/base-install.sh"

MTP_PUBLIC_HOST="$PUBLIC_HOST" \
MTP_PUBLIC_IP="$PUBLIC_IP" \
MTP_PORT="$PORT" \
MTP_PROFILE="$PROFILE" \
MTP_FAKE_TLS_DOMAIN="$FAKE_TLS_DOMAIN" \
MTP_RETENTION_DAYS="$RETENTION_DAYS" \
MTP_ANON_RETENTION_DAYS="$ANON_RETENTION_DAYS" \
MTP_PROMOTED_CHANNEL="$PROMOTED_CHANNEL" \
MTP_RAW_SECRET="$RAW_SECRET" \
MTP_AD_TAG="$AD_TAG" \
bash "$TMP/base-install.sh"

if ! command -v caddy >/dev/null 2>&1; then
  info 'Устанавливаю Caddy для HTTPS веб-панели и Telegram WEB Proxy...'
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends caddy >/dev/null || die 'Не удалось установить Caddy.'
fi
systemctl enable --now caddy >/dev/null 2>&1 || true
[[ -f /etc/caddy/Caddyfile ]] || die 'Caddy установлен, но файл конфигурации отсутствует.'
ok 'Caddy готов'

python3 - "$STATE" "$WEBPROXY_HOST" <<'PY'
from pathlib import Path
import os,sys,tempfile
p=Path(sys.argv[1]); value=sys.argv[2]; key='WEBPROXY_HOST'
lines=p.read_text(encoding='utf-8').splitlines(); out=[]; done=False
for line in lines:
    if line.startswith(key+'='): out.append(f"{key}='{value}'"); done=True
    else: out.append(line)
if not done: out.append(f"{key}='{value}'")
fd,tmp=tempfile.mkstemp(prefix='.state.',dir=str(p.parent),text=True)
with os.fdopen(fd,'w') as f: f.write('\n'.join(out)+'\n'); f.flush(); os.fsync(f.fileno())
os.chmod(tmp,0o600); os.replace(tmp,p)
PY

curl -fsSL --retry 3 "$ROOT/$RELEASE_REF/web-install.sh" -o "$TMP/web-install.sh" || die 'Не удалось скачать зафиксированный установщик веб-панели.'
chmod 0700 "$TMP/web-install.sh"; bash -n "$TMP/web-install.sh"
MTPADMIN_RELEASE_REF="$RELEASE_REF" \
MTPADMIN_WEB_HOST="$WEB_HOST" \
MTPADMIN_WEB_USER="$WEB_USER" \
MTPADMIN_WEB_PASSWORD="$WEB_PASS" \
MTPADMIN_WEBPROXY_HOST="$WEBPROXY_HOST" \
bash "$TMP/web-install.sh"

unset WEB_PASS WEB_PASS2 MTPADMIN_WEB_PASSWORD MTP_RAW_SECRET RAW_SECRET
ok "MTPADMIN $VERSION установлен: обычный MTProto + веб-панель + Telegram WEB Proxy + статистика + Центр обновлений."
echo "Веб-панель: https://$WEB_HOST/"
echo "Логин: $WEB_USER"
echo "Telegram WEB Proxy: https://$WEBPROXY_HOST/"
