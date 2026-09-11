# MTPADMIN — 带网页面板的个人 Telegram Proxy

[Русский](README.md) · [Українська](README.uk.md) · [فارسی](README.fa.md) · [简体中文](README.zh-CN.md) · [Türkçe](README.tr.md) · [العربية](README.ar.md) · [English](README.en.md)

**MTPADMIN 可以帮助你在普通服务器上搭建自己的 Telegram 代理，并通过简单的网页面板进行管理。**

当前版本：**0.12.5**  
状态：**公开测试**。已有运行中的服务器完成了实际升级测试。现在最需要的是不同 Debian/Ubuntu 服务器上的全新安装反馈。

安装后可以使用两种连接方式：

- 普通 **MTProto Proxy**；
- 通过 HTTPS 工作的 **Telegram WEB Proxy**。

网页面板可以查看在线用户、统计数据、国家和网络信息，也可以为朋友、网站或推广创建不同的连接入口，并直接检查和更新服务。

> 安装一次，以后大多数操作都可以在浏览器里完成。

[VPN BOSS](https://brakonder.ru) · [Telegram 帮助与讨论](https://t.me/boss_of_this_vpn)

---

## MTPADMIN 可以做什么？

- 自动生成连接链接和二维码；
- 显示当前在线连接；
- 记录每天和不同来源的统计数据；
- 显示用户所在国家、城市和网络；
- 为朋友、网站或推广创建不同入口；
- 检查代理和网页面板是否正常；
- 在浏览器中分别更新 MTPADMIN、TeleMT 和 Telegram WEB Proxy；
- 正常更新时保留已经发给用户的 WEB Proxy 链接；
- 可以把网页面板添加到手机主屏幕；
- Scanner Guard 可以查看可疑访问，自动封禁默认关闭。

地理信息在你自己的服务器上处理，不会为了查询国家或城市把客户端 IP 列表发送给外部服务。

---

## 安装前需要什么？

建议使用一台干净的服务器：

- **Debian 或 Ubuntu**；
- x86-64 或 ARM64；
- 公网 IPv4；
- `root` 或 `sudo` 权限；
- 至少 **1 GB 可用磁盘空间**；
- 已经解析到这台服务器的域名。

最简单的是准备三个域名：

```text
proxy.example.com       — 普通 MTProto Proxy
panel.example.com       — MTPADMIN 网页面板
webproxy.example.com    — Telegram WEB Proxy
```

网页面板和 WEB Proxy 需要外网可以访问 `80` 和 `443` 端口。普通 MTProto 还需要开放你选择的端口，例如 `8443`。

MTPADMIN 不会修改你的 SSH 设置，也不会重写整个防火墙。它只会为 WEB Proxy 的内部服务增加单独的保护规则，避免内部端口直接暴露在公网。

---

## 安装

通过 SSH 登录服务器并执行：

```bash
curl -fsSL https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main/install.sh | sudo bash
```

安装向导会询问域名、服务器 IP、端口、第一个来源名称、网页面板密码以及其他必要选项。

真正修改系统之前会先显示一次汇总。如果填写有误，可以直接取消。

---

## 安装完成后

打开你的面板地址，例如：

```text
https://panel.example.com/
```

在“链接”页面把代理加入 Telegram，然后可以查看在线用户和统计数据。更新在“操作 → 更新”中完成。

完整健康检查：

```bash
mtpadmin doctor
```

如果一切正常，最后会看到：`RESULT: HEALTHY`。

---

## 更新

推荐直接在网页面板中更新。

如果网页面板暂时无法访问，可以执行：

```bash
curl -fsSL https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main/update.sh | sudo bash
```

即使关闭浏览器标签页，服务器上的更新任务也会继续运行。

---

## 0.12.5 公开测试

我们已经在真实服务器上测试了 MTPADMIN、TeleMT 和 Telegram WEB Proxy 的升级、WEB Proxy 链接保留以及最终健康检查。

现在最需要的是 **全新服务器从零开始安装** 的反馈。

遇到问题时，请提供以下安全输出：

```bash
mtpadmin doctor
systemctl --failed --no-pager
```

请不要公开密码、代理 secret 或密钥文件。

---

## 注意

**MTPADMIN 不是完整 VPN。** 它只为 Telegram 提供代理。安装完成后，大多数日常管理都可以通过网页面板完成。

[帮助与讨论](https://t.me/boss_of_this_vpn)