# Telegram WEB Proxy в MTPADMIN 0.11+

MTPADMIN интегрирует официальный proof-of-concept сервер `telegramdesktop/tproxy-server`.

## Схема

```text
Telegram WEB-capable client
        |
        | HTTPS :443
        v
Caddy / WEBPROXY_HOST
        |
        v
127.0.0.1:8080 tproxy-server
        |
        | обычный зашифрованный MTProxy stream
        v
127.0.0.1:8443 TeleMT
        |
        v
Telegram
```

Второй MTProxy не устанавливается. `tproxy-server` использует отдельный TeleMT source `WEB_PROXY`, поэтому WEB-трафик и клиенты видны в общей статистике MTPADMIN отдельно от других источников.

## Official upstream

Relay собирается из pinned commit официального репозитория:

- repository: `https://github.com/telegramdesktop/tproxy-server`
- commit: `52a5feb7fac38f68da5afef9cedd9b3bfc8473ca`

Перед установкой запускаются upstream Go tests. На малом VPS build выполняется с `GOMAXPROCS=1` и `-p=1`, чтобы уменьшить пиковое потребление RAM.

## Порты

Публично доступны только обычные Caddy `80/443` и существующий MTProxy порт TeleMT. WEB relay слушает только loopback:

- `127.0.0.1:8080` — relay;
- `127.0.0.1:8081` — health/admin;
- backend — `127.0.0.1:8443` TeleMT.

## Hostname

WEB Proxy требует отдельный hostname. Для профиля DEIMOS по умолчанию получается `webproxy.brakonder.ru`.

DNS A-запись должна указывать на публичный IPv4 сервера. Если DNS ещё не создан, installer не ломает основной MTPADMIN: relay и Caddy-конфигурация остаются подготовленными, а Caddy получает сертификат автоматически после появления корректной записи.

## Secret

Installer создаёт или повторно использует TeleMT source `WEB_PROXY`. Raw secret хранится только в:

- `/etc/mtpadmin/config/config.toml` как TeleMT user secret;
- `/etc/tproxy-server/profiles.json` с mode `0400` и передачей процессу через systemd `LoadCredential`.

Raw secret не печатается в installer log. В защищённой веб-панели MTPADMIN он используется для формирования клиентской WEB-ссылки и локального QR.

Клиентская ссылка имеет вид:

```text
https://t.me/webproxy?server=webproxy.example.com&secret=<32-hex-secret>
```

## Проверка

```bash
systemctl status tproxy-server.service --no-pager
curl -fsS http://127.0.0.1:8081/healthz
curl -fsS http://127.0.0.1:8081/readyz
```

В панели MTPADMIN состояние находится в разделе **Операции**, а WEB-ссылка и QR — в **Ссылки**.
