#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION='0.11.12-hotfix2'
PATCH_LEVEL='mtpadmin-client-telemetry-v1'
TPROXY_REPO='https://github.com/telegramdesktop/tproxy-server.git'
TPROXY_MARKER='/usr/local/lib/mtpadmin/tproxy-server.commit'
PATCH_MARKER='/usr/local/lib/mtpadmin/tproxy-server.telemetry'
TPROXY_CFG='/etc/tproxy-server/config.json'
TPROXY_PROFILES='/etc/tproxy-server/profiles.json'
BINARY='/usr/local/bin/tproxy-server'
ADMIN='http://127.0.0.1:8081'
MIN_BUILD_FREE_KB=${MTPADMIN_TPROXY_BUILD_MIN_FREE_KB:-524288}
BUILD_ROOT=${MTPADMIN_TPROXY_BUILD_ROOT:-/var/tmp/mtpadmin-build}
install -d -m 0700 -o root -g root "$BUILD_ROOT"
find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'telemetry.*' -mtime +1 -exec rm -rf -- {} + 2>/dev/null || true
TMP=$(mktemp -d "$BUILD_ROOT/telemetry.XXXXXXXX")
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
ms=manager.read_text(encoding='utf-8'); ss=server.read_text(encoding='utf-8')
if 'type MTPAdminActiveClient struct' not in ms:
    marker='type Manager struct {\n'; assert ms.count(marker)==1
    ms=ms.replace(marker,'type MTPAdminActiveClient struct {\n\tIP string `json:"ip"`\n\tSessions int `json:"sessions"`\n}\n\n'+marker,1)
if 'func (m *Manager) MTPAdminActiveClients()' not in ms:
    marker='func (m *Manager) Shutdown() {\n'; assert ms.count(marker)==1
    method='''func (m *Manager) MTPAdminActiveClients() []MTPAdminActiveClient {\n\tm.mu.Lock()\n\tresult := make([]MTPAdminActiveClient, 0, len(m.sessionsPerIP))\n\tfor ip, count := range m.sessionsPerIP {\n\t\tif count > 0 { result = append(result, MTPAdminActiveClient{IP: ip, Sessions: count}) }\n\t}\n\tm.mu.Unlock()\n\treturn result\n}\n\n'''
    ms=ms.replace(marker,method+marker,1)
if '"encoding/json"' not in ss:
    marker='\t"encoding/base64"\n'; assert ss.count(marker)==1; ss=ss.replace(marker,marker+'\t"encoding/json"\n',1)
if 'mux.HandleFunc("/mtpadmin/clients", s.serveMTPAdminClients)' not in ss:
    marker='\tmux.HandleFunc("/metrics", s.serveMetrics)\n'; assert ss.count(marker)==1; ss=ss.replace(marker,marker+'\tmux.HandleFunc("/mtpadmin/clients", s.serveMTPAdminClients)\n',1)
if 'func (s *Server) serveMTPAdminClients(' not in ss:
    marker='func (s *Server) serveReady(w http.ResponseWriter, r *http.Request) {\n'; assert ss.count(marker)==1
    method='''func (s *Server) serveMTPAdminClients(w http.ResponseWriter, r *http.Request) {\n\tif r.Method != http.MethodGet { http.Error(w, "method not allowed", http.StatusMethodNotAllowed); return }\n\tw.Header().Set("Content-Type", "application/json; charset=utf-8")\n\tw.Header().Set("Cache-Control", "no-store")\n\tresponse := struct { Clients []session.MTPAdminActiveClient `json:"clients"` }{Clients: s.manager.MTPAdminActiveClients()}\n\t_ = json.NewEncoder(w).Encode(response)\n}\n\n'''
    ss=ss.replace(marker,method+marker,1)
manager.write_text(ms,encoding='utf-8'); server.write_text(ss,encoding='utf-8')
PY
  "$gofmt_binary" -w "$src/internal/session/manager.go" "$src/internal/server/server.go"
  grep -q 'MTPAdminActiveClients' "$src/internal/session/manager.go" || die 'Telemetry manager patch не применился.'
  grep -q '/mtpadmin/clients' "$src/internal/server/server.go" || die 'Telemetry admin endpoint patch не применился.'
}

if [[ -n "${MTPADMIN_TPROXY_TELEMETRY_PATCH_SOURCE:-}" ]]; then
  resolve_go; patch_source "$MTPADMIN_TPROXY_TELEMETRY_PATCH_SOURCE"; ok "Telemetry source patch PASS: $MTPADMIN_TPROXY_TELEMETRY_PATCH_SOURCE"; exit 0
fi

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'WEB telemetry installer требует root.'
[[ -x "$BINARY" && -f "$TPROXY_MARKER" && -f "$TPROXY_CFG" && -f "$TPROXY_PROFILES" ]] || die 'Сначала установите Telegram WEB Proxy.'
commit=$(tr -d '\r\n' < "$TPROXY_MARKER"); [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die 'Некорректный установленный commit tproxy-server.'
expected_marker="$commit|$PATCH_LEVEL"

validate_endpoint(){ curl -fsS --max-time 3 "$ADMIN/mtpadmin/clients" | python3 -c 'import ipaddress,json,sys; d=json.load(sys.stdin); r=d.get("clients"); assert isinstance(r,list); [ipaddress.ip_address(str(x.get("ip"))) for x in r]; assert all(isinstance(x.get("sessions"),int) and x.get("sessions")>0 for x in r)' >/dev/null 2>&1; }
wait_endpoint(){ local i; for i in {1..20}; do curl -fsS --max-time 2 "$ADMIN/readyz" >/dev/null 2>&1 && validate_endpoint && return 0; systemctl is-failed --quiet tproxy-server.service && return 1; sleep 1; done; return 1; }
write_marker(){ printf '%s\n' "$expected_marker" > "$PATCH_MARKER"; chmod 0644 "$PATCH_MARKER"; }
binary_has_telemetry(){ [[ -f "$1" ]] && grep -aFq '/mtpadmin/clients' "$1" 2>/dev/null; }

if [[ "$(cat "$PATCH_MARKER" 2>/dev/null || true)" == "$expected_marker" ]] && validate_endpoint; then ok "WEB client telemetry уже установлена: ${commit:0:12} · $PATCH_LEVEL"; exit 0; fi

if binary_has_telemetry "$BINARY"; then
  info 'Telemetry-код уже есть в текущем binary; проверяю без пересборки...'
  if systemctl restart tproxy-server.service >/dev/null 2>&1 && wait_endpoint; then write_marker; ok "WEB client telemetry восстановлена без сборки: ${commit:0:12}"; exit 0; fi
fi

restore_patched_backup(){
  local candidate rescue="$TMP/tproxy-current.rescue" restored=0
  [[ -d /var/backups/mtpadmin ]] || return 1
  cp -a "$BINARY" "$rescue"
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue; binary_has_telemetry "$candidate" || continue
    "$candidate" -config "$TPROXY_CFG" -profiles-file "$TPROXY_PROFILES" -check >/dev/null 2>&1 || continue
    info "Нашёл готовый telemetry binary в backup: $(basename "$candidate")"
    install -m 0755 -o root -g root "$candidate" "$BINARY"
    if systemctl restart tproxy-server.service >/dev/null 2>&1 && wait_endpoint; then write_marker; restored=1; break; fi
    install -m 0755 -o root -g root "$rescue" "$BINARY"; systemctl restart tproxy-server.service >/dev/null 2>&1 || true
  done < <(find /var/backups/mtpadmin -maxdepth 1 -type f -name "tproxy-server-before-${commit:0:12}-*" -printf '%T@ %p\n' 2>/dev/null | sort -nr | cut -d' ' -f2-)
  (( restored == 1 ))
}
if restore_patched_backup; then ok "WEB client telemetry восстановлена из backup без Go build: ${commit:0:12}"; exit 0; fi

command -v git >/dev/null 2>&1 || die 'git не найден.'; id tproxy >/dev/null 2>&1 || die 'System user tproxy не найден.'; resolve_go
free_kb=$(df -Pk "$TMP" | awk 'NR==2{print $4}'); [[ "$free_kb" =~ ^[0-9]+$ ]] || die 'Не удалось определить свободное место build filesystem.'
info "WEB telemetry build filesystem: $(df -P "$TMP" | awk 'NR==2{print $1}') · свободно $((free_kb/1024)) MB"
(( free_kb >= MIN_BUILD_FREE_KB )) || die "Недостаточно места для безопасной сборки WEB telemetry: свободно $((free_kb/1024)) MB, требуется не менее $((MIN_BUILD_FREE_KB/1024)) MB. Текущий relay оставлен без изменений."

src="$TMP/tproxy-server"; buildhome="$TMP/buildhome"; gotmp="$buildhome/gotmp"
git init -q "$src"; git -C "$src" remote add origin "$TPROXY_REPO"; git -C "$src" fetch -q --depth=1 origin "$commit"; git -C "$src" checkout -q --detach FETCH_HEAD
[[ "$(git -C "$src" rev-parse HEAD)" == "$commit" ]] || die 'Не удалось получить установленный upstream commit.'
patch_source "$src"
install -d -o tproxy -g tproxy -m 0700 "$buildhome" "$gotmp"; chown -R tproxy:tproxy "$src" "$buildhome"
info "Собираю tproxy-server ${commit:0:12} + WEB client telemetry (disk-backed mode)..."
(cd "$src" && runuser -u tproxy -- env HOME="$buildhome" TMPDIR="$gotmp" GOTMPDIR="$gotmp" GOCACHE="$buildhome/gocache" GOMODCACHE="$buildhome/gomod" GOMAXPROCS=1 GOTOOLCHAIN=local sh -c 'umask 022; exec "$@"' sh "$go_binary" build -p=1 -trimpath -ldflags='-s -w' -o "$buildhome/tproxy-server.bin" ./cmd/tproxy-server)
chmod 0755 "$buildhome/tproxy-server.bin"; "$buildhome/tproxy-server.bin" -config "$TPROXY_CFG" -profiles-file "$TPROXY_PROFILES" -check >/dev/null || die 'Telemetry build не принял production config.'

install -d -m 0700 /var/backups/mtpadmin; backup="/var/backups/mtpadmin/tproxy-server-before-telemetry-${commit:0:12}-$(date +%Y%m%d-%H%M%S)"; cp -a "$BINARY" "$backup"
rollback(){ warn 'Telemetry relay не прошёл runtime-проверку; возвращаю предыдущий binary.'; cp -a "$backup" "$BINARY"; systemctl restart tproxy-server.service >/dev/null 2>&1 || true; }
install -m 0755 -o root -g root "$buildhome/tproxy-server.bin" "$BINARY"
if ! systemctl restart tproxy-server.service; then rollback; die 'Не удалось запустить telemetry relay.'; fi
if ! wait_endpoint; then rollback; die 'Telemetry endpoint не вышел в READY.'; fi
write_marker; ok "WEB client telemetry READY: /mtpadmin/clients · ${commit:0:12} · $PATCH_LEVEL"
