#!/usr/bin/env bash
set -Eeuo pipefail

# Safe launcher for MTPADMIN Web 0.5.1.
# It reuses the immutable CI-tested 0.5.0 installer and applies the small
# compatibility fixes before execution: a dedicated WEB_PORT and AF_NETLINK
# for read-only socket diagnostics from the hardened web service.

VERSION='0.5.1'
BASE_COMMIT='579aef84a1e58c4768357ab7ed238a8b787d4a8a'
URL="https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/${BASE_COMMIT}/web-install.sh"
STATE='/etc/mtpadmin/state.env'
TMP=$(mktemp /tmp/mtpadmin-web-core.XXXXXX.sh)
cleanup(){ rm -f "$TMP"; }
trap cleanup EXIT

curl -fsSL --retry 3 "$URL" -o "$TMP"

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
if "PORT=9199" not in s:
    raise SystemExit('unexpected installer source: WEB port marker not found')
s=s.replace("VERSION='0.5.0'", "VERSION='0.5.1'", 1)
s=s.replace("PORT=9199", "WEB_PORT=9199", 1)
s=s.replace('$PORT', '$WEB_PORT')
old='RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX'
new='RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK'
if old not in s:
    raise SystemExit('unexpected installer source: address-family marker not found')
s=s.replace(old,new,1)
p.write_text(s, encoding='utf-8')
PY

bash -n "$TMP"
exec 3>&- 2>/dev/null || true
bash "$TMP"

# The web installer is also a product-version transition. Keep CLI/web labels
# consistent even though TeleMT itself is not restarted here.
if [[ -f "$STATE" ]]; then
  python3 - "$STATE" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
lines=[]; done=False
for line in p.read_text(encoding='utf-8').splitlines():
    if line.startswith('MTPADMIN_VERSION='):
        lines.append("MTPADMIN_VERSION='0.5.1'"); done=True
    else:
        lines.append(line)
if not done:
    lines.append("MTPADMIN_VERSION='0.5.1'")
p.write_text('\n'.join(lines)+'\n',encoding='utf-8')
PY
  chmod 0600 "$STATE"
fi
