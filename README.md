# MTPADMIN — свой Telegram Proxy с веб‑админкой

**Поднять собственный Telegram Proxy, получить готовые ссылки и QR, видеть клиентов и статистику, управлять источниками и обновлять всё из браузера.**

MTPADMIN — бесплатный open-source инструмент экосистемы **VPN BOSS** для тех, кто хочет свой Telegram Proxy на VPS, но не хочет каждый раз вручную править конфиги, собирать ссылки, читать systemd-логи и бояться очередного обновления.

> **Установили один раз — дальше основная работа идёт через веб‑панель.**

[**VPN BOSS**](https://brakonder.ru) · [**Новости, помощь и обсуждение в Telegram**](https://t.me/boss_of_this_vpn)

---

## Что нового и зачем это вообще нужно

MTPADMIN теперь поднимает **два транспорта Telegram Proxy одновременно**:

| | Обычный MTProto Proxy | Новый Telegram WEB Proxy |
|---|---|---|
| Транспорт | MTProto | HTTPS |
| Порт | настраивается, по умолчанию `8443` | стандартный `443` |
| Серверная часть | TeleMT | `tproxy-server` + официальный `TelegramMessenger/MTProxy` |
| Ссылки и QR | ✅ | ✅ |
| Управление из MTPADMIN | ✅ | ✅ |
| Live‑клиенты | ✅ | ✅ |
| IP / GeoIP / ASN | ✅ | ✅ |
| История и статистика | ✅ | ✅ |
| Диагностика / repair | ✅ | ✅ |

WEB Proxy — это **дополнительный HTTPS-транспорт**, который живёт рядом с обычным MTProto Proxy. Можно использовать оба варианта и переключаться между ними без отдельной ручной инфраструктуры.

---

# Главное преимущество — нормальная веб‑админка

После установки вы получаете HTTPS‑панель управления MTPADMIN.

Из браузера доступны:

### 📊 Обзор

Состояние сервера и ключевые показатели в одном месте:

- TeleMT;
- WEB Proxy;
- статистический collector;
- Scanner Guard;
- DNS;
- память и swap;
- свободное место;
- состояние backend и relay.

### 👥 Активные клиенты

В одном live‑списке отображаются **обычные MTProto и WEB Proxy клиенты**.

Для активных клиентов доступны:

- IP;
- страна;
- город;
- ASN;
- провайдер / сеть;
- источник подключения;
- первое и последнее появление;
- текущая активность.

WEB Proxy больше не является «чёрным ящиком»: MTPADMIN видит его активные carrier‑сессии через локальную telemetry‑интеграцию.

### 🔗 Ссылки и QR

Не нужно собирать URL вручную.

Панель формирует готовые подключения для:

- Classic;
- Secure;
- FakeTLS;
- Telegram WEB Proxy.

Secrets по умолчанию не нужно искать в конфиге или логах.

### 🧩 Источники

Можно создавать отдельные source для разных задач, например:

- основной доступ;
- сайт;
- друзья;
- реклама;
- отдельный проект;
- конкретная площадка.

Для существующего source можно менять:

- Advertising tag;
- максимальное число TCP‑соединений;
- лимит уникальных IP.

MTPADMIN не ограничивается записью файла: после изменения он проверяет, что source **реально появился в runtime TeleMT**. При проблеме выполняется recovery/rollback.

### 📈 Статистика

Локально сохраняются:

- подключения;
- трафик;
- активность по времени;
- источники;
- страны и города;
- ASN / сети;
- история клиентов;
- пики активности.

Историческая статистика не должна исчезать только потому, что TeleMT был перезапущен.

### 🌍 География

GeoIP работает локально. Панель показывает географию клиентов и сети без необходимости отправлять полный список IP во внешний GeoIP API.

### 🛡 Безопасность

В MTPADMIN есть Scanner Guard и инструменты наблюдения за подозрительной активностью.

Автоматические агрессивные блокировки **не включаются по умолчанию** — autoban остаётся `OFF`, пока администратор сам не решит иначе.

### 🔄 Update Center

MTPADMIN, TeleMT и WEB Proxy можно проверять и обновлять **прямо из веб‑панели**.

Update Center использует отдельные фоновые systemd‑jobs и lock от параллельных обновлений. Для MTPADMIN используется blue/green переключение веб‑панели.

То есть обычное обновление не должно превращаться в ручной набор команд по SSH.

### 🩺 Диагностика

Одна команда:

```bash
mtpadmin doctor
```

проверяет основные компоненты установки и показывает `PASS / WARN / FAIL` понятным списком.

---

# Новый Telegram WEB Proxy

Одна из главных возможностей новых версий MTPADMIN — полностью интегрированный **Telegram WEB Proxy**.

Для пользователя это обычная WEB‑ссылка / QR из панели. Серверная схема выглядит так:

```text
Telegram Desktop
      │
      │ HTTPS :443
      ▼
WEB Proxy hostname
      │
      ▼
    Caddy
      │
      ▼
tproxy-server
      │ localhost
      ▼
official Telegram MTProxy
      │
      ▼
   Telegram
```

MTPADMIN автоматически:

- создаёт отдельный WEB source;
- поднимает HTTPS через Caddy;
- устанавливает `telegramdesktop/tproxy-server`;
- подключает официальный `TelegramMessenger/MTProxy` backend;
- держит backend‑порты закрытыми от внешнего доступа;
- проверяет `READY` relay;
- следит за безопасными pending limits;
- умеет repair/reinstall WEB Proxy из Update Center;
- показывает WEB‑сессии в веб‑админке;
- добавляет WEB‑клиентов в общую статистику;
- показывает WEB IP, GeoIP и ASN через loopback‑only telemetry.

Telemetry endpoint не предназначен для публикации наружу: он находится на локальном admin listener и отдаёт MTPADMIN только данные, необходимые для мониторинга активных клиентов. Proxy secret, capability/session token и URL запросов туда не добавляются.

---

# Установка

## Требования

Для обычной установки нужен:

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

Clean installer запускает единый мастер настройки. До начала установки он собирает параметры и показывает итоговую конфигурацию.

Мастер спрашивает:

- домен обычного MTProto Proxy;
- публичный/NAT IPv4;
- порт;
- имя первого source;
- FakeTLS SNI;
- существующий raw secret или генерацию нового;
- Advertising tag;
- рекламируемый Telegram‑канал — если нужен;
- срок хранения полных IP;
- срок хранения обезличенной истории;
- домен веб‑админки;
- логин администратора;
- пароль + подтверждение;
- отдельный домен Telegram WEB Proxy.

Пароль панели и raw secret не выводятся в открытом виде в итоговой сводке.

После подтверждения MTPADMIN устанавливает и проверяет всю цепочку автоматически.

---

# Как выглядит обычная работа после установки

Вместо постоянного SSH:

```text
Открыли MTPADMIN в браузере
        ↓
посмотрели активных клиентов
        ↓
создали новый source
        ↓
получили ссылку / QR
        ↓
посмотрели статистику
        ↓
при появлении обновления нажали Update
```

SSH остаётся для диагностики и аварийных случаев, а не как основной интерфейс управления.

---

# Обновление

Предпочтительный путь для установленной системы:

**MTPADMIN → Операции → Update Center**

Запасной консольный вариант:

```bash
curl -fsSL https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main/update.sh | sudo bash
```

Updater использует backup, health‑checks, rollback‑логику и проверки runtime. Веб‑панель обновляется по blue/green схеме.

---

# Что MTPADMIN не является

MTPADMIN — это **Telegram Proxy manager**, а не полноценный VPN‑сервер для всего интернет‑трафика устройства.

Если интересует основной VPN‑проект и другие инструменты экосистемы — переходите в **VPN BOSS**.

- 🌐 [brakonder.ru](https://brakonder.ru)
- 💬 [t.me/boss_of_this_vpn](https://t.me/boss_of_this_vpn)

---

# Архитектура

Для тех, кому важны детали:

- основной MTProto engine — **TeleMT**;
- WEB relay — **telegramdesktop/tproxy-server**;
- WEB backend — официальный **TelegramMessenger/MTProxy**;
- HTTPS — **Caddy**;
- веб‑панель — лёгкий локальный Python backend за Caddy Basic Auth;
- статистика — локальная SQLite DB;
- GeoIP — локальная DB-IP Lite;
- управление сервисами — systemd;
- Update Center — фоновые systemd jobs + lock;
- web deploy — blue/green;
- WEB telemetry — loopback-only endpoint;
- Scanner Guard autoban — `OFF` по умолчанию.

Локальные backend/admin‑порты не должны публиковаться наружу.

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

Ориентир по комиссии — около `0.8 USDT`; фактическая комиссия зависит от кошелька или биржи.

### USDT · TRC‑20

```text
TFkFVRq9PEcSe4xbYG5NF24srPCjsPrizR
```

TRC‑20 обычно менее выгоден для небольшой поддержки; ориентир по комиссии — около `2.5 USDT`.

---

# Проект

MTPADMIN развивается как часть экосистемы **VPN BOSS**.

Если нашли ошибку или есть идея — Issues и Pull Requests приветствуются.

## Текущий публичный релиз

**0.11.13** — единый clean‑install wizard, route‑safe Update Center, обычный MTProto + WEB Proxy, WEB client IP/GeoIP/ASN telemetry, persistent stats, source lifecycle, blue/green web deploy, Scanner Guard self‑heal и disk‑safe WEB telemetry build.
