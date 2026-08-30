# MTPADMIN 0.8.1 world basemap extension.
# The browser never contacts Wikimedia: the backend caches the CC0 basemap
# locally and serves it through the authenticated MTPADMIN origin.
import os as _wm_os
import re as _wm_re
import urllib.request as _wm_request

_WM_CACHE=Path('/var/lib/mtpadmin/world-map-equirectangular.png')
_WM_URL='https://upload.wikimedia.org/wikipedia/commons/thumb/5/51/BlankMap-Equirectangular.svg/960px-BlankMap-Equirectangular.svg.png'
_WM_MAX=2_000_000


def _wm_valid():
    try:
        return _WM_CACHE.is_file() and _WM_CACHE.stat().st_size > 10_000 and _WM_CACHE.read_bytes()[:8] == b'\x89PNG\r\n\x1a\n'
    except OSError:
        return False


def _wm_ensure():
    if _wm_valid():
        return True
    try:
        req=_wm_request.Request(_WM_URL,headers={'User-Agent':'MTPADMIN/0.8.1 (+local cached basemap)'})
        with _wm_request.urlopen(req,timeout=8) as r:
            data=r.read(_WM_MAX+1)
        if len(data) > _WM_MAX or len(data) < 10_000 or not data.startswith(b'\x89PNG\r\n\x1a\n'):
            return False
        _WM_CACHE.parent.mkdir(parents=True,exist_ok=True)
        tmp=_WM_CACHE.with_name('.'+_WM_CACHE.name+'.tmp.'+str(_wm_os.getpid()))
        tmp.write_bytes(data); _wm_os.chmod(tmp,0o644); _wm_os.replace(tmp,_WM_CACHE)
        return True
    except Exception:
        return False


_wm_page_template=page_template
def page_template(title,body,user,active='dashboard',refresh=None,message=''):
    doc=_wm_page_template(title,body,user,active,refresh,message)
    if active!='geo' or not _wm_ensure():
        return doc
    replacement=("<image href='/assets/world-map.png' x='0' y='0' width='1000' height='500' "
                 "preserveAspectRatio='none' style='opacity:.88;mix-blend-mode:screen'/><g id='geo-points'></g>")
    doc,n=_wm_re.subn(r"<g class='geo-land'>.*?</g><g id='geo-points'></g>",replacement,doc,count=1,flags=_wm_re.S)
    if n:
        doc=doc.replace('Точки строятся локально по DB-IP из сохранённых IP; размер точки соответствует выбранному показателю за период страницы.',
                        'Базовая карта мира кэшируется локально на сервере (equirectangular, CC0/Natural Earth); точки строятся локально по DB-IP. Размер точки соответствует выбранному показателю.')
    return doc


_wm_do_GET=Handler.do_GET
def _wm_GET(self):
    path=urllib.parse.urlsplit(self.path).path
    if path!='/assets/world-map.png':
        return _wm_do_GET(self)
    if not self.require_user():
        return
    if not _wm_ensure():
        self.send_error(HTTPStatus.SERVICE_UNAVAILABLE,'World basemap unavailable'); return
    data=_WM_CACHE.read_bytes()
    self.send_response(200)
    self.send_header('Content-Type','image/png')
    self.send_header('Content-Length',str(len(data)))
    self.send_header('Cache-Control','private, max-age=86400')
    self.send_header('X-Content-Type-Options','nosniff')
    self.end_headers(); self.wfile.write(data)
Handler.do_GET=_wm_GET
