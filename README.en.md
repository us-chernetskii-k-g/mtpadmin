# MTPADMIN — your own Telegram Proxy with a web panel

[Русский](README.md) · [Українська](README.uk.md) · [فارسی](README.fa.md) · [简体中文](README.zh-CN.md) · [Türkçe](README.tr.md) · [العربية](README.ar.md) · [English](README.en.md)

**MTPADMIN helps you run your own Telegram proxy on a normal server and manage it through a simple web panel.**

Current version: **0.12.5**  
Status: **public testing**. Updating an existing live installation has been tested on a real server. We are now especially interested in clean-install feedback from different Debian and Ubuntu servers.

After installation you get two connection methods:

- regular **MTProto Proxy**;
- **Telegram WEB Proxy** over HTTPS.

The panel shows active users, statistics, country and network information, separate links for friends or campaigns, server health and available updates.

> Install it once; after that, most everyday tasks are done in the browser.

[VPN BOSS](https://brakonder.ru) · [Help and discussion on Telegram](https://t.me/boss_of_this_vpn)

---

## What MTPADMIN can do

- creates ready-to-use connection links and QR codes;
- shows active connections;
- keeps daily and per-source statistics;
- shows client country, city and network;
- lets you create separate links for friends, a website or campaigns;
- checks proxy and web-panel health;
- updates MTPADMIN, TeleMT and Telegram WEB Proxy from the browser;
- keeps an already shared WEB Proxy link during normal updates;
- can be added to a phone home screen like an app;
- includes Scanner Guard for viewing suspicious activity. Automatic blocking is off by default.

Location information is processed locally on your server. Client IP lists are not sent to an external geolocation service.

---

## Before installation

Use a clean server with:

- **Debian or Ubuntu**;
- x86-64 or ARM64;
- a public IPv4 address;
- `root` or `sudo` access;
- at least **1 GB of free disk space**;
- domain names already pointing to the server.

The simplest setup uses three names:

```text
proxy.example.com       — regular MTProto Proxy
panel.example.com       — MTPADMIN web panel
webproxy.example.com    — Telegram WEB Proxy
```

Ports `80` and `443` must be reachable for the panel and WEB Proxy. The chosen MTProto port, for example `8443`, must also be open.

MTPADMIN does not change your SSH settings or rewrite your entire firewall. It only adds a separate protection rule for the internal WEB Proxy services.

---

## Installation

Connect to the server over SSH and run:

```bash
curl -fsSL https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main/install.sh | sudo bash
```

The installer asks for domains, server IP, proxy port, the first source name, web-panel password and a few optional settings.

Before changing the system it shows a summary, so you can stop if something is wrong.

---

## After installation

Open your panel address, for example:

```text
https://panel.example.com/
```

Use the Links page to add the proxy to Telegram, then check active users and statistics in the panel.

For a full health check:

```bash
mtpadmin doctor
```

A healthy installation ends with `RESULT: HEALTHY`.

---

## Updates

The normal way is through the web panel under **Operations → Updates**.

If the panel is unavailable:

```bash
curl -fsSL https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main/update.sh | sudo bash
```

Closing the browser tab does not stop an update already running on the server.

---

## 0.12.5 public testing

Updates of MTPADMIN, TeleMT and Telegram WEB Proxy, preservation of the existing WEB Proxy link, and the final health check have all been tested on a real server.

We are especially looking for **clean installations on new servers**.

If you hit a problem, send the safe output of:

```bash
mtpadmin doctor
systemctl --failed --no-pager
```

Do not publish passwords, proxy secrets or key files.

---

## Important note

**MTPADMIN is not a full VPN.** It is a proxy specifically for Telegram. After installation, almost all day-to-day management can be done from the web panel.

[Help and discussion](https://t.me/boss_of_this_vpn)