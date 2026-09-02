# MTPADMIN — свой Telegram Proxy с веб‑админкой

**Поднять собственный Telegram Proxy, получить готовые ссылки и QR, видеть клиентов и статистику, управлять источниками и обновлять всё из браузера.**

MTPADMIN — бесплатный open-source инструмент экосистемы **VPN BOSS** для тех, кто хочет собственный Telegram Proxy на VPS, но не хочет постоянно править конфиги, собирать ссылки вручную и разбираться с systemd после каждого изменения.

> **Установили один раз — дальше основная работа идёт через веб‑панель.**

[**VPN BOSS**](https://brakonder.ru) · [**Новости, помощь и обсуждение в Telegram**](https://t.me/boss_of_this_vpn)

---

## Два Telegram Proxy в одной установке

MTPADMIN поднимает и обслуживает сразу два транспорта:

| | Обычный MTProto Proxy | Telegram WEB Proxy |
|---|---|---|
| Транспорт | MTProto | HTTPS |
| Порт | настраивается, обычно `8443` | стандартный `443` |
| Серверная часть | TeleMT | `tproxy-server` + официальный `TelegramMessenger/MTProxy` |
| Готовые ссылки и QR | ✅ | ✅ |
| Управление из MTPADMIN | ✅ | ✅ |
| Live‑клиенты | ✅ | ✅ |
| IP / GeoIP / ASN | ✅ | ✅ |
| История и статистика | ✅ | ✅ |
| Диагностика / repair | ✅ | ✅ |

**WEB Proxy — не отдельный проект и не отдельная админка.** Он встроен в MTPADMIN и работает рядом с обычным MTProto Proxy.

---

# Главное преимущество — нормальная веб‑админка

После установки вы получаете HTTPS‑панель управления MTPADMIN.

### 📊 Обзор

На одной странице видно состояние:

- TeleMT;
- Telegram WEB Proxy;
- статистического collector;
- Scanner Guard;
- веб‑панели;
- DNS;
- памяти и swap;
- свободного места;
- backend и relay.

### 👥 Активные клиенты

Обычные MTProto и WEB Proxy клиенты отображаются **в одном live‑списке**.

Для активных клиентов доступны:

- IP;
- страна и город;
- ASN;
- провайдер / сеть;
- источник подключения;
- первое и последнее появление;
- текущая активность.

WEB Proxy больше не является «чёрным ящиком»: MTPADMIN получает его активные carrier‑сессии через локальную loopback-only telemetry‑интеграцию. Начиная с 0.11.15 production updater дополнительно проверяет именно браузерный маршрут `/active`, а не только внутреннюю helper-функцию.

### 🔗 Ссылки и QR

Панель формирует готовые подключения для:

- Classic;
- Secure;
- FakeTLS;
- Telegram WEB Proxy.

Не нужно вручную собирать URL или искать secret в конфиге.

**Уже розданная ссылка Telegram WEB Proxy сохраняется при обычных обновлениях, reinstall и repair.** MTPADMIN не должен менять её hostname/source/secret без явного административного действия. Updater контролирует идентичность WEB‑ссылки до и после обновления и остановится с ошибкой, если она неожиданно изменилась.

### 🧩 Источники

Можно создавать отдельные source для сайта, друзей, рекламы, проекта или любой другой площадки и видеть их статистику отдельно.

Для существующего source можно менять:

- Advertising tag;
- максимальное число TCP‑соединений;
- лимит уникальных IP.

После изменения MTPADMIN проверяет не только конфиг на диске, но и то, что source реально появился в runtime TeleMT. При проблеме используется recovery/restart/rollback логика.

### 📈 Статистика и география

Локально сохраняются:

- подключения;
- трафик;
- активность по времени;
- источники;
- страны и города;
- ASN / сети;
- история клиентов;
- пики активности.

GeoIP обрабатывается локально. Полный список IP не нужно отправлять во внешний GeoIP API.

### 🛡 Безопасность

В MTPADMIN есть Scanner Guard, Risk Score, whitelist и ручные блокировки.

Автоматические агрессивные блокировки **не включаются по умолчанию** — autoban остаётся `OFF`, пока администратор сам не решит иначе.

### 🔄 Update Center

MTPADMIN, TeleMT и Telegram WEB Proxy можно проверять и обновлять **прямо из браузера**.

Update Center использует фоновые systemd‑jobs и lock от параллельных операций. Веб‑панель MTPADMIN переключается по blue/green схеме, поэтому сам TeleMT не нужно останавливать ради обновления интерфейса.

Если операция продолжает работать, вкладку можно закрыть — задача выполняется на сервере.

### 🩺 Диагностика

```bash
mtpadmin doctor
```

`doctor` проверяет ключевые компоненты установки и показывает `PASS / WARN / FAIL` понятным списком.

---

# Новый Telegram WEB Proxy

Для пользователя это обычная WEB‑ссылка / QR из панели. Серверная схема:

```text
Telegram Desktop
      │ HTTPS :443
      ▼
WEB Proxy hostname
      ▼
    Caddy
      ▼
tproxy-server
      │ localhost
      ▼
official Telegram MTProxy
      ▼
   Telegram
```

MTPADMIN автоматически:

- создаёт отдельный WEB source;
- поднимает HTTPS через Caddy;
- устанавливает `telegramdesktop/tproxy-server`;
- подключает официальный `TelegramMessenger/MTProxy` backend;
- держит backend/admin‑порты на loopback;
- проверяет READY relay;
- применяет безопасный pending limit;
- умеет repair/reinstall WEB Proxy из Update Center;
- добавляет WEB‑клиентов в общую live‑статистику;
- показывает их IP, GeoIP и ASN.

`tproxy-server` принимает forwarded IP только от loopback reverse proxy и валидирует его; telemetry endpoint предназначен только для локального мониторинга. В него не добавляются proxy secret, capability/session token и URL запросов.

---

# Установка

## Требования

- VPS / сервер с публичным IPv4;
- Debian/Ubuntu;
- `systemd`;
- root / sudo;
- домены с DNS‑записями на сервер.

Для полного варианта удобно подготовить три имени:

```text
proxy.example.com       — обычный MTProto Proxy
mtpadmin.example.com    — веб‑админка
webproxy.example.com    — Telegram WEB Proxy
```

## Одна команда

```bash
curl -fsSL https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main/install.sh | sudo bash
```

Clean installer сначала собирает все параметры и **до первого изменения системы** показывает итоговую конфигурацию.

Мастер спрашивает:

- домен обычного MTProto Proxy;
- публичный/NAT IPv4;
- порт;
- имя первого source;
- FakeTLS SNI;
- существующий raw secret или генерацию нового;
- Advertising tag;
- рекламируемый Telegram‑канал — если нужен;
- сроки хранения истории;
- домен веб‑админки;
- логин и пароль администратора;
- отдельный домен Telegram WEB Proxy.

Пароль панели и raw secret не выводятся в открытом виде в итоговой сводке.

---

# Обновление

Предпочтительный путь:

**MTPADMIN → Операции → Update Center**

Запасной консольный вариант:

```bash
curl -fsSL https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main/update.sh | sudo bash
```

Updater использует backup, health‑checks, rollback‑логику и проверки runtime. Для существующего WEB Proxy он дополнительно контролирует, что hostname/source/secret не изменились, а браузерный `/active` действительно использует WEB-aware renderer.

---

# Что MTPADMIN не является

MTPADMIN — это **Telegram Proxy manager**, а не полноценный VPN‑сервер для всего интернет‑трафика устройства.

Для основного VPN‑проекта и других инструментов экосистемы:

- 🌐 [brakonder.ru](https://brakonder.ru)
- 💬 [t.me/boss_of_this_vpn](https://t.me/boss_of_this_vpn)

---

# Архитектура

- основной MTProto engine — **TeleMT**;
- WEB relay — **telegramdesktop/tproxy-server**;
- WEB backend — официальный **TelegramMessenger/MTProxy**;
- HTTPS — **Caddy**;
- веб‑панель — локальный Python backend за Caddy;
- статистика — локальная SQLite DB;
- GeoIP — локальная DB-IP Lite;
- сервисы — systemd;
- Update Center — фоновые systemd jobs + lock;
- web deploy — blue/green;
- WEB telemetry — loopback-only endpoint;
- Scanner Guard autoban — `OFF` по умолчанию.

---

# Поддержать разработку

MTPADMIN бесплатный. Разработка, тестовые VPS и проверка обновлений требуют времени и инфраструктуры.

Если проект оказался полезен — буду весьма признателен ❤️

### СПБ / МИР

[**Поддержать через YooKassa**](https://yookassa.ru/my/i/aoLKJEpmtnnX/l)

### USDT · TON — рекомендуемый вариант

```text
UQCjpkzF3YQKSXZUu7jxETBndx8qx6M21M4QtTKwi8_Ee2A1
```

### USDT · BEP‑20

```text
0xe93f304d4828c0dbc6667dd2761eb7b07e325ed4
```

### USDT · TRC‑20

```text
TFkFVRq9PEcSe4xbYG5NF24srPCjsPrizR
```

---

# Текущий публичный релиз

**0.11.15** — исправлен реальный HTTP‑маршрут страницы «Активные»: WEB Proxy renderer теперь подключён к analytics-plus route, поэтому активные WEB‑клиенты отображаются вместе с TeleMT, включая IP/GeoIP/ASN. Production updater проверяет браузерный `/active` и, если telemetry видит живой WEB IP, требует увидеть этот IP в HTML страницы.

Также 0.11.15 закрепляет стабильность уже розданных WEB‑ссылок: updater сравнивает hostname/source/secret до и после update/repair без вывода raw secret. Проверка WEB source теперь учитывает `in_runtime=true`, а не только наличие имени в disk-first API TeleMT.

Сохраняются возможности 0.11.14/0.11.13: единый clean‑install wizard, обычный MTProto + WEB Proxy, веб‑админка, disk-backed WEB telemetry, persistent stats, source lifecycle, route-safe Update Center, blue/green web deploy и Scanner Guard self‑heal.

Issues и Pull Requests приветствуются.
