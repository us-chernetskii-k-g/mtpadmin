#!/usr/bin/env bash
set -Eeuo pipefail

# Safe launcher for MTPADMIN Web 0.5.0.
# The original 0.5.0 installer used PORT for both the MTProxy port loaded
# from state.env and the local web backend port. This launcher executes the
# already CI-tested installer from an immutable commit after renaming the
# web-only variable to WEB_PORT.

BASE_COMMIT='579aef84a1e58c4768357ab7ed238a8b787d4a8a'
URL="https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/${BASE_COMMIT}/web-install.sh"
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
s=s.replace("PORT=9199", "WEB_PORT=9199", 1)
s=s.replace('$PORT', '$WEB_PORT')
p.write_text(s, encoding='utf-8')
PY

bash -n "$TMP"
exec 3>&- 2>/dev/null || true
bash "$TMP"
