# MTPADMIN

Лёгкая система управления и мониторинга MTProto Proxy на базе [TeleMT](https://github.com/telemt/telemt). Ориентирована на небольшие VPS и production-серверы: Docker не требуется, TeleMT запускается нативно через systemd, статистика и GeoIP хранятся локально.

## Установка на новый сервер

Поддерживаются Debian/Ubuntu с systemd, `x86_64` и `aarch64`.

```bash
curl -fsSL https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main/install.sh | sudo bash
```

Установщик интерактивно спросит домен, публичный/NAT IPv4, порт, основной profile/source, существующий или новый 32-hex secret, Fake-TLS SNI и необязательный advertising tag. Пароли и production secrets в GitHub не отправляются.

Установщик **не изменяет Caddy, firewall, SSH, почту или PostgreSQL**. Публичным становится только выбранный MTProto TCP-порт. Prometheus metrics и TeleMT Admin API слушают только loopback.

## Обновление существующего MTPADMIN

```bash
curl -fsSL https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main/update.sh | sudo bash
```

`update.sh` сначала делает backup, проверяет синтаксис новых файлов и только затем заменяет MTPADMIN/collector. Сам TeleMT при таком обновлении не перезапускается. При ошибке collector выполняется rollback.

## Возможности

- native TeleMT + systemd;
- русское консольное меню `mtpadmin`;
- status / live dashboard / `doctor`;
- статистика подключений и трафика по периодам;
- локальная история IP с ограниченным retention;
- обезличенная HMAC-история уникальных клиентов;
- локальная GeoIP-геолокация: страна, регион, город;
- ASN / оператор сети через DB-IP Lite;
- несколько source/secret с отдельной статистикой;
- classic / secure / Fake-TLS ссылки;
- per-source limits и advertising tags;
- backup, runtime config reload и обновление TeleMT;
- Prometheus metrics `127.0.0.1:9090`;
- TeleMT Admin API `127.0.0.1:9091`.

## Основные команды

```bash
sudo mtpadmin
sudo mtpadmin doctor
sudo mtpadmin dashboard
sudo mtpadmin stats 7d
sudo mtpadmin geo today
sudo mtpadmin ips
sudo mtpadmin sources
sudo mtpadmin links
```

## GeoIP

Для геолокации используются локальные DB-IP Lite City и ASN. IP клиентов не отправляются внешнему GeoIP API.

```bash
sudo mtpadmin geo-setup
sudo mtpadmin geo-status
sudo mtpadmin geo-rebuild
```

DB-IP Lite распространяется по лицензии CC BY 4.0: https://db-ip.com/db/lite.php

## Безопасность

В репозитории не хранятся:

- MTProxy secrets;
- advertising tags production-инстансов;
- пароли будущей web-панели;
- реальные IP клиентов и SQLite-базы;
- `/etc/mtpadmin/state.env`;
- production backups.

GitHub Actions дополнительно проверяет синтаксис собранного CLI/collector и наличие известных production-значений.

## Структура

```text
install.sh                     clean install
update.sh                      безопасное обновление MTPADMIN
VERSION                        версия проекта
src/mtpadmin.d/*.sh            CLI, собирается в /usr/local/bin/mtpadmin
src/stats_collector.d/*.py     collector, собирается в stats_collector.py
src/user_config.py             управление source/secret
scripts/render_config.sh       применение основных настроек
scripts/geo_update.sh          обновление DB-IP Lite
.github/workflows/ci.yml       автоматические проверки
web/                           web-панель (следующий этап)
```

## Версия

Текущая ветка: **0.4.4**. Она включает GeoIP City/ASN, multi-source и исправление расчёта swap в `mtpadmin doctor`.

## В разработке

- лёгкая web-панель за Caddy с логином/паролем;
- Scanner Guard;
- ручной ban/unban IP;
- безопасный web-редактор sources/settings.
