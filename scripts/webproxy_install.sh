#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION='0.11.0'
TPROXY_COMMIT='52a5feb7fac38f68da5afef9cedd9b3bfc8473ca'
TPROXY_REPO='https://github.com/telegramdesktop/tproxy-server.git'
STATE='/etc/mtpadmin/state.env'
CFG='/etc/mtpadmin/config/config.toml'
USERCFG='/usr/local/lib/mtpadmin/user_config.py'
API='http://127.0.0.1:9091'
CADDYFILE='/etc/caddy/Caddyfile'
BEGIN='# BEGIN MTPADMIN WEBPROXY - managed by mtpadmin'
END='# END MTPADMIN WEBPROXY - managed by mtpadmin'
TPROXY_CFG='/etc/tproxy-server/config.json'
TPROXY_PROFILES='/etc/tproxy-server/profiles.json'
TPROXY_SERVICE='/etc/systemd/system/tproxy-server.service'
TPROXY_MARKER='/usr/local/lib/mtpadmin/tproxy-server.commit'
SITE='/srv/tproxy-site'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }
die(){ echo "[FAIL] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'WEB Proxy installer требует root.'
[[ -f "$STATE" && -f "$CFG" ]] || die 'MTPADMIN не установлен.'
# shellcheck disable=SC1090
source "$STATE"
PUBLIC_HOST=${PUBLIC_HOST:-}
PUBLIC_IP=${PUBLIC_IP:-}
PORT=${PORT:-8443}
[[ -n "$PUBLIC_HOST" && -n "$PUBLIC_IP" ]] || die 'В state.env нет PUBLIC_HOST/PUBLIC_IP.'

if [[ -z "${WEBPROXY_HOST:-}" ]]; then
  if [[ "$PUBLIC_HOST" == *.*.* ]]; then
    WEBPROXY_HOST="webproxy.${PUBLIC_HOST#*.}"
  else
    WEBPROXY_HOST="webproxy.$PUBLIC_HOST"
  fi
fi
WEBPROXY_SOURCE=${WEBPROXY_SOURCE:-WEB_PROXY}
[[ "$WEBPROXY_HOST" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$WEBPROXY_HOST" == *.* ]] || die 'Некорректный WEBPROXY_HOST.'
[[ "$WEBPROXY_SOURCE" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die 'Некорректный WEBPROXY_SOURCE.'

state_set(){
  python3 - "$STATE" "$1" "$2" <<'PY'
from pathlib import Path
import os,sys,tempfile
p=Path(sys.argv[1]); key=sys.argv[2]; value=sys.argv[3]
lines=p.read_text(encoding='utf-8').splitlines(); out=[]; done=False
for line in lines:
    if line.startswith(key+'='):
        out.append(key+"='"+value.replace("'","'\\''")+"'"); done=True
    else: out.append(line)
if not done: out.append(key+"='"+value.replace("'","'\\''")+"'")
fd,tmp=tempfile.mkstemp(prefix='.state.',dir=str(p.parent),text=True)
with os.fdopen(fd,'w') as f: f.write('\n'.join(out)+'\n')
os.chmod(tmp,0o600); os.replace(tmp,p)
PY
}

telemt_secret(){
  python3 - "$CFG" "$WEBPROXY_SOURCE" <<'PY'
from pathlib import Path
import sys,tomllib
cfg=tomllib.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
print((((cfg.get('access') or {}).get('users') or {}).get(sys.argv[2]) or '').strip())
PY
}

reload_telemt(){
  local body rid st i
  body=$(curl -fsS --max-time 8 -X POST -H 'Content-Type: application/json' -d '{"mode":"instant","failure_policy":"rollback"}' "$API/v1/system/reload") || return 1
  rid=$(printf '%s' "$body" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("data") or {}).get("reload_id", ""))' 2>/dev/null || true)
  [[ -n "$rid" ]] || return 1
  for i in {1..30}; do
    st=$(curl -fsS --max-time 3 "$API/v1/system/reload/$rid" | python3 -c 'import json,sys; print((json.load(sys.stdin).get("data") or {}).get("state", ""))' 2>/dev/null || true)
    case "$st" in succeeded) return 0;; failed|rolled_back) return 1;; esac
    sleep 0.25
  done
  return 1
}

secret=$(telemt_secret)
if [[ -z "$secret" ]]; then
  cfg_backup="$TMP/config.toml.before-webproxy"
  cp -a "$CFG" "$cfg_backup"
  secret=$("$USERCFG" add "$WEBPROXY_SOURCE") || { cp -a "$cfg_backup" "$CFG"; die 'Не удалось создать TeleMT source для WEB Proxy.'; }
  if ! reload_telemt; then
    cp -a "$cfg_backup" "$CFG"
    reload_telemt >/dev/null 2>&1 || true
    die 'TeleMT не принял WEB Proxy source; конфиг восстановлен.'
  fi
  ok "TeleMT source $WEBPROXY_SOURCE создан без перезапуска"
fi
[[ "$secret" =~ ^[0-9a-f]{32}$ ]] || die 'WEB Proxy source имеет secret неверного формата.'

state_set WEBPROXY_HOST "$WEBPROXY_HOST"
state_set WEBPROXY_SOURCE "$WEBPROXY_SOURCE"
state_set WEBPROXY_TPROXY_COMMIT "$TPROXY_COMMIT"
state_set WEBPROXY_ENABLED '1'

if ! id tproxy >/dev/null 2>&1; then
  useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
fi

need_build=1
if [[ -x /usr/local/bin/tproxy-server && -f "$TPROXY_MARKER" ]] && grep -Fxq "$TPROXY_COMMIT" "$TPROXY_MARKER"; then
  need_build=0
fi

if (( need_build == 1 )); then
  info 'Собираю официальный telegramdesktop/tproxy-server (первый запуск может занять несколько минут)...'
  missing=()
  command -v git >/dev/null 2>&1 || missing+=(git)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  [[ -f /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
  if ((${#missing[@]})); then
    apt-get update -y >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null
  fi

  go_binary=''
  if command -v go >/dev/null 2>&1; then
    minor=$(go env GOVERSION 2>/dev/null | sed -E 's/^go1\.([0-9]+).*/\1/' || true)
    [[ "$minor" =~ ^[0-9]+$ ]] && (( minor >= 20 )) && go_binary=$(command -v go)
  fi
  if [[ -z "$go_binary" ]]; then
    go_version='1.26.5'
    go_checksum='5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053'
    archive="$TMP/go.tgz"
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
      -o "$archive" "https://go.dev/dl/go${go_version}.linux-amd64.tar.gz"
    [[ "$(sha256sum "$archive" | awk '{print $1}')" == "$go_checksum" ]] || die 'Checksum Go toolchain не совпал.'
    rm -rf "/opt/go${go_version}.new"
    mkdir -p "/opt/go${go_version}.new"
    tar -C "/opt/go${go_version}.new" --strip-components=1 -xzf "$archive"
    rm -rf "/opt/go${go_version}"
    mv "/opt/go${go_version}.new" "/opt/go${go_version}"
    go_binary="/opt/go${go_version}/bin/go"
  fi

  src="$TMP/tproxy-server"
  git init -q "$src"
  git -C "$src" remote add origin "$TPROXY_REPO"
  git -C "$src" fetch -q --depth=1 origin "$TPROXY_COMMIT"
  git -C "$src" checkout -q --detach FETCH_HEAD
  [[ "$(git -C "$src" rev-parse HEAD)" == "$TPROXY_COMMIT" ]] || die 'Не удалось зафиксировать официальный tproxy-server commit.'
  (cd "$src" && GOMAXPROCS=1 "$go_binary" test -p=1 ./...)
  (cd "$src" && GOMAXPROCS=1 "$go_binary" build -p=1 -trimpath -ldflags='-s -w' -o "$TMP/tproxy-server.bin" ./cmd/tproxy-server)
  install -m 0755 -o root -g root "$TMP/tproxy-server.bin" /usr/local/bin/tproxy-server
  install -d -m 0755 /usr/local/lib/mtpadmin
  printf '%s\n' "$TPROXY_COMMIT" > "$TPROXY_MARKER"
  chmod 0644 "$TPROXY_MARKER"
  ok 'Официальный WEB relay собран и установлен'
fi

install -d -o root -g tproxy -m 0750 /etc/tproxy-server
install -d -o root -g root -m 0755 "$SITE"

public_json=''
if ss -H -ltn 'sport = :3000' 2>/dev/null | grep -q '127.0.0.1:3000'; then
  public_json='  "public_upstream": "http://127.0.0.1:3000",'
  site_mode='upstream 127.0.0.1:3000'
else
  if [[ ! -f "$SITE/index.html" ]]; then
    cat > "$SITE/index.html" <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${WEBPROXY_HOST}</title><style>body{font-family:system-ui,sans-serif;background:#0b1220;color:#dbe7ff;max-width:760px;margin:12vh auto;padding:28px}h1{font-size:28px}p{color:#9fb0ca;line-height:1.6}.box{border:1px solid #24344e;border-radius:16px;padding:24px;background:#111c30}</style></head><body><div class="box"><h1>${WEBPROXY_HOST}</h1><p>Network service endpoint.</p><p>Status: online.</p></div></body></html>
EOF
    chmod 0644 "$SITE/index.html"
  fi
  public_json='  "public_dir": "/srv/tproxy-site",'
  site_mode='static site'
fi

cat > "$TPROXY_CFG" <<EOF
{
  "public_hostname": "$WEBPROXY_HOST",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
$public_json
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json",
  "enable_pprof": false,
  "limits": {
    "max_header_bytes": 16384,
    "max_body_bytes": 2097152,
    "max_frame_payload": 1048576,
    "carrier_batch_bytes": 2097152,
    "max_streams_per_session": 96,
    "max_closed_stream_ids": 2048,
    "max_pending_per_session": 8388608,
    "max_pending_global": 67108864,
    "max_pending_items_per_session": 4096,
    "max_pending_items_global": 32768,
    "max_sessions_global": 64,
    "max_streams_global": 1024,
    "max_backend_dials_in_flight": 64,
    "new_sessions_per_minute": 300,
    "new_sessions_burst": 64,
    "new_streams_per_minute": 3000,
    "new_streams_burst": 256,
    "max_bootstraps_global": 256,
    "new_bootstraps_per_minute": 600,
    "new_bootstraps_burst": 128,
    "max_profiles": 8
  },
  "timeouts": {
    "backend_dial": "5s",
    "long_poll": "25s",
    "reconnect_grace": "2m",
    "bootstrap_lifetime": "2m",
    "read_header": "10s",
    "idle": "75s",
    "shutdown": "15s"
  }
}
EOF
cat > "$TPROXY_PROFILES" <<EOF
{"profiles":[{"name":"$WEBPROXY_SOURCE","secret":"$secret","backend":"127.0.0.1:$PORT","carrier_mode":"https"}]}
EOF
chown root:tproxy "$TPROXY_CFG" "$TPROXY_PROFILES"
chmod 0640 "$TPROXY_CFG"
chmod 0400 "$TPROXY_PROFILES"

/usr/local/bin/tproxy-server -config "$TPROXY_CFG" -profiles-file "$TPROXY_PROFILES" -check >/dev/null || die 'tproxy-server config check failed.'

cat > "$TPROXY_SERVICE" <<'EOF'
[Unit]
Description=MTPADMIN Telegram WEB Proxy relay
After=network-online.target mtpadmin-telemt.service
Wants=network-online.target mtpadmin-telemt.service

[Service]
Type=simple
User=tproxy
Group=tproxy
LoadCredential=profiles.json:/etc/tproxy-server/profiles.json
ExecStart=/usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json
Restart=on-failure
RestartSec=3s
TimeoutStopSec=20s
LimitNOFILE=262144
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectClock=true
ProtectControlGroups=true
ProtectHome=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectProc=invisible
ProtectSystem=strict
ProcSubset=pid
ReadOnlyPaths=-/srv/tproxy-site
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=
IPAddressDeny=any
IPAddressAllow=localhost
SystemCallArchitectures=native
SystemCallFilter=@system-service
UMask=0077
MemoryMax=192M
TasksMax=128

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$TPROXY_SERVICE"
systemctl daemon-reload
systemctl enable --now tproxy-server.service >/dev/null
systemctl restart tproxy-server.service

ready=0
for i in {1..20}; do
  if curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null 2>&1; then ready=1; break; fi
  systemctl is-failed --quiet tproxy-server.service && break
  sleep 1
done
if (( ready == 0 )); then
  systemctl status tproxy-server.service --no-pager -l >&2 || true
  journalctl -u tproxy-server.service -n 100 --no-pager >&2 || true
  die 'WEB relay не вышел в READY.'
fi
ok 'WEB relay READY на 127.0.0.1:8080; admin 127.0.0.1:8081'

[[ -f "$CADDYFILE" ]] || die 'Caddyfile не найден.'
cp -a "$CADDYFILE" "$TMP/Caddyfile.before-webproxy"
python3 - "$CADDYFILE" "$TMP/Caddyfile.candidate" "$BEGIN" "$END" "$WEBPROXY_HOST" <<'PY'
from pathlib import Path
import sys
src,dst,begin,end,host=sys.argv[1:]
lines=Path(src).read_text(encoding='utf-8').splitlines(True)
out=[]; inside=False
for line in lines:
    s=line.strip()
    if s==begin: inside=True; continue
    if s==end: inside=False; continue
    if not inside: out.append(line)
if out and not out[-1].endswith('\n'): out[-1]+='\n'
if out and out[-1].strip(): out.append('\n')
out.extend((begin+'\n',f'{host} {{\n','\tencode zstd gzip\n','\theader Strict-Transport-Security "max-age=31536000; includeSubDomains"\n','\treverse_proxy 127.0.0.1:8080 {\n','\t\ttransport http {\n','\t\t\tresponse_header_timeout 40s\n','\t\t}\n','\t}\n','\thandle_errors {\n','\t\theader {\n','\t\t\tCache-Control "no-store"\n','\t\t\tContent-Security-Policy "default-src \'self\'; style-src \'self\'; img-src \'self\'; worker-src \'none\'; frame-ancestors \'none\'; base-uri \'none\'; form-action \'none\'"\n','\t\t\tPermissions-Policy "camera=(), microphone=(), geolocation=()"\n','\t\t\tReferrer-Policy "strict-origin-when-cross-origin"\n','\t\t\tX-Content-Type-Options "nosniff"\n','\t\t\tX-Frame-Options "DENY"\n','\t\t}\n','\t\trespond "{http.error.status_code} {http.error.status_text}" {http.error.status_code}\n','\t}\n','}\n',end+'\n'))
Path(dst).write_text(''.join(out),encoding='utf-8')
PY
caddy fmt --overwrite "$TMP/Caddyfile.candidate" >/dev/null 2>&1 || die 'Не удалось отформатировать Caddy candidate.'
if ! caddy validate --config "$TMP/Caddyfile.candidate" --adapter caddyfile >/dev/null 2>&1; then
  caddy validate --config "$TMP/Caddyfile.candidate" --adapter caddyfile || true
  die 'WEB Proxy Caddy candidate не прошёл validate.'
fi
install -m 0644 "$TMP/Caddyfile.candidate" "$CADDYFILE"
if ! systemctl reload caddy; then
  install -m 0644 "$TMP/Caddyfile.before-webproxy" "$CADDYFILE"
  systemctl reload caddy || true
  die 'Caddy reload не прошёл; старый Caddyfile восстановлен.'
fi
ok "Caddy подключил WEB Proxy hostname $WEBPROXY_HOST"

resolved=$(getent ahostsv4 "$WEBPROXY_HOST" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, - || true)
if printf ',%s,' "$resolved" | grep -q ",$PUBLIC_IP,"; then
  ok "DNS A $WEBPROXY_HOST -> $PUBLIC_IP"
  for i in {1..20}; do
    if curl -fsS --max-time 5 "https://$WEBPROXY_HOST/" >/dev/null 2>&1; then
      ok 'WEB Proxy HTTPS доступен с валидным TLS'
      break
    fi
    sleep 2
  done
else
  warn "DNS $WEBPROXY_HOST пока не указывает на $PUBLIC_IP (сейчас: ${resolved:-не разрешается}). Relay установлен; после создания A-записи Caddy получит сертификат автоматически."
fi

state_set WEBPROXY_SITE_MODE "$site_mode"
state_set WEBPROXY_LAST_INSTALL "$(date +%s)"

ok "Telegram WEB Proxy готов: host=$WEBPROXY_HOST source=$WEBPROXY_SOURCE backend=127.0.0.1:$PORT"
echo "[INFO] Клиентская ссылка доступна в MTPADMIN → Ссылки; raw secret в лог не выводится."
