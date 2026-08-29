# Архитектура MTPADMIN

## Runtime

- TeleMT: `/usr/local/bin/telemt`
- CLI: `/usr/local/bin/mtpadmin`
- конфиг TeleMT: `/etc/mtpadmin/config/config.toml`
- state: `/etc/mtpadmin/state.env`
- SQLite: `/var/lib/mtpadmin/stats.db`
- GeoIP: `/var/lib/mtpadmin/geo/`
- metrics: `127.0.0.1:9090`
- TeleMT Admin API: `127.0.0.1:9091`

## systemd

- `mtpadmin-telemt.service`
- `mtpadmin-stats.service`
- `mtpadmin-geo-update.service`
- `mtpadmin-geo-update.timer`

## Принципы

1. Proxy-порт публичный, API/metrics только loopback.
2. TeleMT работает от отдельного системного пользователя.
3. Секреты не находятся в Git.
4. Изменения конфигурации сначала валидируются и имеют rollback.
5. Полные IP хранятся ограниченное время; долгосрочная уникальность считается через локальный HMAC.
6. GeoIP выполняется локально.
7. Web UI будет слушать только loopback и публиковаться через Caddy.
