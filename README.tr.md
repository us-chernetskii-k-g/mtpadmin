# MTPADMIN — web panelli kişisel Telegram Proxy

[Русский](README.md) · [Українська](README.uk.md) · [فارسی](README.fa.md) · [简体中文](README.zh-CN.md) · [Türkçe](README.tr.md) · [العربية](README.ar.md) · [English](README.en.md)

**MTPADMIN, normal bir sunucuda kendi Telegram proxy'nizi kurmanıza ve daha sonra basit bir web panelinden yönetmenize yardımcı olur.**

Güncel sürüm: **0.12.5**  
Durum: **açık test**. Çalışan bir kurulumun güncellenmesi gerçek bir sunucuda test edildi. Şimdi özellikle farklı Debian/Ubuntu sunucularında sıfırdan kurulum geri bildirimlerine ihtiyaç var.

Kurulumdan sonra iki bağlantı yöntemi kullanılabilir:

- normal **MTProto Proxy**;
- HTTPS üzerinden çalışan **Telegram WEB Proxy**.

Panelde aktif kullanıcıları, istatistikleri, ülke ve ağ bilgisini görebilir; arkadaşlar, site veya reklam için ayrı bağlantılar oluşturabilir; sistemi kontrol edip güncelleyebilirsiniz.

> Bir kez kurun; sonrasında günlük işlerin çoğu tarayıcıdan yapılır.

[VPN BOSS](https://brakonder.ru) · [Telegram destek ve sohbet](https://t.me/boss_of_this_vpn)

---

## Neler yapabilir?

- hazır bağlantı ve QR kodu oluşturur;
- aktif bağlantıları gösterir;
- günlük ve kaynak bazlı istatistik tutar;
- istemcinin ülke, şehir ve ağ bilgisini gösterir;
- arkadaşlar, web sitesi veya reklam için ayrı bağlantılar oluşturur;
- proxy ve panelin durumunu kontrol eder;
- MTPADMIN, TeleMT ve Telegram WEB Proxy güncellemelerini tarayıcıdan yapar;
- normal güncellemede mevcut WEB Proxy bağlantısını korur;
- panel telefonun ana ekranına uygulama gibi eklenebilir;
- Scanner Guard şüpheli etkinliği gösterir. Otomatik engelleme varsayılan olarak kapalıdır.

Konum bilgisi kendi sunucunuzda işlenir. İstemci IP listesi ülke veya şehir belirlemek için harici bir servise gönderilmez.

---

## Kurulumdan önce

Temiz bir sunucu önerilir:

- **Debian veya Ubuntu**;
- x86-64 veya ARM64;
- genel IPv4;
- `root` veya `sudo` erişimi;
- en az **1 GB boş disk alanı**;
- bu sunucuya yönlendirilmiş alan adları.

En kolay düzen üç alan adıdır:

```text
proxy.example.com       — normal MTProto Proxy
panel.example.com       — MTPADMIN web paneli
webproxy.example.com    — Telegram WEB Proxy
```

Panel ve WEB Proxy için `80` ve `443` portları erişilebilir olmalıdır. Normal MTProto için de seçtiğiniz port, örneğin `8443`, açık olmalıdır.

MTPADMIN SSH ayarlarınızı değiştirmez ve tüm güvenlik duvarınızı yeniden yazmaz. Yalnızca WEB Proxy'nin iç servislerini dışarıdan kapatmak için ayrı bir koruma kuralı ekler.

---

## Kurulum

SSH ile sunucuya bağlanın ve çalıştırın:

```bash
curl -fsSL https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main/install.sh | sudo bash
```

Kurulum sihirbazı alan adlarını, sunucu IP'sini, portu, ilk kaynak adını, panel şifresini ve gerekli diğer seçenekleri sorar.

Sistemde değişiklik yapılmadan önce bir özet gösterilir. Hatalı bir bilgi varsa kurulumu iptal edebilirsiniz.

---

## Kurulumdan sonra

Panel adresinizi açın:

```text
https://panel.example.com/
```

Bağlantılar bölümünden proxy'yi Telegram'a ekleyin. Aktif kullanıcıları ve istatistikleri panelden görebilirsiniz.

Tam kontrol için:

```bash
mtpadmin doctor
```

Her şey yolundaysa sonunda `RESULT: HEALTHY` görünür.

---

## Güncelleme

Ana yöntem web panelindeki **İşlemler → Güncellemeler** bölümüdür.

Panel kullanılamıyorsa:

```bash
curl -fsSL https://raw.githubusercontent.com/us-chernetskii-k-g/mtpadmin/main/update.sh | sudo bash
```

Tarayıcı sekmesini kapatmanız sunucudaki güncellemeyi durdurmaz.

---

## 0.12.5 açık test

Gerçek sunucuda MTPADMIN, TeleMT ve Telegram WEB Proxy güncellemeleri, mevcut WEB Proxy bağlantısının korunması ve son sağlık kontrolü test edildi.

Şimdi özellikle **temiz bir sunucuda sıfırdan kurulum** geri bildirimleri arıyoruz.

Sorun yaşarsanız şu güvenli çıktıları paylaşın:

```bash
mtpadmin doctor
systemctl --failed --no-pager
```

Parola, proxy secret veya anahtar dosyalarını paylaşmayın.

---

## Kısa not

**MTPADMIN tam bir VPN değildir.** Yalnızca Telegram için proxy sağlar. Kurulumdan sonra günlük yönetimin neredeyse tamamı web panelinden yapılabilir.

[Destek ve sohbet](https://t.me/boss_of_this_vpn)