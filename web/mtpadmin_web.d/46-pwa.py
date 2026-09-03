# MTPADMIN 0.12.2 mobile application layer.
# Adds a same-origin web-app manifest, a network-only service worker and a
# mobile-first installation screen. No admin HTML or API response is cached.

_PWA_MANIFEST = json.dumps({
    'id': '/',
    'name': 'MTPADMIN',
    'short_name': 'MTPADMIN',
    'description': 'Управление Telegram Proxy',
    'lang': 'ru',
    'start_url': '/?pwa=1',
    'scope': '/',
    'display': 'standalone',
    'background_color': '#07101d',
    'theme_color': '#07101d',
    'icons': [
        {'src': '/pwa-icon-192.png', 'sizes': '192x192', 'type': 'image/png', 'purpose': 'any maskable'},
        {'src': '/pwa-icon-512.png', 'sizes': '512x512', 'type': 'image/png', 'purpose': 'any maskable'},
    ],
}, ensure_ascii=False, separators=(',', ':')).encode('utf-8')

_PWA_SW = b"""'use strict';
const VERSION='mtpadmin-0.12.2';
self.addEventListener('install', event => { self.skipWaiting(); });
self.addEventListener('activate', event => { event.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', event => {
  if (event.request.method !== 'GET') return;
  event.respondWith(fetch(event.request));
});
"""


def _pwa_icon_png(size):
    # Small generated PNG: no binary assets are required in the repository.
    # The icon is cached in memory after the first request.
    cache = globals().setdefault('_PWA_ICON_CACHE', {})
    if size in cache:
        return cache[size]
    import binascii
    import struct
    import zlib

    n = int(size)
    bg = (7, 16, 29, 255)
    blue = (37, 131, 255, 255)
    violet = (92, 92, 255, 255)
    white = (255, 255, 255, 255)
    pad = int(n * .13)
    inner = int(n * .22)
    stroke = max(4, int(n * .075))
    mid = n // 2
    raw = bytearray()
    for y in range(n):
        raw.append(0)
        for x in range(n):
            c = bg
            if pad <= x < n-pad and pad <= y < n-pad:
                c = blue
            if inner <= x < n-inner and inner <= y < n-inner:
                c = violet
            # Geometric M, intentionally simple and legible at launcher sizes.
            top = int(n * .33)
            bottom = int(n * .69)
            left = int(n * .32)
            right = int(n * .68)
            if top <= y <= bottom:
                if abs(x-left) <= stroke//2 or abs(x-right) <= stroke//2:
                    c = white
                rel = (y-top) / max(1, bottom-top)
                dl = left + int((mid-left) * min(1.0, rel * 1.15))
                dr = right - int((right-mid) * min(1.0, rel * 1.15))
                if y <= int(n * .55) and (abs(x-dl) <= stroke//2 or abs(x-dr) <= stroke//2):
                    c = white
            raw.extend(c)

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', binascii.crc32(kind + data) & 0xffffffff)

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', n, n, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    cache[size] = png
    return png


def _pwa_send(self, data, content_type, cache='no-store', extra=None):
    self.send_response(200)
    self.send_header('Content-Type', content_type)
    self.send_header('Cache-Control', cache)
    self.send_header('X-Content-Type-Options', 'nosniff')
    for k, v in (extra or {}).items():
        self.send_header(k, v)
    self.send_header('Content-Length', str(len(data)))
    self.end_headers()
    self.wfile.write(data)


_pwa_prev_do_GET = Handler.do_GET


def _pwa_do_GET(self):
    path = urllib.parse.urlsplit(self.path).path
    if path == '/manifest.webmanifest':
        _pwa_send(self, _PWA_MANIFEST, 'application/manifest+json; charset=utf-8')
        return
    if path == '/mtpadmin-sw.js':
        _pwa_send(self, _PWA_SW, 'application/javascript; charset=utf-8', extra={'Service-Worker-Allowed': '/'})
        return
    if path == '/pwa-icon-192.png':
        _pwa_send(self, _pwa_icon_png(192), 'image/png', cache='public, max-age=86400')
        return
    if path == '/pwa-icon-512.png':
        _pwa_send(self, _pwa_icon_png(512), 'image/png', cache='public, max-age=86400')
        return
    return _pwa_prev_do_GET(self)


Handler.do_GET = _pwa_do_GET


_PWA_HEAD = r'''
<link rel="manifest" href="/manifest.webmanifest">
<meta name="theme-color" content="#07101d">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="MTPADMIN">
<link rel="apple-touch-icon" href="/pwa-icon-192.png">
<style id="mtpadmin-pwa-style">
.m-pwa-sheet[hidden]{display:none!important}.m-pwa-sheet{position:fixed;inset:0;z-index:10000;display:grid;place-items:end center;background:rgba(1,7,14,.74);backdrop-filter:blur(10px);padding:18px}.m-pwa-card{width:min(520px,100%);border:1px solid #29425f;border-radius:26px;background:linear-gradient(165deg,#112036,#091523 72%);box-shadow:0 28px 90px rgba(0,0,0,.55);padding:24px;color:#f4f8ff}.m-pwa-head{display:flex;align-items:center;gap:15px;margin-bottom:18px}.m-pwa-logo{width:58px;height:58px;flex:0 0 58px;display:grid;place-items:center;clip-path:polygon(50% 0,94% 23%,94% 77%,50% 100%,6% 77%,6% 23%);background:linear-gradient(145deg,#2583ff,#5c5cff);font-size:28px;font-weight:900;color:white}.m-pwa-kicker{font-size:12px;color:#6caaff;font-weight:750;text-transform:uppercase;letter-spacing:.7px}.m-pwa-card h2{font-size:25px;margin:4px 0 0}.m-pwa-card p{color:#a6b6ca;line-height:1.5;margin:0 0 16px}.m-pwa-benefits{display:grid;gap:8px;margin:0 0 20px;padding:0;list-style:none}.m-pwa-benefits li{display:flex;gap:9px;align-items:flex-start;color:#dbe6f4}.m-pwa-benefits li:before{content:'✓';color:#24d17e;font-weight:900}.m-pwa-actions{display:grid;gap:10px}.m-pwa-install,.m-pwa-continue,.m-pwa-menu{font:inherit;cursor:pointer}.m-pwa-install{border:0;border-radius:14px;padding:14px 18px;background:linear-gradient(135deg,#2583ff,#5564ff);color:#fff;font-weight:800;font-size:16px;box-shadow:0 12px 30px rgba(37,131,255,.26)}.m-pwa-continue{border:1px solid #29425f;border-radius:14px;padding:12px 18px;background:#101d2f;color:#b7c6d9;font-weight:650}.m-pwa-help{display:none;margin:14px 0 0;padding:14px;border-radius:14px;background:#0a1727;border:1px solid #203753;color:#c9d6e6;line-height:1.55}.m-pwa-help.show{display:block}.m-pwa-help b{color:#fff}.m-pwa-menu{display:flex;width:100%;align-items:center;gap:10px;min-height:42px;padding:10px 12px;border:1px solid transparent;border-radius:11px;background:transparent;color:#acbad0;text-align:left}.m-pwa-menu:hover{background:#111f33;color:#edf5ff;border-color:#203754}.m-pwa-menu:before{content:'⇩';width:18px;text-align:center;color:#69aaff;font-size:17px}.m-pwa-installed .m-pwa-menu{display:none!important}
@media(max-width:900px){.m-pwa-sheet{padding:max(12px,env(safe-area-inset-top)) 12px max(12px,env(safe-area-inset-bottom));align-items:end}.m-pwa-card{border-radius:24px;padding:22px 20px}.m-pwa-card h2{font-size:23px}body.mtp-modern #live-root{padding-bottom:calc(104px + env(safe-area-inset-bottom))!important}body.mtp-modern .nav{padding-bottom:env(safe-area-inset-bottom)!important}}
@media(display-mode:standalone){body.mtp-modern .top{padding-top:env(safe-area-inset-top)!important;height:calc(74px + env(safe-area-inset-top))}body.mtp-modern .nav{padding-bottom:env(safe-area-inset-bottom)!important}.m-pwa-menu{display:none!important}}
</style>
<script>
(function(){
'use strict';
var deferredPrompt=null;
var DISMISS_KEY='mtpadmin-pwa-dismiss-until';
var DISMISS_MS=14*24*60*60*1000;
function standalone(){return window.matchMedia('(display-mode: standalone)').matches||window.navigator.standalone===true;}
function mobile(){return window.matchMedia('(max-width: 900px)').matches||/Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent);}
function ios(){return /iPhone|iPad|iPod/i.test(navigator.userAgent)&&!window.MSStream;}
function dismissed(){try{return Number(localStorage.getItem(DISMISS_KEY)||0)>Date.now();}catch(e){return false;}}
function rememberDismiss(){try{localStorage.setItem(DISMISS_KEY,String(Date.now()+DISMISS_MS));}catch(e){}}
function clearDismiss(){try{localStorage.removeItem(DISMISS_KEY);}catch(e){}}
function sheet(){return document.getElementById('m-pwa-sheet');}
function hideSheet(){var x=sheet();if(x)x.hidden=true;}
function showHelp(text){var h=document.getElementById('m-pwa-help');if(!h)return;h.innerHTML=text;h.classList.add('show');}
function showSheet(force){if(standalone())return;if(!force&&(!mobile()||dismissed()))return;var x=sheet();if(x)x.hidden=false;}
async function install(){
  if(standalone()){hideSheet();return;}
  if(deferredPrompt){
    var p=deferredPrompt;deferredPrompt=null;
    p.prompt();
    try{var choice=await p.userChoice;if(choice&&choice.outcome==='accepted'){clearDismiss();hideSheet();}}catch(e){}
    return;
  }
  if(ios()){
    showHelp('<b>На iPhone:</b> нажмите кнопку «Поделиться» в браузере, затем выберите «На экран Домой» и подтвердите добавление.');
  }else{
    showHelp('<b>Если окно установки не появилось:</b> откройте меню браузера и выберите «Установить приложение» или «Добавить на главный экран».');
  }
}
function addMenuButton(){
  if(standalone())return;
  var host=document.querySelector('.m-side-links');
  if(!host||document.getElementById('m-pwa-menu'))return;
  var b=document.createElement('button');b.type='button';b.id='m-pwa-menu';b.className='m-pwa-menu';b.textContent='Установить приложение';b.addEventListener('click',function(){showSheet(true);});host.appendChild(b);
}
window.addEventListener('beforeinstallprompt',function(e){e.preventDefault();deferredPrompt=e;});
window.addEventListener('appinstalled',function(){clearDismiss();hideSheet();document.documentElement.classList.add('m-pwa-installed');deferredPrompt=null;});
document.addEventListener('DOMContentLoaded',function(){
  if('serviceWorker' in navigator){navigator.serviceWorker.register('/mtpadmin-sw.js',{scope:'/'}).catch(function(){});}
  var installBtn=document.getElementById('m-pwa-install');if(installBtn)installBtn.addEventListener('click',install);
  var continueBtn=document.getElementById('m-pwa-continue');if(continueBtn)continueBtn.addEventListener('click',function(){rememberDismiss();hideSheet();});
  addMenuButton();
  if(!standalone()&&mobile()&&!dismissed()){setTimeout(function(){showSheet(false);},250);}
});
})();
</script>
'''

_PWA_BODY = r'''
<div id="m-pwa-sheet" class="m-pwa-sheet" hidden role="dialog" aria-modal="true" aria-labelledby="m-pwa-title">
  <div class="m-pwa-card">
    <div class="m-pwa-head"><div class="m-pwa-logo">M</div><div><div class="m-pwa-kicker">Приложение для телефона</div><h2 id="m-pwa-title">Установить MTPADMIN</h2></div></div>
    <p>На телефоне панель удобнее открывать как отдельное приложение — без адресной строки и лишних элементов браузера.</p>
    <ul class="m-pwa-benefits"><li>Отдельный значок на главном экране</li><li>Полноэкранная панель управления</li><li>Данные не сохраняются для работы без сети и всегда берутся с вашего сервера</li></ul>
    <div class="m-pwa-actions"><button type="button" id="m-pwa-install" class="m-pwa-install">Установить приложение</button><button type="button" id="m-pwa-continue" class="m-pwa-continue">Продолжить в браузере</button></div>
    <div id="m-pwa-help" class="m-pwa-help"></div>
  </div>
</div>
'''

_pwa_base_page_template = page_template


def page_template(title, body, user, active='dashboard', refresh=None, message=''):
    doc = _pwa_base_page_template(title, body, user, active=active, refresh=refresh, message=message)
    if 'rel="manifest" href="/manifest.webmanifest"' not in doc and '</head>' in doc:
        doc = doc.replace('</head>', _PWA_HEAD + '\n</head>', 1)
    if 'id="m-pwa-sheet"' not in doc and '</body>' in doc:
        doc = doc.replace('</body>', _PWA_BODY + '\n</body>', 1)
    return doc
