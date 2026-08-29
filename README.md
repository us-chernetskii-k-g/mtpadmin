# MTPADMIN

Лёгкая консольная система управления и мониторинга MTProto Proxy на базе [TeleMT](https://github.com/telemt/telemt).

Проект ориентирован на небольшие VPS и production-серверы, где уже могут работать Caddy, почта, PostgreSQL и другие сервисы. MTPADMIN не требует Docker и хранит метрики/историю локально.

## Возможности текущей ветки

- native TeleMT + systemd;
- консольная команда `mtpadmin` с русским интерфейсом;
- статус, live dashboard и `doctor`;
- статистика подключений и трафика;
- локальная история IP с ограниченным retention;
- обезличенная HMAC-история уникальных клиентов;
- локальная GeoIP-геолокация: страна, регион, город;
- ASN / оператор сети через DB-IP Lite;
- несколько source/secret с отдельной статистикой;
- ссылки MTProxy и Fake-TLS;
- backup / update / runtime reload;
- Prometheus metrics и TeleMT Admin API только на loopback.

## В разработке

- единый clean installer для нового сервера;
- лёгкая web-панель за Caddy с авторизацией;
- Scanner Guard и ручной ban/unban;
- безопасное обновление MTPADMIN из GitHub.

## Безопасность

В репозитории **не должны храниться**:

- MTProxy secrets;
- advertising tags;
- пароли web-панели;
- реальные IP клиентов и SQLite-базы;
- приватные backup-файлы;
- содержимое `/etc/mtpadmin/` с production-конфигурацией.

Все production-значения создаются локально на сервере.

## Структура

```text
src/mtpadmin                 основной CLI
src/stats_collector.py       сборщик статистики
src/user_config.py           безопасное редактирование access users
scripts/render_config.sh     применение настроек в config.toml
scripts/geo_update.sh        обновление локальных DB-IP Lite MMDB
```

## GeoIP

Для геолокации используются локальные DB-IP Lite City и ASN. IP клиентов не отправляются внешнему GeoIP API.

DB-IP Lite распространяется по лицензии CC BY 4.0. См. https://db-ip.com/db/lite.php

## Статус проекта

Текущая production-ветка: **0.4.3**. Исходники перенесены из рабочего экземпляра DEIMOS без production secrets и клиентских данных.

Clean install / web UI будут добавлены следующими коммитами.
