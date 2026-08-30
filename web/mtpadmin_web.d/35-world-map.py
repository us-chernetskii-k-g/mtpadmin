# MTPADMIN 0.8.2 world basemap and map-polish extension.
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
        req=_wm_request.Request(_WM_URL,headers={'User-Agent':'MTPADMIN/0.8.2 (+local cached basemap)'})
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


def _wm_city_map():
    """Representative city per country from retained local client history."""
    try:
        rows=query("""SELECT upper(country_code) AS cc, coalesce(city,'') AS city, count(*) AS n
                      FROM clients
                      WHERE length(coalesce(country_code,''))=2 AND coalesce(city,'')!=''
                      GROUP BY upper(country_code), city
                      ORDER BY n DESC""")
    except Exception:
        return {}
    best={}
    for row in rows:
        cc=str(row.get('cc') or '').upper()
        city=str(row.get('city') or '').strip()
        if len(cc)==2 and city and cc not in best:
            best[cc]=city
    return best


_wm_page_template=page_template
def page_template(title,body,user,active='dashboard',refresh=None,message=''):
    doc=_wm_page_template(title,body,user,active,refresh,message)
    if active!='geo':
        return doc

    if _wm_ensure():
        replacement=("<image href='/assets/world-map.png' x='0' y='0' width='1000' height='500' "
                     "preserveAspectRatio='none' style='opacity:.88;mix-blend-mode:screen'/><g id='geo-points'></g>")
        doc,n=_wm_re.subn(r"<g class='geo-land'>.*?</g><g id='geo-points'></g>",replacement,doc,count=1,flags=_wm_re.S)
        if n:
            doc=doc.replace('Точки строятся локально по DB-IP из сохранённых IP; размер точки соответствует выбранному показателю за период страницы.',
                            'Базовая карта мира кэшируется локально на сервере (equirectangular, CC0/Natural Earth); точки строятся локально по DB-IP. Размер и разведение точек адаптируются к выбранному показателю.')

    cities=esc(json.dumps(_wm_city_map(),ensure_ascii=False,separators=(',',':')))
    doc=doc.replace("id='world-map' data-positions=",f"id='world-map' data-wm-cities=\"{cities}\" data-positions=",1)

    css="""<style id='wm-polish-css'>
.wm-tip{position:fixed;z-index:9999;display:none;pointer-events:none;max-width:280px;padding:9px 11px;border-radius:9px;background:#050b14eF;border:1px solid #3b4c67;box-shadow:0 10px 30px #0008;color:#e9eef7;font-size:12px;line-height:1.4}.wm-tip b{color:#fff}.wm-tip .muted{font-size:11px}.geo-dot{filter:drop-shadow(0 2px 3px #0008)}
</style>"""
    js="""<div id='wm-tip' class='wm-tip'></div><script id='wm-polish-js'>
(()=>{
 const root=document.getElementById('live-root'), tip=document.getElementById('wm-tip'); if(!root||!tip)return;
 let raf=0;
 function schedule(){if(raf)return;raf=requestAnimationFrame(()=>{raf=0;polish();});}
 function cityMap(){const box=document.getElementById('world-map');try{return JSON.parse(box?.dataset.wmCities||'{}')}catch(_e){return {}}}
 function hashAngle(s){let h=0;for(let i=0;i<s.length;i++)h=((h<<5)-h+s.charCodeAt(i))|0;return ((Math.abs(h)%360)/180)*Math.PI;}
 function polish(){
   const dots=[...root.querySelectorAll('.geo-dot')]; if(!dots.length)return;
   const metric=root.querySelector('[data-geo-metric].active-metric')?.dataset.geoMetric||'unique';
   const vals=dots.map(d=>Math.max(0,parseInt(metric==='sessions'?d.dataset.s:d.dataset.u)||0));
   const max=Math.max(1,...vals), denom=Math.log1p(max), placed=[];
   dots.forEach((d,i)=>{
     const val=vals[i], r=5+(denom?Math.log1p(val)/denom:0)*14;
     d.setAttribute('r',r.toFixed(1)); d.removeAttribute('transform');
     let x=parseFloat(d.getAttribute('cx'))||0,y=parseFloat(d.getAttribute('cy'))||0,dx=0,dy=0;
     for(const p of placed){
       const vx=x+dx-p.x,vy=y+dy-p.y,dist=Math.hypot(vx,vy),need=r+p.r+3;
       if(dist<need){const a=dist>0.1?Math.atan2(vy,vx):hashAngle(d.dataset.cc||String(i));const sh=Math.min(15,(need-dist)*0.58);dx+=Math.cos(a)*sh;dy+=Math.sin(a)*sh;}
     }
     if(dx||dy)d.setAttribute('transform',`translate(${dx.toFixed(1)} ${dy.toFixed(1)})`);
     placed.push({x:x+dx,y:y+dy,r});
   });
 }
 function show(e,d){
   const cities=cityMap(),cc=d.dataset.cc||'',city=cities[cc]||'';
   tip.innerHTML=`<b>${d.dataset.name||cc} (${cc})</b>${city?`<div>Город: <b>${city}</b></div>`:''}<div>Уникальных IP: <b>${d.dataset.u||0}</b></div><div>Сеансов: <b>${d.dataset.s||0}</b></div><div class='muted'>GeoIP приблизительный</div>`;
   tip.style.display='block'; const w=280,h=110; tip.style.left=Math.max(8,Math.min(innerWidth-w-8,e.clientX+14))+'px';tip.style.top=Math.max(8,Math.min(innerHeight-h-8,e.clientY+14))+'px';
 }
 root.addEventListener('pointermove',e=>{const d=e.target.closest&&e.target.closest('.geo-dot');if(d)show(e,d);else tip.style.display='none'});
 root.addEventListener('pointerleave',()=>tip.style.display='none');
 new MutationObserver(schedule).observe(root,{subtree:true,childList:true});
 schedule();
})();
</script>"""
    doc=doc.replace('</head>',css+'</head>',1).replace('</body>',js+'</body>',1)
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
