#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

STATE='/etc/mtpadmin/state.env'
CFG='/etc/mtpadmin/config/config.toml'
TPROXY_PROFILES='/etc/tproxy-server/profiles.json'
TPROXY_CFG='/etc/tproxy-server/config.json'
MTPROXY_DIR='/opt/MTProxy'
MTPROXY_ENV='/etc/mtproxy/mtproxy.env'
MTPROXY_SERVICE='/etc/systemd/system/mtpadmin-webproxy-mtproxy.service'
FIREWALL_FILE='/etc/tproxy-server/mtpadmin-backend-firewall.nft'
FIREWALL_SERVICE='/etc/systemd/system/mtpadmin-webproxy-firewall.service'
MARKER='/usr/local/lib/mtpadmin/mtproxy-backend.commit'
MTPROXY_COMMIT='f36d8af769ffaeac36978d38c2c0f6d1104c2137'
MTPROXY_CHECKSUM='919795c416b870670841a21d1930ad97a24c7b84b9eb8c6f9e3de32f2fdf4655'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }
die(){ echo "[FAIL] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'WEB backend installer требует root.'
[[ -f "$STATE" && -f "$CFG" && -f "$TPROXY_CFG" ]] || die 'WEB Proxy ещё не установлен.'
# shellcheck disable=SC1090
source "$STATE"
WEBPROXY_SOURCE=${WEBPROXY_SOURCE:-WEB_PROXY}

secret=$(python3 - "$CFG" "$WEBPROXY_SOURCE" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); wanted=sys.argv[2]
section=None
section_re=re.compile(r'^\s*\[([^\[\]]+)\]\s*(?:#.*)?$')
key_re=re.compile(r'^\s*(?:"'+re.escape(wanted)+r'"|'+re.escape(wanted)+r')\s*=\s*"([0-9A-Fa-f]{32})"\s*(?:#.*)?$')
for raw in p.read_text(encoding='utf-8').splitlines():
    m=section_re.match(raw)
    if m:
        section=m.group(1).strip(); continue
    if section!='access.users': continue
    m=key_re.match(raw)
    if m:
        print(m.group(1).lower()); raise SystemExit(0)
raise SystemExit(2)
PY
) || die "Не удалось прочитать secret $WEBPROXY_SOURCE."
[[ "$secret" =~ ^[0-9a-f]{32}$ ]] || die 'WEB Proxy secret имеет неверный формат.'

if ! id mtproxy >/dev/null 2>&1; then useradd --system --home /nonexistent --shell /usr/sbin/nologin mtproxy; fi

need_pkg=0
for c in curl make gcc nft; do command -v "$c" >/dev/null 2>&1 || need_pkg=1; done
[[ -f /usr/include/openssl/ssl.h && -f /usr/include/zlib.h ]] || need_pkg=1
if (( need_pkg )); then
  info 'Устанавливаю зависимости official MTProxy backend...'
  apt-get update -y >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl build-essential libssl-dev zlib1g-dev nftables util-linux >/dev/null
fi

current=$(cat "$MARKER" 2>/dev/null || true)
if [[ ! -x "$MTPROXY_DIR/objs/bin/mtproto-proxy" || "$current" != "$MTPROXY_COMMIT" ]]; then
  info "Собираю официальный TelegramMessenger/MTProxy ${MTPROXY_COMMIT:0:12}..."
  archive="$TMP/MTProxy.tar.gz"; build="$TMP/MTProxy"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
    -o "$archive" "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz"
  [[ "$(sha256sum "$archive" | awk '{print $1}')" == "$MTPROXY_CHECKSUM" ]] || die 'Checksum official MTProxy archive не совпал.'
  install -d -o mtproxy -g mtproxy -m 0755 "$build"
  tar -C "$build" --strip-components=1 -xzf "$archive"
  chown -R mtproxy:mtproxy "$build"
  runuser -u mtproxy -- make -C "$build" -j1 >/dev/null
  [[ -x "$build/objs/bin/mtproto-proxy" ]] || die 'Official MTProxy binary не собрался.'
  chown -R root:root "$build"
  if [[ -e "$MTPROXY_DIR" ]]; then mv "$MTPROXY_DIR" "$MTPROXY_DIR.before-mtpadmin.$(date +%Y%m%d%H%M%S)"; fi
  mv "$build" "$MTPROXY_DIR"
  printf '%s\n' "$MTPROXY_COMMIT" > "$MARKER"
  chmod 0644 "$MARKER"
  ok 'Официальный MTProxy backend собран'
fi

install -d -o root -g mtproxy -m 0750 /etc/mtproxy
secret_tmp="$TMP/proxy-secret"; config_tmp="$TMP/proxy-multi.conf"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$secret_tmp" https://core.telegram.org/getProxySecret
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$config_tmp" https://core.telegram.org/getProxyConfig
[[ "$(wc -c < "$secret_tmp")" -eq 128 ]] || die 'Некорректный Telegram proxy-secret.'
[[ "$(wc -c < "$config_tmp")" -ge 100 ]] || die 'Некорректный Telegram proxy config.'
grep -q '^default ' "$config_tmp" || die 'proxy-multi.conf без default.'
grep -q '^proxy_for ' "$config_tmp" || die 'proxy-multi.conf без proxy_for.'
install -m 0640 -o root -g mtproxy "$secret_tmp" /etc/mtproxy/proxy-secret
install -m 0640 -o root -g mtproxy "$config_tmp" /etc/mtproxy/proxy-multi.conf
cat > "$MTPROXY_ENV" <<EOF
MTPROXY_SECRET=$secret
MTPROXY_WORKERS=1
MTPROXY_MAX_CONNECTIONS=4096
EOF
chown root:mtproxy "$MTPROXY_ENV"; chmod 0640 "$MTPROXY_ENV"

cat > "$FIREWALL_FILE" <<'EOF'
table inet mtpadmin_webproxy_backend {
  chain input {
    type filter hook input priority -10; policy accept;
    iifname != "lo" tcp dport { 2398, 8888 } drop
  }
}
EOF
chmod 0600 "$FIREWALL_FILE"
cat > "$FIREWALL_SERVICE" <<'EOF'
[Unit]
Description=MTPADMIN WEB Proxy backend firewall
Before=mtpadmin-webproxy-mtproxy.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c '/usr/sbin/nft list table inet mtpadmin_webproxy_backend >/dev/null 2>&1 || /usr/sbin/nft -f /etc/tproxy-server/mtpadmin-backend-firewall.nft'
ExecStop=/bin/sh -c '/usr/sbin/nft delete table inet mtpadmin_webproxy_backend >/dev/null 2>&1 || true'
[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$FIREWALL_SERVICE"

cat > "$MTPROXY_SERVICE" <<'EOF'
[Unit]
Description=MTPADMIN official MTProxy backend for Telegram WEB Proxy
After=network-online.target mtpadmin-webproxy-firewall.service
Wants=network-online.target
Requires=mtpadmin-webproxy-firewall.service
[Service]
Type=simple
User=mtproxy
Group=mtproxy
EnvironmentFile=/etc/mtproxy/mtproxy.env
WorkingDirectory=/opt/MTProxy
ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy -u mtproxy -p 8888 -H 2398 -S ${MTPROXY_SECRET} --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M ${MTPROXY_WORKERS} -C ${MTPROXY_MAX_CONNECTIONS}
Restart=on-failure
RestartSec=3s
LimitNOFILE=262144
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectHome=true
ProtectProc=invisible
ProtectSystem=strict
ProcSubset=pid
ReadOnlyPaths=/etc/mtproxy
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
LockPersonality=true
MemoryMax=160M
TasksMax=96
[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$MTPROXY_SERVICE"
systemctl daemon-reload
systemctl enable --now mtpadmin-webproxy-firewall.service >/dev/null
systemctl enable mtpadmin-webproxy-mtproxy.service >/dev/null
systemctl restart mtpadmin-webproxy-mtproxy.service

ready=0
for i in {1..20}; do
  if systemctl is-active --quiet mtpadmin-webproxy-mtproxy.service && ss -H -ltn 'sport = :2398' | grep -q .; then ready=1; break; fi
  sleep 1
done
if (( ! ready )); then journalctl -u mtpadmin-webproxy-mtproxy.service -n 80 --no-pager >&2 || true; die 'Official MTProxy backend не вышел в READY.'; fi
nft list table inet mtpadmin_webproxy_backend >/dev/null 2>&1 || die 'WEB backend firewall table отсутствует.'
ok 'Official MTProxy backend READY на localhost:2398; внешние 2398/8888 закрыты'

python3 - "$TPROXY_PROFILES" "$secret" "$WEBPROXY_SOURCE" <<'PY'
from pathlib import Path
import json,os,sys,tempfile
p=Path(sys.argv[1]); secret=sys.argv[2]; name=sys.argv[3]
data={'profiles':[{'name':name,'secret':secret,'backend':'127.0.0.1:2398','carrier_mode':'https'}]}
fd,tmp=tempfile.mkstemp(prefix='.profiles.',dir=str(p.parent),text=True)
with os.fdopen(fd,'w') as f:
    json.dump(data,f,separators=(',',':')); f.write('\n'); f.flush(); os.fsync(f.fileno())
os.chmod(tmp,0o400); os.replace(tmp,p)
PY
chown root:tproxy "$TPROXY_PROFILES"; chmod 0400 "$TPROXY_PROFILES"
/usr/local/bin/tproxy-server -config "$TPROXY_CFG" -profiles-file "$TPROXY_PROFILES" -check >/dev/null || die 'tproxy-server не принял профиль с official MTProxy backend.'
systemctl restart tproxy-server.service
for i in {1..20}; do curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null 2>&1 && break; sleep 1; done
curl -fsS --max-time 2 http://127.0.0.1:8081/readyz >/dev/null || die 'WEB relay не вышел в READY после переключения backend.'

python3 - "$STATE" <<'PY'
from pathlib import Path
import os,tempfile,sys
p=Path(sys.argv[1]); updates={'WEBPROXY_BACKEND':'official-mtproxy','WEBPROXY_BACKEND_PORT':'2398','WEBPROXY_BACKEND_READY':'1'}
lines=p.read_text().splitlines(); out=[]; seen=set()
for line in lines:
    key=line.split('=',1)[0] if '=' in line else ''
    if key in updates:
        out.append(f"{key}='{updates[key]}'"); seen.add(key)
    else: out.append(line)
for k,v in updates.items():
    if k not in seen: out.append(f"{k}='{v}'")
fd,tmp=tempfile.mkstemp(prefix='.state.',dir=str(p.parent),text=True)
with os.fdopen(fd,'w') as f: f.write('\n'.join(out)+'\n'); f.flush(); os.fsync(f.fileno())
os.chmod(tmp,0o600); os.replace(tmp,p)
PY

ok 'Telegram WEB Proxy backend переключён: tproxy-server -> official MTProxy localhost:2398'
