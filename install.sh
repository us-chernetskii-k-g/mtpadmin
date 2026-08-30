#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.4.4'
RAW_BASE='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main'
STATE='/etc/mtpadmin/state.env'
CFG='/etc/mtpadmin/config/config.toml'
SERVICE='mtpadmin-telemt.service'
STATSSVC='mtpadmin-stats.service'

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok(){ echo -e "${GREEN}[PASS]${NC} $*"; }
info(){ echo -e "${CYAN}[INFO]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
die(){ echo -e "${RED}[FAIL]${NC} $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запустите установщик от root или через sudo.'
command -v systemctl >/dev/null 2>&1 || die 'Нужен systemd.'
[[ -e "$STATE" ]] && die 'MTPADMIN уже установлен. Для обновления используйте update.sh из репозитория.'

TTY='/dev/tty'
[[ -r "$TTY" ]] || TTY='/dev/stdin'
ask(){
  local prompt="$1" def="${2:-}" out
  if [[ -n "$def" ]]; then
    printf '%s [%s]: ' "$prompt" "$def" >"$TTY"
  else
    printf '%s: ' "$prompt" >"$TTY"
  fi
  IFS= read -r out <"$TTY" || true
  printf '%s' "${out:-$def}"
}
ask_secret(){
  local prompt="$1" out
  printf '%s' "$prompt" >"$TTY"
  IFS= read -r -s out <"$TTY" || true
  printf '\n' >"$TTY"
  printf '%s' "$out"
}
yn(){
  local prompt="$1" def="${2:-Y}" out
  printf '%s [%s]: ' "$prompt" "$def" >"$TTY"
  IFS= read -r out <"$TTY" || true
  out="${out:-$def}"
  [[ "$out" =~ ^[YyДд]$ ]]
}

case "$(uname -m)" in
  x86_64|amd64) TELEMT_ARCH='x86_64' ;;
  aarch64|arm64) TELEMT_ARCH='aarch64' ;;
  *) die "Архитектура $(uname -m) пока не поддерживается prebuilt TeleMT." ;;
esac

if command -v apt-get >/dev/null 2>&1; then
  PKG_MGR='apt'
else
  die 'Clean installer 0.4.4 сейчас поддерживает Debian/Ubuntu (apt).'
fi

LOCAL_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)
HOST_DEFAULT=$(hostname -f 2>/dev/null || hostname)

cat <<'BANNER'
╔════════════════════════════════════════════════════╗
║                  MTPADMIN 0.4.4                   ║
║          Clean install · TeleMT native            ║
╚════════════════════════════════════════════════════╝
BANNER

echo 'Установщик не меняет Caddy, firewall, SSH, почту или PostgreSQL.'
echo 'Публичным будет только выбранный MTProto TCP-порт; API и metrics — loopback.'
echo

PUBLIC_HOST="${MTP_PUBLIC_HOST:-$(ask 'Публичный домен прокси' "$HOST_DEFAULT")}"
PUBLIC_HOST="${PUBLIC_HOST% }"
PUBLIC_IP="${MTP_PUBLIC_IP:-$(ask 'Публичный/NAT IPv4 сервера' "$LOCAL_IP")}"
PUBLIC_IP="${PUBLIC_IP% }"
PORT="${MTP_PORT:-$(ask 'Порт MTProto Proxy' '8443')}"; PORT="${PORT% }"
PROFILE="${MTP_PROFILE:-$(ask 'Имя основного источника/profile' 'MAIN')}"; PROFILE="${PROFILE% }"
FAKE_TLS_DOMAIN="${MTP_FAKE_TLS_DOMAIN:-$(ask 'Fake-TLS SNI домен' 'google.com')}"; FAKE_TLS_DOMAIN="${FAKE_TLS_DOMAIN% }"
RETENTION_DAYS="${MTP_RETENTION_DAYS:-$(ask 'Хранить полные IP, дней' '7')}"; RETENTION_DAYS="${RETENTION_DAYS% }"
ANON_RETENTION_DAYS="${MTP_ANON_RETENTION_DAYS:-$(ask 'Хранить обезличенную историю, дней' '400')}"; ANON_RETENTION_DAYS="${ANON_RETENTION_DAYS% }"
PROMOTED_CHANNEL="${MTP_PROMOTED_CHANNEL:-$(ask 'Рекламируемый канал (необязательно)' '')}"; PROMOTED_CHANNEL="${PROMOTED_CHANNEL% }"

RAW_SECRET="${MTP_RAW_SECRET:-}"
if [[ -z "$RAW_SECRET" ]]; then
  RAW_SECRET=$(ask_secret 'Существующий raw secret 32 hex [Enter = сгенерировать]: ')
fi
if [[ -z "$RAW_SECRET" ]]; then RAW_SECRET=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n'); fi
RAW_SECRET=${RAW_SECRET,,}
[[ "$RAW_SECRET" =~ ^[0-9a-f]{32}$ ]] || die 'Raw secret должен быть ровно 32 hex-символа.'
LEGACY_SECRET="$RAW_SECRET"

AD_TAG="${MTP_AD_TAG:-}"
if [[ -z "$AD_TAG" ]]; then AD_TAG=$(ask 'Advertising tag @MTProxyBot 32 hex (необязательно)' ''); fi
AD_TAG=${AD_TAG,,}
[[ -z "$AD_TAG" || "$AD_TAG" =~ ^[0-9a-f]{32}$ ]] || die 'Ad tag должен быть пустым или ровно 32 hex-символа.'
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die 'Некорректный TCP-порт.'
[[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( RETENTION_DAYS >= 1 && RETENTION_DAYS <= 365 )) || die 'RETENTION_DAYS должен быть 1..365.'
[[ "$ANON_RETENTION_DAYS" =~ ^[0-9]+$ ]] && (( ANON_RETENTION_DAYS >= RETENTION_DAYS && ANON_RETENTION_DAYS <= 3650 )) || die 'ANON_RETENTION_DAYS должен быть не меньше raw retention и не больше 3650.'
[[ "$PROFILE" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die 'Profile: только A-Z, a-z, 0-9, _, ., - (до 64 символов).'
[[ -n "$PUBLIC_HOST" ]] || die 'Публичный домен не может быть пустым.'
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'Укажите IPv4 адрес сервера/NAT.'
[[ -n "$FAKE_TLS_DOMAIN" ]] || die 'Fake-TLS домен не может быть пустым.'

for lp in "$PORT" 9090 9091; do
  if ss -H -ltn "sport = :$lp" 2>/dev/null | grep -q .; then
    ss -ltnp "sport = :$lp" || true
    die "TCP-порт $lp уже занят."
  fi
done

info 'Устанавливаю недостающие системные пакеты...'
BASE_PKGS=(ca-certificates curl jq sqlite3 python3 dnsutils iproute2 tar gzip)
MISSING=()
for p in "${BASE_PKGS[@]}"; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || MISSING+=("$p")
done
if ((${#MISSING[@]})); then
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${MISSING[@]}"
fi
ok 'Базовые пакеты готовы'

install_telemt(){
  local libc='gnu' url tmp archive bin
  if ldd --version 2>&1 | grep -qi musl; then libc='musl'; fi
  url="https://github.com/telemt/telemt/releases/latest/download/telemt-${TELEMT_ARCH}-linux-${libc}.tar.gz"
  tmp=$(mktemp -d); archive="$tmp/telemt.tar.gz"
  info "Скачиваю TeleMT: $url"
  curl -fL --retry 3 --connect-timeout 15 --max-time 240 "$url" -o "$archive" || { rm -rf "$tmp"; die 'Не удалось скачать TeleMT.'; }
  tar -xzf "$archive" -C "$tmp" || { rm -rf "$tmp"; die 'Не удалось распаковать TeleMT.'; }
  bin=$(find "$tmp" -maxdepth 3 -type f -name telemt -print -quit)
  [[ -n "$bin" ]] || { rm -rf "$tmp"; die 'В архиве TeleMT нет binary.'; }
  install -m 0755 "$bin" /usr/local/bin/telemt
  rm -rf "$tmp"
  /usr/local/bin/telemt --help >/dev/null 2>&1 || die 'TeleMT binary не запускается.'
}
install_telemt
ok "TeleMT установлен: $(/usr/local/bin/telemt --version 2>/dev/null | head -1 || echo installed)"

if ! id -u mtpadmin >/dev/null 2>&1; then
  useradd --system --home /var/lib/mtpadmin/telemt --shell /usr/sbin/nologin mtpadmin
fi
install -d -m 0750 -o root -g mtpadmin /etc/mtpadmin
install -d -m 0750 -o root -g mtpadmin /etc/mtpadmin/config
install -d -m 0750 -o root -g mtpadmin /var/lib/mtpadmin
install -d -m 0750 -o mtpadmin -g mtpadmin /var/lib/mtpadmin/telemt
install -d -m 0750 -o root -g mtpadmin /var/lib/mtpadmin/geo
install -d -m 0755 /usr/local/lib/mtpadmin
install -d -m 0700 /var/backups/mtpadmin

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fetch_src(){
  local remote="$1" out="$2"
  curl -fsSL --retry 3 "${RAW_BASE}/${remote}" -o "$out" || die "Не удалось скачать ${remote}"
}
: > "$TMP/mtpadmin"
for part in 00-core.sh 10-sources.sh 20-admin.sh 30-menu.sh; do
  curl -fsSL --retry 3 "$RAW_BASE/src/mtpadmin.d/$part" >> "$TMP/mtpadmin" || die "Не удалось скачать CLI fragment $part"
done
: > "$TMP/stats_collector.py"
for part in 00-core.py 10-runtime.py; do
  curl -fsSL --retry 3 "$RAW_BASE/src/stats_collector.d/$part" >> "$TMP/stats_collector.py" || die "Не удалось скачать collector fragment $part"
done
fetch_src src/user_config.py "$TMP/user_config.py"
fetch_src scripts/render_config.sh "$TMP/render_config.sh"
fetch_src scripts/geo_update.sh "$TMP/geo_update.sh"
bash -n "$TMP/mtpadmin"
bash -n "$TMP/render_config.sh"
bash -n "$TMP/geo_update.sh"
python3 -m py_compile "$TMP/stats_collector.py" "$TMP/user_config.py"
ok 'Исходники MTPADMIN скачаны и проверены'

install -m 0700 "$TMP/mtpadmin" /usr/local/bin/mtpadmin
install -m 0700 "$TMP/stats_collector.py" /usr/local/lib/mtpadmin/stats_collector.py
install -m 0700 "$TMP/user_config.py" /usr/local/lib/mtpadmin/user_config.py
install -m 0700 "$TMP/render_config.sh" /usr/local/lib/mtpadmin/render_config.sh
install -m 0700 "$TMP/geo_update.sh" /usr/local/lib/mtpadmin/geo_update.sh

cat > "$STATE" <<EOF_STATE
MTPADMIN_VERSION='$VERSION'
PROFILE='$PROFILE'
PUBLIC_HOST='$PUBLIC_HOST'
PUBLIC_IP='$PUBLIC_IP'
PORT='$PORT'
RAW_SECRET='$RAW_SECRET'
LEGACY_SECRET='$LEGACY_SECRET'
AD_TAG='$AD_TAG'
FAKE_TLS_DOMAIN='$FAKE_TLS_DOMAIN'
PROMOTED_CHANNEL='$PROMOTED_CHANNEL'
RETENTION_DAYS='$RETENTION_DAYS'
ANON_RETENTION_DAYS='$ANON_RETENTION_DAYS'
TELEMT_CHANNEL='latest'
TELEMT_BIN='/usr/local/bin/telemt'
EOF_STATE
chmod 0600 "$STATE"

TAG_LINE=''
[[ -n "$AD_TAG" ]] && TAG_LINE="ad_tag = \"$AD_TAG\""
cat > "$CFG" <<EOF_CFG
# Generated by MTPADMIN $VERSION
[general]
fast_mode = true
use_middle_proxy = true
$TAG_LINE
proxy_secret_path = "proxy-secret"
middle_proxy_nat_ip = "$PUBLIC_IP"
middle_proxy_nat_probe = false
log_level = "normal"

[general.modes]
classic = true
secure = true
tls = true

[general.links]
show = "*"
public_host = "$PUBLIC_HOST"
public_port = $PORT

[server]
port = $PORT
metrics_listen = "127.0.0.1:9090"
metrics_whitelist = ["127.0.0.1/32", "::1/128"]

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32", "::1/128"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "$FAKE_TLS_DOMAIN"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
"$PROFILE" = "$RAW_SECRET"

[[upstreams]]
type = "direct"
enabled = true
weight = 10
EOF_CFG
chown root:mtpadmin "$CFG"
chmod 0640 "$CFG"

if [[ ! -f /etc/mtpadmin/stats_salt ]]; then
  python3 - <<'PY' > /etc/mtpadmin/stats_salt
import secrets
print(secrets.token_hex(32))
PY
  chmod 0600 /etc/mtpadmin/stats_salt
fi

cat > /etc/systemd/system/mtpadmin-telemt.service <<'EOF_SERVICE'
[Unit]
Description=MTPADMIN TeleMT MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mtpadmin
Group=mtpadmin
WorkingDirectory=/var/lib/mtpadmin/telemt
ExecStart=/usr/local/bin/telemt /etc/mtpadmin/config/config.toml
Restart=always
RestartSec=3
TimeoutStartSec=30
TimeoutStopSec=30
LimitNOFILE=262144
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/mtpadmin/telemt
RestrictSUIDSGID=true
LockPersonality=true
RestrictAddressFamilies=AF_INET AF_INET6
UMask=0027

[Install]
WantedBy=multi-user.target
EOF_SERVICE

cat > /etc/systemd/system/mtpadmin-stats.service <<'EOF_STATS'
[Unit]
Description=MTPADMIN local client IP statistics collector
After=mtpadmin-telemt.service
Requires=mtpadmin-telemt.service

[Service]
Type=simple
ExecStart=/usr/local/lib/mtpadmin/stats_collector.py
Restart=always
RestartSec=3
Nice=10

[Install]
WantedBy=multi-user.target
EOF_STATS

cat > /etc/systemd/system/mtpadmin-geo-update.service <<'EOF_GEOSVC'
[Unit]
Description=MTPADMIN local DB-IP Geo database update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/mtpadmin/geo_update.sh
ExecStartPost=/bin/systemctl try-restart mtpadmin-stats.service
EOF_GEOSVC

cat > /etc/systemd/system/mtpadmin-geo-update.timer <<'EOF_GEOTIMER'
[Unit]
Description=Monthly MTPADMIN local Geo database update

[Timer]
OnCalendar=monthly
RandomizedDelaySec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF_GEOTIMER

systemctl daemon-reload
systemctl enable "$SERVICE" "$STATSSVC" >/dev/null
systemctl start "$SERVICE"

for _ in {1..20}; do
  if curl -fsS --max-time 2 http://127.0.0.1:9090/metrics >/dev/null 2>&1 && curl -fsS --max-time 2 http://127.0.0.1:9091/v1/users >/dev/null 2>&1; then break; fi
  sleep 1
done
systemctl is-active --quiet "$SERVICE" || { journalctl -u "$SERVICE" -n 60 --no-pager; die 'TeleMT не запустился.'; }
curl -fsS --max-time 2 http://127.0.0.1:9090/metrics >/dev/null || die 'TeleMT запущен, но metrics не отвечают.'

systemctl start "$STATSSVC"
sleep 3
systemctl is-active --quiet "$STATSSVC" || { journalctl -u "$STATSSVC" -n 60 --no-pager; die 'Collector не запустился.'; }
ok 'TeleMT и collector запущены'

if yn 'Установить локальные City + ASN GeoIP базы DB-IP Lite?' 'Y'; then
  mtpadmin geo-setup || warn 'GeoIP setup не завершён; его можно повторить: mtpadmin geo-setup'
fi

echo
echo '===== DOCTOR ====='
mtpadmin doctor || true
echo
echo '===== LINKS ====='
mtpadmin links || true

echo
echo "Установка MTPADMIN $VERSION завершена."
echo 'Команда управления: sudo mtpadmin'
echo 'Firewall/Caddy установщик не изменял.'
