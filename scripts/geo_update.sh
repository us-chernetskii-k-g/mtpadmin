#!/usr/bin/env bash
set -Eeuo pipefail
GEO_DIR=/var/lib/mtpadmin/geo
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$GEO_DIR"
chmod 0750 "$GEO_DIR"
chown root:mtpadmin "$GEO_DIR" 2>/dev/null || true

python3 -c 'import maxminddb' >/dev/null 2>&1 || {
  echo '[FAIL] python3-maxminddb не установлен' >&2
  exit 1
}

download_one(){
  local kind="$1" out="$2" ym url gz mmdb
  for ym in "$(date +%Y-%m)" "$(date -d '1 month ago' +%Y-%m)"; do
    url="https://download.db-ip.com/free/dbip-${kind}-lite-${ym}.mmdb.gz"
    gz="$TMP/${kind}.mmdb.gz"
    mmdb="$TMP/${kind}.mmdb"
    echo "[INFO] Скачиваю $url"
    if curl -fL --retry 3 --connect-timeout 15 --max-time 600 "$url" -o "$gz"; then
      gzip -t "$gz"
      gzip -dc "$gz" > "$mmdb"
      python3 - "$mmdb" <<'PY'
import sys, maxminddb
p=sys.argv[1]
with maxminddb.open_database(p) as r:
    rec=r.get('8.8.8.8')
    if not isinstance(rec,dict):
        raise SystemExit('MMDB validation failed')
print('MMDB OK')
PY
      install -m 0640 -o root -g mtpadmin "$mmdb" "$out"
      return 0
    fi
  done
  return 1
}

download_one city "$GEO_DIR/dbip-city-lite.mmdb" || {
  echo '[FAIL] Не удалось скачать City Lite' >&2
  exit 1
}
download_one asn "$GEO_DIR/dbip-asn-lite.mmdb" || {
  echo '[FAIL] Не удалось скачать ASN Lite' >&2
  exit 1
}

cat > "$GEO_DIR/ATTRIBUTION.txt" <<'EOF'
IP geolocation by DB-IP.com
DB-IP Lite databases are licensed under CC BY 4.0.
https://db-ip.com/db/lite.php
EOF
chmod 0640 "$GEO_DIR/ATTRIBUTION.txt"
chown root:mtpadmin "$GEO_DIR/ATTRIBUTION.txt" 2>/dev/null || true
echo '[PASS] DB-IP City Lite и ASN Lite обновлены'
