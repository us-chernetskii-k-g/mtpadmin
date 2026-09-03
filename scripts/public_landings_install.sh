#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

STATE='/etc/mtpadmin/state.env'
CADDYFILE='/etc/caddy/Caddyfile'
ADMIN_SITE='/srv/mtpadmin-public'
WEBPROXY_SITE='/srv/tproxy-site'
TPROXY_CFG='/etc/tproxy-server/config.json'
BEGIN='# BEGIN MTPADMIN WEB - managed by mtpadmin'
END='# END MTPADMIN WEB - managed by mtpadmin'
MODE=${1:-all}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ok(){ echo "[PASS] $*"; }
info(){ echo "[INFO] $*"; }
warn(){ echo "[WARN] $*"; }
die(){ echo "[FAIL] $*" >&2; exit 1; }
[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Landing installer требует root.'

cat > "$TMP/admin-index.html" <<'HTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><title>BRAKONDER Cloud</title><style>
:root{--bg:#06101d;--panel:#0c1a2d;--line:#183452;--text:#f5f8ff;--muted:#9eafc5;--blue:#3282ff;--cyan:#38bdf8}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;font-family:Inter,ui-sans-serif,system-ui,-apple-system,Segoe UI,sans-serif;background:radial-gradient(circle at 73% 18%,#0c3260 0,transparent 28%),linear-gradient(145deg,#050b14,#081526 55%,#06101d);color:var(--text);min-height:100vh}.wrap{max-width:1240px;margin:auto;padding:22px 28px 40px}.nav{display:flex;align-items:center;justify-content:space-between;padding:14px 18px;border:1px solid #142a45;border-radius:18px;background:#07111fcf;backdrop-filter:blur(16px)}.brand{display:flex;align-items:center;gap:12px;font-weight:800;font-size:20px}.logo{width:34px;height:34px;border-radius:10px;background:linear-gradient(145deg,#3b82f6,#7c3aed);display:grid;place-items:center;box-shadow:0 0 28px #2563eb55}.logo:after{content:'B';font-weight:900}.brand b{color:#4da3ff}.nav a,.btn{color:var(--text);text-decoration:none}.navlinks{display:flex;gap:24px;align-items:center;color:var(--muted)}.navlinks a{color:var(--muted)}.hero{display:grid;grid-template-columns:1.08fr .92fr;gap:64px;align-items:center;padding:78px 48px 54px}.badge{display:inline-flex;align-items:center;gap:9px;border:1px solid #1e4f7c;border-radius:999px;padding:8px 12px;color:#77baff;background:#0b2038}.badge i{width:8px;height:8px;border-radius:50%;background:#32d399;box-shadow:0 0 14px #32d399}.hero h1{font-size:clamp(38px,5vw,65px);line-height:1.03;margin:22px 0 20px;letter-spacing:-.04em}.hero h1 span{color:#4b98ff}.hero p{font-size:18px;line-height:1.7;color:var(--muted);max-width:650px}.actions{display:flex;gap:14px;margin:30px 0 18px;flex-wrap:wrap}.btn{display:inline-flex;align-items:center;justify-content:center;padding:13px 22px;border-radius:12px;border:1px solid #28517c;font-weight:750;background:#0a1729}.btn.primary{background:linear-gradient(135deg,#2776ed,#3e91ff);border-color:#4c9aff;box-shadow:0 12px 32px #0b5ec344}.trust{font-size:13px;color:#8297b0}.visual{min-height:360px;display:grid;place-items:center;position:relative}.cloud{width:min(100%,480px);aspect-ratio:1.3;border:2px solid #3282ff;border-radius:48% 48% 34% 34%;position:relative;box-shadow:0 0 55px #2576ff55,inset 0 0 45px #0c66de22;background:linear-gradient(145deg,#0c1b30,#071120)}.cloud:before,.cloud:after{content:'';position:absolute;border:2px solid #3282ff;background:#0a1729;border-bottom:0}.cloud:before{width:42%;height:48%;left:8%;top:-19%;border-radius:50% 50% 0 0}.cloud:after{width:50%;height:60%;right:7%;top:-30%;border-radius:50% 50% 0 0}.folder{position:absolute;z-index:3;width:170px;height:112px;background:linear-gradient(145deg,#103e78,#0b2243);border:1px solid #3a8fff;border-radius:15px;left:50%;top:50%;transform:translate(-62%,-35%);box-shadow:0 22px 50px #0008}.folder:before{content:'';position:absolute;width:70px;height:24px;left:12px;top:-16px;border-radius:9px 9px 0 0;background:#174d8e;border:1px solid #3a8fff}.lock{position:absolute;z-index:4;right:23%;bottom:17%;width:72px;height:82px;border-radius:15px;background:linear-gradient(#257ff1,#0c3970);border:1px solid #5aa4ff;box-shadow:0 15px 40px #0d5dd966}.lock:before{content:'';position:absolute;width:39px;height:38px;border:7px solid #49a0ff;border-bottom:0;border-radius:24px 24px 0 0;left:10px;top:-31px}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:10px 20px 48px}.card{border:1px solid var(--line);background:linear-gradient(145deg,#0b192b,#081321);border-radius:17px;padding:22px;min-height:150px}.ico{width:46px;height:46px;border-radius:12px;background:#0d2d58;display:grid;place-items:center;font-size:22px;margin-bottom:16px}.card h3{margin:0 0 8px;font-size:17px}.card p{margin:0;color:var(--muted);line-height:1.55;font-size:14px}.section{text-align:center;margin:24px 20px 22px}.section h2{font-size:30px;margin-bottom:8px}.section h2 span{color:#438fff}.section p{color:var(--muted)}.benefits{grid-template-columns:repeat(3,1fr);margin-bottom:58px}.footer{border-top:1px solid #14273d;padding:28px 10px;display:flex;justify-content:space-between;color:#758aa5;font-size:13px}.footer strong{color:#dbe7f8}@media(max-width:850px){.navlinks{display:none}.hero{grid-template-columns:1fr;padding:52px 12px 30px;gap:30px}.visual{min-height:280px}.grid,.benefits{grid-template-columns:1fr 1fr}.wrap{padding:14px}.footer{flex-direction:column;gap:8px}}@media(max-width:540px){.grid,.benefits{grid-template-columns:1fr}.hero h1{font-size:42px}.visual{transform:scale(.82);margin:-25px}.actions .btn{width:100%}}
</style></head><body><main class="wrap"><nav class="nav"><div class="brand"><span class="logo"></span>BRAKONDER <b>Cloud</b></div><div class="navlinks"><a href="#service">О сервисе</a><a href="#features">Возможности</a><a href="#benefits">Преимущества</a><a class="btn primary" href="/operations">Войти</a></div></nav><section class="hero" id="service"><div><span class="badge"><i></i> Надёжно. Безопасно. Для работы.</span><h1>Безопасное облачное <span>хранилище</span> и корпоративная <span>почта</span></h1><p>Единое пространство для рабочих файлов, обмена документами и корпоративных коммуникаций. Доступ с любого устройства и аккуратная организация данных.</p><div class="actions"><a class="btn primary" href="/operations">Войти в кабинет →</a><a class="btn" href="#features">Возможности</a></div><div class="trust">◈ Доступ к кабинету предоставляется авторизованным пользователям.</div></div><div class="visual"><div class="cloud"><div class="folder"></div><div class="lock"></div></div></div></section><section class="grid" id="features"><article class="card"><div class="ico">▰</div><h3>Хранение файлов</h3><p>Удобная организация рабочих документов и материалов в одном пространстве.</p></article><article class="card"><div class="ico">✉</div><h3>Почта для команды</h3><p>Корпоративные коммуникации в привычном и аккуратном формате.</p></article><article class="card"><div class="ico">▣</div><h3>Доступ с устройств</h3><p>Работайте из офиса, дома или в дороге через современный браузер.</p></article><article class="card"><div class="ico">◇</div><h3>Защита данных</h3><p>Контроль доступа и инфраструктура для безопасной работы с информацией.</p></article></section><div class="section" id="benefits"><h2>Почему выбирают <span>нас</span></h2><p>Простой доступ к рабочему пространству без лишней сложности.</p></div><section class="grid benefits"><article class="card"><h3>⚡ Быстрый запуск</h3><p>Вход в рабочее пространство занимает минимум времени.</p></article><article class="card"><h3>▦ Простой интерфейс</h3><p>Понятная структура для ежедневной работы.</p></article><article class="card"><h3>◉ Доступ по приглашению</h3><p>Сервис предназначен для авторизованных пользователей и команд.</p></article></section><footer class="footer"><div><strong>BRAKONDER Cloud</strong> · рабочее цифровое пространство</div><div>© 2026 BRAKONDER</div></footer></main></body></html>
HTML

cat > "$TMP/webproxy-index.html" <<'HTML'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><title>BRAKONDER Access</title><style>
:root{--bg:#06111f;--panel:#0c1b2e;--line:#173451;--text:#f5f8ff;--muted:#a1b1c5;--blue:#3b82f6;--green:#2dd4a2}*{box-sizing:border-box}body{margin:0;font-family:Inter,ui-sans-serif,system-ui,-apple-system,Segoe UI,sans-serif;color:var(--text);background:radial-gradient(circle at 78% 20%,#0b355d 0,transparent 30%),linear-gradient(145deg,#050c15,#081728 58%,#06111f);min-height:100vh}.wrap{max-width:1240px;margin:auto;padding:22px 28px 42px}.nav{display:flex;justify-content:space-between;align-items:center;border:1px solid #142c47;border-radius:17px;padding:14px 18px;background:#07121fcf}.brand{font-size:20px;font-weight:850;display:flex;gap:10px;align-items:center}.mark{width:34px;height:34px;display:grid;place-items:center;border-radius:10px;background:linear-gradient(145deg,#0ea5e9,#2563eb);box-shadow:0 0 28px #168ee455}.brand span:last-child{color:var(--green)}.links{display:flex;align-items:center;gap:26px}.links a,.button{color:var(--text);text-decoration:none}.links a{color:var(--muted)}.hero{display:grid;grid-template-columns:1fr 1fr;gap:56px;align-items:center;padding:72px 10px 50px}.badge{display:inline-flex;align-items:center;gap:9px;padding:8px 12px;border:1px solid #155245;border-radius:999px;color:#7de7c8;background:#09251f}.dot{width:8px;height:8px;border-radius:50%;background:#2dd4a2;box-shadow:0 0 14px #2dd4a2}.hero h1{font-size:clamp(40px,5vw,67px);line-height:1.05;letter-spacing:-.045em;margin:22px 0}.hero p{font-size:18px;color:var(--muted);line-height:1.7;max-width:620px}.buttons{display:flex;gap:14px;margin-top:30px}.button{padding:14px 22px;border-radius:12px;border:1px solid #285077;background:#0a1728;font-weight:750}.button.primary{background:linear-gradient(135deg,#286fdc,#3f8df6);border-color:#569cff}.browser{height:360px;border:2px solid #2f72cd;border-radius:24px;background:#071320;box-shadow:0 0 54px #1f63c044;overflow:hidden}.bar{height:55px;border-bottom:1px solid #173451;display:flex;align-items:center;gap:8px;padding:0 18px}.bar i{width:10px;height:10px;border-radius:50%;background:#ff6b6b}.bar i:nth-child(2){background:#f6c84f}.bar i:nth-child(3){background:#2dd4a2}.address{height:25px;border-radius:20px;background:#0d1e31;margin-left:25px;flex:1}.dash{display:grid;grid-template-columns:105px 1fr;gap:18px;height:305px;padding:20px}.side{border-radius:14px;background:#0b1b2e}.content{display:grid;grid-template-columns:repeat(3,1fr);grid-template-rows:90px 1fr;gap:14px}.secure{grid-column:1/4;border:1px solid #1b4d5b;background:#0b2430;border-radius:14px;padding:22px;color:#71e5c1;font-weight:700}.tile{border:1px solid #173451;border-radius:14px;background:#0b192a}.features{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:10px 0 42px}.card{border:1px solid var(--line);border-radius:17px;padding:22px;background:linear-gradient(145deg,#0b192a,#081321)}.ico{font-size:24px;width:48px;height:48px;border-radius:50%;display:grid;place-items:center;background:#0d2e58;margin-bottom:14px}.card h3{margin:0 0 8px;font-size:17px}.card p{margin:0;color:var(--muted);line-height:1.55;font-size:14px}.why{border:1px solid var(--line);border-radius:20px;padding:26px;margin-top:30px}.why h2{text-align:center;margin:0 0 26px}.whygrid{display:grid;grid-template-columns:repeat(3,1fr);gap:20px}.mini{padding:10px 18px}.mini strong{display:block;margin-bottom:8px}.mini span{color:var(--muted);font-size:14px;line-height:1.5}.footer{margin-top:38px;padding:28px 0;border-top:1px solid #142a42;color:#748aa5;display:flex;justify-content:space-between;font-size:13px}@media(max-width:850px){.links a{display:none}.hero{grid-template-columns:1fr}.features{grid-template-columns:1fr 1fr}.wrap{padding:14px}.browser{height:300px}.whygrid{grid-template-columns:1fr}}@media(max-width:540px){.features{grid-template-columns:1fr}.hero h1{font-size:42px}.buttons{flex-direction:column}.button{text-align:center}.browser{height:260px}.dash{grid-template-columns:70px 1fr}.footer{flex-direction:column;gap:8px}}
</style></head><body><main class="wrap"><nav class="nav"><div class="brand"><span class="mark">B</span>BRAKONDER <span>Access</span></div><div class="links"><a href="#service">О сервисе</a><a href="#help">Помощь</a><a href="#contact">Контакты</a><a class="button primary" href="#access">Открыть кабинет</a></div></nav><section class="hero" id="service"><div><div class="badge"><span class="dot"></span> Безопасный доступ из любого места</div><h1>Защищённый веб-доступ для работы из любого места</h1><p>Работайте там, где удобно. Сервис открывается прямо в браузере и предоставляет единое защищённое пространство для рабочих ресурсов и команд.</p><div class="buttons"><a class="button primary" href="#access">Открыть кабинет →</a><a class="button" href="#help">Запросить доступ</a></div></div><div class="browser"><div class="bar"><i></i><i></i><i></i><div class="address"></div></div><div class="dash"><div class="side"></div><div class="content"><div class="secure">◆ Соединение защищено<br><small>Доступ к рабочему пространству</small></div><div class="tile"></div><div class="tile"></div><div class="tile"></div></div></div></div></section><section class="features"><article class="card"><div class="ico">◎</div><h3>Работа в браузере</h3><p>Доступ к рабочим ресурсам без лишних действий.</p></article><article class="card"><div class="ico">⇩</div><h3>Без установки</h3><p>Откройте адрес в современном браузере и продолжайте работу.</p></article><article class="card"><div class="ico">ϟ</div><h3>Стабильное соединение</h3><p>Инфраструктура рассчитана на ежедневное использование.</p></article><article class="card"><div class="ico">◇</div><h3>Контроль доступа</h3><p>Доступ предоставляется только авторизованным пользователям.</p></article></section><section class="why" id="access"><h2>Почему это удобно</h2><div class="whygrid"><div class="mini"><strong>→ Быстрый вход</strong><span>Минимум шагов до рабочего пространства.</span></div><div class="mini"><strong>▦ Привычный интерфейс</strong><span>Современная веб-среда без лишней сложности.</span></div><div class="mini"><strong>♙ Для команды</strong><span>Подходит для сотрудников и распределённых рабочих групп.</span></div></div></section><footer class="footer" id="help"><div>© 2026 BRAKONDER Access</div><div id="contact">Сервис доступен по приглашению</div></footer></main></body></html>
HTML

install -d -m 0755 -o root -g root "$WEBPROXY_SITE"
if [[ -f "$TPROXY_CFG" ]]; then
  mode=$(python3 - "$TPROXY_CFG" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1],encoding='utf-8'))
except Exception:
    print('unknown'); raise SystemExit
if d.get('public_dir') == '/srv/tproxy-site': print('managed-static')
elif d.get('public_upstream'): print('custom-upstream')
else: print('other')
PY
)
  if [[ "$mode" == managed-static ]]; then
    install -m 0644 -o root -g root "$TMP/webproxy-index.html" "$WEBPROXY_SITE/index.html"
    ok 'Публичная заглушка WEB Proxy установлена'
  else
    warn "WEB Proxy использует $mode; пользовательский public upstream/site не изменён."
  fi
fi

[[ "$MODE" == '--webproxy-only' ]] && exit 0
[[ -f "$CADDYFILE" ]] || die 'Caddyfile не найден.'
command -v caddy >/dev/null 2>&1 || die 'Caddy не найден.'
install -d -m 0755 -o root -g root "$ADMIN_SITE"
install -m 0644 -o root -g root "$TMP/admin-index.html" "$ADMIN_SITE/index.html"
cp -a "$CADDYFILE" "$TMP/Caddyfile.before"

python3 - "$CADDYFILE" "$TMP/Caddyfile.new" "$BEGIN" "$END" <<'PY'
from pathlib import Path
import re,sys
src,dst,begin,end=sys.argv[1:]
text=Path(src).read_text(encoding='utf-8')
start=text.find(begin); stop=text.find(end,start+len(begin))
if start<0 or stop<0: raise SystemExit('managed MTPADMIN Caddy block not found')
stop += len(end)
block=text[start:stop]
host_m=re.search(r'(?m)^\s*([A-Za-z0-9.-]+)\s*\{\s*$',block)
auth_m=re.search(r'(?ms)^\s*(basic_auth|basicauth)\s*\{\s*\n\s*([^\s{}]+)\s+([^\s{}]+)\s*\n\s*\}',block)
port_m=re.search(r'(?m)^\s*reverse_proxy\s+127\.0\.0\.1:(\d+)\s*\{',block)
if not (host_m and auth_m and port_m):
    raise SystemExit('managed MTPADMIN Caddy block has unexpected structure')
host=host_m.group(1); directive,user,pwhash=auth_m.group(1),auth_m.group(2),auth_m.group(3); port=port_m.group(1)
replacement=f'''{begin}\n{host} {{\n    encode zstd gzip\n\n    @anonymous_root {{\n        path /\n        not header Authorization *\n    }}\n    handle @anonymous_root {{\n        root * /srv/mtpadmin-public\n        file_server\n        header {{\n            X-Content-Type-Options "nosniff"\n            X-Frame-Options "DENY"\n            Referrer-Policy "no-referrer"\n            Permissions-Policy "camera=(), microphone=(), geolocation=()"\n            -Server\n        }}\n    }}\n\n    handle {{\n        {directive} {{\n            {user} {pwhash}\n        }}\n        header {{\n            X-Content-Type-Options "nosniff"\n            X-Frame-Options "DENY"\n            Referrer-Policy "no-referrer"\n            Permissions-Policy "camera=(), microphone=(), geolocation=()"\n            Cache-Control "no-store"\n            -Server\n        }}\n        reverse_proxy 127.0.0.1:{port} {{\n            header_up X-MTPADMIN-User {{http.auth.user.id}}\n            header_up -Authorization\n        }}\n    }}\n\n    log {{\n        output file /var/log/caddy/mtpadmin-access.log {{\n            roll_size 10MiB\n            roll_keep 5\n            roll_keep_for 168h\n        }}\n    }}\n}}\n{end}'''
Path(dst).write_text(text[:start]+replacement+text[stop:],encoding='utf-8')
print(host)
PY

caddy fmt --overwrite "$TMP/Caddyfile.new" >/dev/null 2>&1 || die 'Caddy landing candidate format failed.'
caddy validate --config "$TMP/Caddyfile.new" --adapter caddyfile >/dev/null 2>&1 || die 'Caddy landing candidate validate failed; рабочий конфиг не изменён.'
backup="/var/backups/mtpadmin/Caddyfile-before-public-landing-$(date +%Y%m%d-%H%M%S)"
install -d -m 0700 /var/backups/mtpadmin
cp -a "$CADDYFILE" "$backup"
install -m 0644 -o root -g root "$TMP/Caddyfile.new" "$CADDYFILE"
if ! systemctl reload caddy; then
  cp -a "$backup" "$CADDYFILE"
  systemctl reload caddy || true
  die 'Caddy reload failed; предыдущий конфиг восстановлен.'
fi
ok 'Публичная заглушка веб-домена установлена; защищённые маршруты MTPADMIN сохранены'
