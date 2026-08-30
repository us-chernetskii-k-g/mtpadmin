#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

VERSION='0.7.0'
BASE_COMMIT='579aef84a1e58c4768357ab7ed238a8b787d4a8a'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
STATE='/etc/mtpadmin/state.env'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запустите через sudo/root.'
[[ -f "$STATE" ]] || die 'Сначала установите MTPADMIN.'

# Bring the core to the current seamless-update generation before adding web.
info 'Проверяю и обновляю ядро MTPADMIN...'
curl -fsSL --retry 3 "$ROOT/main/update.sh" -o "$TMP/update.sh" || die 'Не удалось скачать update.sh.'
chmod 0700 "$TMP/update.sh"
bash -n "$TMP/update.sh"
bash "$TMP/update.sh"

# Reuse the already battle-tested interactive Caddy/auth installer only for the
# initial login/password/vhost creation. It starts the first legacy slot at
# 9199; immediately afterwards update.sh converts it to blue/green slots.
curl -fsSL --retry 3 "$ROOT/$BASE_COMMIT/web-install.sh" -o "$TMP/base-web-install.sh" || die 'Не удалось скачать базовый web-installer.'
python3 - "$TMP/base-web-install.sh" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
checks=["VERSION='0.5.0'","PORT=9199","RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"]
for marker in checks:
    if marker not in s: raise SystemExit('unexpected immutable web installer: '+marker)
s=s.replace("VERSION='0.5.0'", "VERSION='0.7.0'", 1)
s=s.replace("PORT=9199", "WEB_PORT=9199", 1)
s=s.replace('$PORT', '$WEB_PORT')
s=s.replace('RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX','RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK',1)
p.write_text(s,encoding='utf-8')
PY
chmod 0700 "$TMP/base-web-install.sh"
bash -n "$TMP/base-web-install.sh"

# Run interactively as a real file, never through stdin pipe.
bash "$TMP/base-web-install.sh"

# Convert the just-created 9199 legacy backend to the permanent blue/green
# architecture. The old slot stays alive until the candidate is healthy and
# Caddy has switched successfully.
info 'Перевожу веб-панель на бесшовную blue/green схему...'
curl -fsSL --retry 3 "$ROOT/main/update.sh" -o "$TMP/update-after-web.sh" || die 'Не удалось скачать финальный update.sh.'
chmod 0700 "$TMP/update-after-web.sh"
bash -n "$TMP/update-after-web.sh"
bash "$TMP/update-after-web.sh"

ok "MTPADMIN Web $VERSION готов. Последующие обновления используют blue/green; autoban=OFF."
