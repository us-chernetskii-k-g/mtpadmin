# MTPADMIN

### Свой Telegram proxy — без постоянной возни с консолью

Telegram MTProto Proxy, которым удобно управлять.

MTPADMIN превращает обычный VPS в готовый Telegram proxy-сервер с понятной веб-панелью, статистикой, картой клиентов, Scanner Guard и поддержкой **Telegram WEB Proxy**.

> **Одна установка — MTProxy, WEB Proxy, аналитика и управление из браузера.**

Docker не нужен.

## Что умеет

- MTProto Proxy на базе **TeleMT**;
- официальный **Telegram WEB Proxy** через `telegramdesktop/tproxy-server`;
- Classic, Secure, FakeTLS и WEB-ссылки;
- QR-коды для быстрого подключения;
- клиенты online и история подключений;
- графики IP, сеансов, соединений и трафика;
- карта стран, городов и ASN;
- отдельные источники вроде `SITE`, `TG_AD_01`, `FRIENDS`;
- Scanner Guard и Learning Mode без автоматических блокировок по умолчанию;
- события, диагностика и резервные копии;
- **Update Center** для MTPADMIN, TeleMT и WEB Proxy;
- бесшовные blue/green обновления веб-панели без остановки TeleMT.

## Установка

Нужен VPS на Ubuntu/Debian с `systemd` и публичным IP.

```bash
curl -fsSL https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main/install.sh | sudo bash
```

После установки доступны и веб-панель, и консольная команда:

```bash
mtpadmin
```

Обновление уже установленного сервера:

```bash
curl -fsSL https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main/update.sh | sudo bash
```

Перед обновлением автоматически создаётся backup.

## Веб-панель

Панель рассчитана на повседневное управление без постоянного SSH.

**Обзор** показывает состояние proxy, online, активные IP и основные тренды.

**Статистика** — клиенты, соединения, сеансы и трафик за разные периоды.

**Активные** — кто подключён сейчас, страна, город, ASN и источник.

**География** — карта и распределение клиентов.

**Источники** — отдельные secrets и статистика по каждой ссылке.

**Ссылки** — компактные карточки Classic, Secure, FakeTLS и WEB Proxy. Полные URL и secrets скрыты по умолчанию: можно сразу скопировать ссылку или раскрыть её вручную.

**Безопасность** — Scanner Guard, Risk score, whitelist и ручные блокировки.

**События** — история важных изменений и действий.

**Операции** — Health, Update Center, WEB Proxy, Guard Learning и backup. Интерфейс компактный: подробности разнесены по вкладкам, большие таблицы прокручиваются внутри карточек, а основные показатели остаются перед глазами.

**Система** — состояние TeleMT, collector, Caddy, памяти, диска и других компонентов.

## Telegram WEB Proxy

MTPADMIN использует официальный проект `telegramdesktop/tproxy-server`.

```text
Telegram
   ↓ HTTPS :443
WEB Proxy hostname
   ↓
Caddy
   ↓
tproxy-server
   ↓
TeleMT
   ↓
Telegram
```

Второй MTProxy не запускается: WEB relay использует уже работающий TeleMT как backend.

Hostname можно задать прямо в панели, например `webproxy.example.com`. Для него нужна DNS A-запись на IP сервера. Caddy после этого получает TLS-сертификат автоматически.

Обычный заход на WEB Proxy hostname остаётся обычным HTTPS-сайтом. Relay активируется только для WEB-capability клиента, поэтому существующий сайт можно использовать как естественный public upstream.

WEB Proxy использует отдельный источник `WEB_PROXY`, поэтому его статистика не смешивается с обычными ссылками. Панель формирует и `tg://webproxy`, и `https://t.me/webproxy` варианты.

## Update Center

Панель проверяет новую версию **MTPADMIN**, новые релизы **TeleMT** и актуальный upstream commit **Telegram WEB Proxy**.

Обновления запускаются отдельными systemd-задачами и не зависят от открытой вкладки браузера. В панели виден статус `QUEUED → RUNNING → SUCCESS/FAILED`, а кнопки подписаны названием компонента.

Одновременно выполняется только одна операция обновления. Это дополнительно защищено серверным lock, поэтому MTPADMIN, TeleMT и WEB Proxy не могут обновляться параллельно.

MTPADMIN обновляется blue/green и привязывается к конкретному commit SHA проверенного `main`. TeleMT перед заменой бинарника резервируется и откатывается при неудачном READY-check. WEB Proxy сначала собирается и проходит upstream-тесты, а затем заменяет рабочую версию.

## Scanner Guard

Scanner Guard наблюдает обращения к MTProxy и сопоставляет их с реальными клиентами TeleMT.

Статусы: `CLIENT`, `UNKNOWN`, `HOSTING?`, `SCAN`, `WHITELIST`, `BANNED`.

Risk score помогает быстро находить подозрительную активность, но сам по себе не является доказательством атаки.

**Автоблокировка по умолчанию выключена.** Learning Mode показывает, кого система могла бы заблокировать при разных порогах, ничего реально не блокируя.

## Приватность

История и графики строятся локально. GeoIP используется локально через DB-IP Lite; IP клиентов не отправляются во внешний GeoIP API.

В публичный репозиторий не попадают secrets, пароль панели, IP клиентов, база статистики, whitelist/ban конкретного сервера и резервные копии.

## Быстрая диагностика

```bash
mtpadmin doctor
```

Doctor проверяет TeleMT, API, collector, Scanner Guard, веб-панель, WEB Proxy, Caddy, DNS, память, Linux PSI, swap и свободное место.

## Текущая версия

**0.11.6** — восстановление WEB Proxy client links из фактической конфигурации TeleMT, компактная безопасная страница ссылок и сериализация операций Update Center.

Если нашли проблему или есть идея — Issues и Pull Requests приветствуются.
