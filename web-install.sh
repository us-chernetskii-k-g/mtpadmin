#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.6.0'
BASE_COMMIT='579aef84a1e58c4768357ab7ed238a8b787d4a8a'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
STATE='/etc/mtpadmin/state.env'
WEBSVC='/etc/systemd/system/mtpadmin-web.service'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запустите через sudo/root.'
[[ -f "$STATE" ]] || die 'Сначала установите MTPADMIN.'

# Scanner Guard is part of the 0.6 product. Bring the core to current main
# before installing/updating the web UI, without restarting TeleMT.
if [[ ! -x /usr/local/lib/mtpadmin/scanner_guard.py ]]; then
  info 'Сначала обновляю ядро MTPADMIN до версии со Scanner Guard...'
  curl -fsSL --retry 3 "$ROOT/main/update.sh" -o "$TMP/update.sh" || die 'Не удалось скачать update.sh.'
  chmod 0700 "$TMP/update.sh"
  bash -n "$TMP/update.sh"
  bash "$TMP/update.sh"
fi

curl -fsSL --retry 3 "$ROOT/$BASE_COMMIT/web-install.sh" -o "$TMP/base-web-install.sh" || die 'Не удалось скачать базовый web-installer.'

python3 - "$TMP/base-web-install.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
checks=["VERSION='0.5.0'","PORT=9199","RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"]
for marker in checks:
    if marker not in s:
        raise SystemExit('unexpected immutable web installer: '+marker)
s=s.replace("VERSION='0.5.0'", "VERSION='0.6.0'", 1)
s=s.replace("PORT=9199", "WEB_PORT=9199", 1)
s=s.replace('$PORT', '$WEB_PORT')
s=s.replace('RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX',
            'RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK',1)
p.write_text(s,encoding='utf-8')
PY

chmod 0700 "$TMP/base-web-install.sh"
bash -n "$TMP/base-web-install.sh"

# Deliberately run the interactive installer as a file, not as a pipe.
bash "$TMP/base-web-install.sh"

# The immutable installer downloaded the current four web fragments from main,
# where Scanner Guard is attached in 30-actions.py after the Handler is complete.
python3 - "$STATE" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); out=[]; done=False
for line in p.read_text(encoding='utf-8').splitlines():
    if line.startswith('MTPADMIN_VERSION='):
        out.append("MTPADMIN_VERSION='0.6.0'"); done=True
    else: out.append(line)
if not done: out.append("MTPADMIN_VERSION='0.6.0'")
p.write_text('\n'.join(out)+'\n',encoding='utf-8')
PY
chmod 0600 "$STATE"

if [[ -f "$WEBSVC" ]]; then
  if grep -q '^RestrictAddressFamilies=' "$WEBSVC"; then
    sed -i 's/^RestrictAddressFamilies=.*/RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK/' "$WEBSVC"
  fi
  systemctl daemon-reload
  systemctl restart mtpadmin-web.service
  sleep 1
  curl -fsS --max-time 5 -H 'X-MTPADMIN-User: local-health' http://127.0.0.1:9199/healthz >/dev/null || die 'Web healthcheck не прошёл.'
fi

ok "MTPADMIN Web $VERSION готов. Scanner Guard: autoban=OFF."
