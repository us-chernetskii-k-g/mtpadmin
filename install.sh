#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# Clean-install bootstrap.
# First runs the known-good interactive base installer from a file, then
# upgrades the fresh installation to the current release from main.
BASE_COMMIT='b5dcc69b9d4761e475c17ed7e692790c405d42f0'
ROOT='https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin'
STATE='/etc/mtpadmin/state.env'
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

die(){ echo "[FAIL] $*" >&2; exit 1; }
ok(){ echo "[PASS] $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Запустите через sudo/root.'
[[ ! -e "$STATE" ]] || die 'MTPADMIN уже установлен. Используйте update.sh.'
command -v curl >/dev/null 2>&1 || die 'Не найден curl.'

curl -fsSL --retry 3 "$ROOT/$BASE_COMMIT/install.sh" -o "$TMP/base-install.sh" || die 'Не удалось скачать базовый установщик.'
chmod 0700 "$TMP/base-install.sh"
bash -n "$TMP/base-install.sh"

# Run as a real file: interactive reads/password entry are not tied to the
# curl pipe even when this bootstrap itself was launched as curl | bash.
bash "$TMP/base-install.sh"

curl -fsSL --retry 3 "$ROOT/main/update.sh" -o "$TMP/update.sh" || die 'Не удалось скачать актуальное обновление.'
chmod 0700 "$TMP/update.sh"
bash -n "$TMP/update.sh"
bash "$TMP/update.sh"

ok 'Чистая установка MTPADMIN завершена и обновлена до текущей версии.'
