#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION='0.11.11'
PATCH_LEVEL='mtpadmin-client-telemetry-v1'
TPROXY_REPO='https://github.com/telegramdesktop/tproxy-server.git'
TPROXY_MARKER='/usr/local/lib/mtpadmin/tproxy-server.commit'
PATCH_MARKER='/usr/local/lib/mtpadmin/tproxy-server.telemetry'
TPROXY_CFG='/etc/tproxy-server/config.json'
TPROXY_PROFILES='/etc/tproxy-server/profiles.json'
BINARY='/usr/local/bin/tproxy-server'
ADMIN='http://127.0.0.1:8081'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
chmod 0755 "$TMP"

ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }
die(){ echo "[FAIL] $*" >&2; exit 1; }

resolve_go(){
  go_binary=''
  if command -v go >/dev/null 2>&1; then
    minor=$(go env GOVERSION 2>/dev/null | sed -E 's/^go1\.([0-9]+).*/\1/' || true)
    [[ "$minor" =~ ^[0-9]+$ ]] && (( minor >= 20 )) && go_binary=$(command -v go)
  fi
  [[ -n "$go_binary" || ! -x /opt/go1.26.5/bin/go ]] || go_binary=/opt/go1.26.5/bin/go
  [[ -n "$go_binary" ]] || die 'Go toolchain не найден; выполните WEB Proxy repair из панели.'
  gofmt_binary="$(dirname "$go_binary")/gofmt"
  [[ -x "$gofmt_binary" ]] || die 'gofmt не найден рядом с Go toolchain.'
}

patch_source(){
  local src="$1"
  [[ -f "$src/internal/session/manager.go" && -f "$src/internal/server/server.go" ]] || die 'Некорректное дерево tproxy-server для telemetry patch.'
  python3 - "$src/internal/session/manager.go" "$src/internal/server/server.go" <<'PY'
from pathlib import Path
import sys
manager=Path(sys.argv[1]); server=Path(sys.argv[2])
ms=manager.read_text(encoding='utf-8')
ss=server.read_text(encoding='utf-8')

# The relay already keeps active session counts per client IP in memory for
# rate limiting. Expose only that existing in-memory state on the loopback
# admin listener; do not log requests, tokens, capabilities or query strings.
if 'type MTPAdminActiveClient struct' not in ms:
    marker='type Manager struct {\n'
    if ms.count(marker)!=1:
        raise SystemExit('manager type marker changed upstream')
    block='''type MTPAdminActiveClient struct {\n\tIP       string `json:"ip"`\n\tSessions int    `json:"sessions"`\n}\n\n'''
    ms=ms.replace(marker,block+marker,1)
if 'func (m *Manager) MTPAdminActiveClients()' not in ms:
    marker='func (m *Manager) Shutdown() {\n'
    if ms.count(marker)!=1:
        raise SystemExit('manager shutdown marker changed upstream')
    method='''func (m *Manager) MTPAdminActiveClients() []MTPAdminActiveClient {\n\tm.mu.Lock()\n\tresult := make([]MTPAdminActiveClient, 0, len(m.sessionsPerIP))\n\tfor ip, count := range m.sessionsPerIP {\n\t\tif count > 0 {\n\t\t\tresult = append(result, MTPAdminActiveClient{IP: ip, Sessions: count})\n\t\t}\n\t}\n\tm.mu.Unlock()\n\treturn result\n}\n\n'''
    ms=ms.replace(marker,method+marker,1)

if '"encoding/json"' not in ss:
    marker='\t"encoding/base64"\n'
    if ss.count(marker)!=1:
        raise SystemExit('server import marker changed upstream')
    ss=ss.replace(marker,marker+'\t"encoding/json"\n',1)
if 'mux.HandleFunc("/mtpadmin/clients", s.serveMTPAdminClients)' not in ss:
    marker='\tmux.HandleFunc("/metrics", s.serveMetrics)\n'
    if ss.count(marker)!=1:
        raise SystemExit('admin metrics marker changed upstream')
    ss=ss.replace(marker,marker+'\tmux.HandleFunc("/mtpadmin/clients", s.serveMTPAdminClients)\n',1)
if 'func (s *Server) serveMTPAdminClients(' not in ss:
    marker='func (s *Server) serveReady(w http.ResponseWriter, r *http.Request) {\n'
    if ss.count(marker)!=1:
        raise SystemExit('serveReady marker changed upstream')
    method='''func (s *Server) serveMTPAdminClients(w http.ResponseWriter, r *http.Request) {\n\tif r.Method != http.MethodGet {\n\t\thttp.Error(w, "method not allowed", http.StatusMethodNotAllowed)\n\t\treturn\n\t}\n\tw.Header().Set("Content-Type", "application/json; charset=utf-8")\n\tw.Header().Set("Cache-Control", "no-store")\n\tresponse := struct {\n\t\tClients []session.MTPAdminActiveClient `json:"clients"`\n\t}{Clients: s.manager.MTPAdminActiveClients()}\n\tif err := json.NewEncoder(w).Encode(response); err != nil {\n\t\treturn\n\t}\n}\n\n'''
    ss=ss.replace(marker,method+marker,1)

manager.write_text(ms,encoding='utf-8')
server.write_text(ss,encoding='utf-8')
PY
  "$gofmt_binary" -w "$src/internal/session/manager.go" "$src/internal/server/server.go"
  grep -q 'MTPAdminActiveClients' "$src/internal/session/manager.go" || die 'Telemetry manager patch не применился.'
  grep -q '/mtpadmin/clients' "$src/internal/server/server.go" || die 'Telemetry admin endpoint patch не применился.'
}

# CI/developer mode: patch an already checked-out upstream tree and stop before
# any root/systemd/runtime work. This is used to compile-test the exact patch
# logic against the pinned upstream commit.
if [[ -n "${MTPADMIN_TPROXY_TELEMETRY_PATCH_SOURCE:-}" ]]; then
  resolve_go
  patch_source "$MTPADMIN_TPROXY_TELEMETRY_PATCH_SOURCE"
  ok "Telemetry source patch PASS: $MTPADMIN_TPROXY_TELEMETRY_PATCH_SOURCE"
  exit 0
fi

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'WEB telemetry installer требует root.'
[[ -x "$BINARY" && -f "$TPROXY_MARKER" && -f "$TPROXY_CFG" && -f "$TPROXY_PROFILES" ]] || die 'Сначала установите Telegram WEB Proxy.'
commit=$(tr -d '\r\n' < "$TPROXY_MARKER")
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die 'Некорректный установленный commit tproxy-server.'
expected_marker="$commit|$PATCH_LEVEL"

validate_endpoint(){
  curl -fsS --max-time 3 "$ADMIN/mtpadmin/clients" | python3 -c 'import ipaddress,json,sys; d=json.load(sys.stdin); rows=d.get("clients"); assert isinstance(rows,list); [ipaddress.ip_address(str(x.get("ip"))) for x in rows]; assert all(isinstance(x.get("sessions"),int) and x.get("sessions")>0 for x in rows)' >/dev/null 2>&1
}

if [[ "$(cat "$PATCH_MARKER" 2>/dev/null || true)" == "$expected_marker" ]] && validate_endpoint; then
  ok "WEB client telemetry уже установлена: ${commit:0:12} · $PATCH_LEVEL"
  exit 0
fi

command -v git >/dev/null 2>&1 || die 'git не найден.'
id tproxy >/dev/null 2>&1 || die 'System user tproxy не найден.'
resolve_go

src="$TMP/tproxy-server"
buildhome="$TMP/buildhome"
git init -q "$src"
git -C "$src" remote add origin "$TPROXY_REPO"
git -C "$src" fetch -q --depth=1 origin "$commit"
git -C "$src" checkout -q --detach FETCH_HEAD
[[ "$(git -C "$src" rev-parse HEAD)" == "$commit" ]] || die 'Не удалось получить установленный upstream commit.'
patch_source "$src"

install -d -o tproxy -g tproxy -m 0700 "$buildhome"
chown -R tproxy:tproxy "$src"
info "Собираю tproxy-server ${commit:0:12} + WEB client telemetry..."
(cd "$src" && runuser -u tproxy -- env HOME="$buildhome" GOCACHE="$buildhome/gocache" GOMODCACHE="$buildhome/gomod" GOMAXPROCS=1 sh -c 'umask 022; exec "$@"' sh "$go_binary" test -p=1 ./...)
(cd "$src" && runuser -u tproxy -- env HOME="$buildhome" GOCACHE="$buildhome/gocache" GOMODCACHE="$buildhome/gomod" GOMAXPROCS=1 sh -c 'umask 022; exec "$@"' sh "$go_binary" build -p=1 -trimpath -ldflags='-s -w' -o "$buildhome/tproxy-server.bin" ./cmd/tproxy-server)
chmod 0755 "$buildhome/tproxy-server.bin"
"$buildhome/tproxy-server.bin" -config "$TPROXY_CFG" -profiles-file "$TPROXY_PROFILES" -check >/dev/null || die 'Telemetry build не принял production config.'

install -d -m 0700 /var/backups/mtpadmin
backup="/var/backups/mtpadmin/tproxy-server-before-telemetry-${commit:0:12}-$(date +%Y%m%d-%H%M%S)"
cp -a "$BINARY" "$backup"
rollback(){
  warn 'Telemetry relay не прошёл runtime-проверку; возвращаю предыдущий binary.'
  cp -a "$backup" "$BINARY"
  systemctl restart tproxy-server.service >/dev/null 2>&1 || true
}

install -m 0755 -o root -g root "$buildhome/tproxy-server.bin" "$BINARY"
if ! systemctl restart tproxy-server.service; then rollback; die 'Не удалось запустить telemetry relay.'; fi
ready=0
for _ in {1..20}; do
  if curl -fsS --max-time 2 "$ADMIN/readyz" >/dev/null 2>&1 && validate_endpoint; then ready=1; break; fi
  systemctl is-failed --quiet tproxy-server.service && break
  sleep 1
done
if (( ready == 0 )); then rollback; die 'Telemetry endpoint не вышел в READY.'; fi

printf '%s\n' "$expected_marker" > "$PATCH_MARKER"
chmod 0644 "$PATCH_MARKER"
ok "WEB client telemetry READY: /mtpadmin/clients · ${commit:0:12} · $PATCH_LEVEL"
