# MTPADMIN 0.11.1 Operations, Update Center and Telegram WEB Proxy UI.
import base64 as _o_b64

_O_UPDATE_STATUS=Path('/var/lib/mtpadmin/update-status.json')
_O_COMPONENT_STATUS=Path('/var/lib/mtpadmin/component-update-status.json')
_O_CHECKER='/usr/local/lib/mtpadmin/update_check.py'
_O_COMPONENT='/usr/local/lib/mtpadmin/component_update.sh'
_O_HOST_RE=re.compile(r'^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$')


def _o_state(): return state()


def _o_read_json(path):
    try:
        obj=json.loads(Path(path).read_text(encoding='utf-8'))
        return obj if isinstance(obj,dict) else {}
    except Exception: return {}


def _o_update_status(): return _o_read_json(_O_UPDATE_STATUS)
def _o_component_status(): return _o_read_json(_O_COMPONENT_STATUS)


def _o_short(v,n=12):
    v=str(v or '')
    return v[:n] if len(v)>n else v


def _o_webproxy_secret():
    st=_o_state(); source=st.get('WEBPROXY_SOURCE','WEB_PROXY')
    try:
        import tomllib
        cfg=tomllib.loads(Path(CFG).read_text(encoding='utf-8'))
        val=(((cfg.get('access') or {}).get('users') or {}).get(source) or '').strip()
        return val if re.fullmatch(r'[0-9a-f]{32}',val) else ''
    except Exception: return ''


def _o_webproxy_link():
    st=_o_state(); host=st.get('WEBPROXY_HOST',''); sec=_o_webproxy_secret()
    if not host or not sec: return ''
    return 'https://t.me/webproxy?'+urllib.parse.urlencode({'server':host,'secret':sec})


def _o_qr(link):
    if not link or shutil.which('qrencode') is None: return ''
    try:
        p=subprocess.run(['qrencode','-t','PNG','-o','-','-s','5','-m','2',link],capture_output=True,timeout=5)
        if p.returncode or not p.stdout: return ''
        data=_o_b64.b64encode(p.stdout).decode('ascii')
        return f"<img alt='WEB Proxy QR' style='width:190px;height:190px;background:#fff;border-radius:12px;padding:8px' src='data:image/png;base64,{data}'>"
    except Exception: return ''


def _o_service(name):
    try: return subprocess.run(['systemctl','is-active','--quiet',name],timeout=3).returncode==0
    except Exception: return False


def _o_http_ok(url):
    try:
        with urllib.request.urlopen(url,timeout=2) as r: return 200 <= int(r.status) < 400
    except Exception: return False


def _o_health():
    st=_o_state(); wp_enabled=st.get('WEBPROXY_ENABLED','0')=='1'; wp_ready=st.get('WEBPROXY_READY','0')=='1'
    checks=[('TeleMT',_o_service('mtpadmin-telemt.service')),('Collector',_o_service('mtpadmin-stats.service')),('Scanner Guard',_o_service('mtpadmin-scanner.service'))]
    if wp_enabled:
        checks.append(('WEB relay',wp_ready and _o_service('tproxy-server.service')))
        checks.append(('WEB relay ready',wp_ready and _o_http_ok('http://127.0.0.1:8081/readyz')))
    try:
        wr={}
        for line in Path('/etc/mtpadmin/web-runtime.env').read_text(encoding='utf-8').splitlines():
            if '=' in line:
                k,v=line.split('=',1); wr[k.strip()]=v.strip().strip("'\"")
        svc=wr.get('WEB_ACTIVE_SERVICE','')
        checks.append(('MTPADMIN Web',bool(svc and _o_service(svc))))
    except Exception: checks.append(('MTPADMIN Web',True))
    good=sum(1 for _n,v in checks if v); score=round(good*100/max(1,len(checks)))
    rows=[[esc(n),'<span class="ok">PASS</span>' if v else '<span class="bad">FAIL</span>'] for n,v in checks]
    return score,rows


def _o_learning():
    now=int(time.time()); cutoff=now-30*86400; rows=[]
    for threshold in (70,80,90):
        would=scalar("SELECT count(*) FROM scanner_observations WHERE risk_score>=? AND classification NOT IN ('CLIENT','WHITELIST','BANNED')",(threshold,),0)
        false=scalar("""SELECT count(DISTINCT e.ip) FROM scanner_state_events e
                       WHERE e.ts>=? AND e.risk_score>=? AND e.new_class IN ('SCAN','HOSTING?')
                         AND EXISTS(SELECT 1 FROM scanner_state_events c WHERE c.ip=e.ip AND c.ts>e.ts AND c.new_class='CLIENT')""",(cutoff,threshold),0)
        rows.append([f'Risk ≥ {threshold}',esc(would),esc(false),'<span class="ok">OFF · только симуляция</span>'])
    return table(['Порог','Было бы заблокировано сейчас','Позже стали CLIENT · 30д','Автобан'],rows)


def _o_backups():
    root=Path('/var/backups/mtpadmin'); items=[]
    try:
        for p in sorted(root.iterdir(),key=lambda x:x.stat().st_mtime,reverse=True)[:15]:
            try:
                st=p.stat(); size=st.st_size if p.is_file() else sum(x.stat().st_size for x in p.rglob('*') if x.is_file())
                items.append([esc(p.name),esc(dt.datetime.fromtimestamp(st.st_mtime).strftime('%Y-%m-%d %H:%M:%S')),esc(human_bytes(size)),esc('архив' if p.is_file() else 'update snapshot')])
            except Exception: pass
    except Exception: pass
    return table(['Backup','Время','Размер','Тип'],items)


def _o_update_center(csrf):
    data=_o_update_status(); comps=data.get('components') or {}; rows=[]
    labels=(('mtpadmin','MTPADMIN'),('telemt','TeleMT'),('webproxy','Telegram WEB Proxy'))
    for key,label in labels:
        c=comps.get(key) or {}; cur=c.get('current') or '—'; latest=c.get('latest') or '—'; available=bool(c.get('available'))
        if key=='webproxy': cur=_o_short(cur); latest=_o_short(latest)
        status='<span class="warn"><b>Доступно обновление</b></span>' if available else ('<span class="ok">Актуально</span>' if latest!='—' else '<span class="muted">Нет данных</span>')
        button=(f"<form class='inline' method='post' action='/action/component-update'><input type='hidden' name='csrf' value='{esc(csrf)}'><input type='hidden' name='component' value='{key}'><button {'class="warnbtn"' if available else 'class="secondary"'}>{'Обновить' if available else 'Переустановить / проверить'}</button></form>")
        rows.append([esc(label),esc(cur),esc(latest),status,button])
    checked=data.get('checked_at'); checked_txt=dt.datetime.fromtimestamp(int(checked)).strftime('%Y-%m-%d %H:%M:%S') if checked else 'ещё не проверялось'
    cs=_o_component_status(); op=''
    if cs:
        st=str(cs.get('state') or ''); cls='ok' if st=='success' else ('bad' if st=='failed' else 'warn')
        op=f"<div class='muted' style='margin-top:10px'>Последняя операция: <span class='{cls}'>{esc(cs.get('component',''))} · {esc(st)}</span> · {esc(cs.get('detail',''))}</div>"
    checkform=f"<form class='inline' method='post' action='/action/update-check'><input type='hidden' name='csrf' value='{esc(csrf)}'><button class='secondary'>Проверить сейчас</button></form>"
    return f"<div class='card'><div class='a-head'><div><h2>Update Center</h2><div class='muted'>Последняя проверка: {esc(checked_txt)}</div></div>{checkform}</div>{table(['Компонент','Установлено','Доступно','Статус','Действие'],rows)}{op}<div class='muted' style='margin-top:10px'>TeleMT при обновлении делает короткий restart с автоматическим rollback при неудаче. MTPADMIN обновляется blue/green. WEB Proxy обновляется отдельно от TeleMT.</div></div>"


def _o_webproxy_card(csrf):
    st=_o_state(); host=st.get('WEBPROXY_HOST',''); source=st.get('WEBPROXY_SOURCE','WEB_PROXY'); link=_o_webproxy_link()
    ready=st.get('WEBPROXY_READY','0')=='1' and _o_service('tproxy-server.service') and _o_http_ok('http://127.0.0.1:8081/readyz')
    qr=_o_qr(link); status='<span class="ok">● READY</span>' if ready else '<span class="warn">● требуется завершить/проверить установку</span>'
    linkbox=f"<div class='linkbox' id='webproxy-link'>{esc(link)}</div><button class='secondary' onclick=\"copyText('webproxy-link')\">Копировать</button>" if link else "<div class='muted'>WEB link ещё не сформирован.</div>"
    form=f"""<form method='post' action='/action/webproxy-host'><input type='hidden' name='csrf' value='{esc(csrf)}'><label>Hostname WEB Proxy</label><div class='actions'><input name='host' required autocomplete='off' autocapitalize='off' spellcheck='false' style='min-width:min(420px,100%)' value='{esc(host)}' placeholder='webproxy.example.com'><button>Применить</button></div><div class='muted' style='margin-top:6px'>Можно ввести свой поддомен. Его DNS A-запись должна указывать на IP этого сервера.</div></form>"""
    return f"""<div class='card'><div class='a-head'><div><h2>Telegram WEB Proxy</h2><div>{status}</div></div>{qr}</div>{form}
<div style='margin-top:12px'><label>TeleMT source</label><div class='linkbox'>{esc(source)}</div></div>
<div style='margin-top:12px'>{linkbox}</div><div class='muted' style='margin-top:10px'>Официальный telegramdesktop/tproxy-server → TeleMT localhost. HTTPS/443 обслуживает Caddy.</div></div>"""


def _o_operations_html(user,csrf):
    score,checks=_o_health(); cls='ok' if score>=90 else ('warn' if score>=70 else 'bad'); st=_o_state(); current=st.get('MTPADMIN_VERSION',VERSION)
    health=f"<div class='card metric'><div class='k'>Health Score</div><div class='v {cls}'>{score}/100</div><div class='muted'>ключевые runtime-компоненты</div></div>"
    version=f"<div class='card metric'><div class='k'>MTPADMIN</div><div class='v' style='font-size:25px'>{esc(current)}</div><div class='muted'>blue/green update</div></div>"
    learn=scalar("SELECT count(*) FROM scanner_observations WHERE risk_score>=70 AND classification NOT IN ('CLIENT','WHITELIST','BANNED')",(),0)
    guard=f"<div class='card metric'><div class='k'>Guard Learning</div><div class='v'>{esc(learn)}</div><div class='muted'>Risk ≥70 · autoban OFF</div></div>"
    updates=int((_o_update_status().get('updates') or 0)); upd=f"<div class='card metric'><div class='k'>Обновления</div><div class='v {'warn' if updates else 'ok'}'>{updates}</div><div class='muted'>{'доступны новые версии' if updates else 'всё актуально'}</div></div>"
    return f"""<div class='grid'>{health}{version}{guard}{upd}</div>
<div style='margin-top:14px'>{_o_update_center(csrf)}</div>
<div class='grid2' style='margin-top:14px'>{_o_webproxy_card(csrf)}<div class='card'><h2>Health checks</h2>{table(['Компонент','Статус'],checks)}</div></div>
<div class='card' style='margin-top:14px'><h2>Scanner Guard · Learning Mode</h2><div class='muted' style='margin-bottom:10px'>Симуляция показывает последствия порогов, но ничего автоматически не блокирует.</div>{_o_learning()}</div>
<div class='card' style='margin-top:14px'><h2>Последние backup</h2>{_o_backups()}</div>"""


# Keep browser autofill away from the source-name field.
_o_sources_prev=sources_html
def sources_html(user,csrf):
    out=_o_sources_prev(user,csrf)
    return out.replace("<input name='name' required placeholder='SITE или TG_AD_01'>","<input name='name' required autocomplete='off' autocapitalize='off' spellcheck='false' placeholder='SITE или TG_AD_01'>",1)


# Add WEB Proxy to connection links.
_o_links_prev=links_html
def links_html():
    base=_o_links_prev(); link=_o_webproxy_link()
    if not link: return base
    st=_o_state(); qr=_o_qr(link); iid='webproxy-share-link'
    card=f"""<div class='card' style='margin-bottom:12px'><div class='a-head'><div><h2>WEB_PROXY · WEB</h2><div class='muted'>{esc(st.get('WEBPROXY_HOST',''))} · HTTPS 443</div></div>{qr}</div><div class='linkbox' id='{iid}'>{esc(link)}</div><button class='secondary' onclick=\"copyText('{iid}')\">Копировать WEB-ссылку</button></div>"""
    return base+card


# Operations GET route.
_o_get_prev=Handler.do_GET
def _o_do_GET(self):
    path=urllib.parse.urlsplit(self.path).path
    if path!='/operations': return _o_get_prev(self)
    if not self.require_user(): return
    try: self.send_html('Операции',_o_operations_html(self.user(),csrf_token(self.user())),'operations',refresh=10,message=self.params().get('msg',''))
    except Exception as e: self.send_html('Ошибка',f'<div class="card"><h1>Ошибка</h1><pre>{esc(type(e).__name__+": "+str(e))}</pre></div>','operations',500)
Handler.do_GET=_o_do_GET


# Operations POST actions. Long updates are detached into transient systemd jobs.
_o_post_prev=Handler.do_POST
def _o_do_POST(self):
    path=urllib.parse.urlsplit(self.path).path
    if path not in ('/action/update-check','/action/component-update','/action/webproxy-host'): return _o_post_prev(self)
    if not self.require_user(): return
    try:
        f=self.form()
        if not csrf_ok(self.user(),f.get('csrf','')):
            self.send_html('CSRF','<div class="card"><h1>Запрос отклонён</h1></div>','operations',403); return
        if path=='/action/update-check':
            rc,out=run([_O_CHECKER],timeout=35)
            if rc: raise RuntimeError(out or 'Проверка обновлений не выполнена')
            self.redirect('/operations','Проверка обновлений завершена'); return
        if path=='/action/component-update':
            comp=str(f.get('component') or '')
            if comp not in ('mtpadmin','telemt','webproxy'): raise ValueError('Неизвестный компонент')
            rc,out=run([_O_COMPONENT,'dispatch',comp],timeout=10)
            if rc: raise RuntimeError(out or 'Не удалось запустить обновление')
            self.redirect('/operations',f'Обновление {comp} запущено в фоне'); return
        raw=str(f.get('host') or '').strip().lower()
        raw=re.sub(r'^https?://','',raw).split('/',1)[0].rstrip('.')
        if not _O_HOST_RE.fullmatch(raw) or '.' not in raw or ':' in raw: raise ValueError('Укажите hostname без пути и порта, например webproxy.example.com')
        rc,out=run([_O_COMPONENT,'dispatch','webproxy-host',raw],timeout=10)
        if rc: raise RuntimeError(out or 'Не удалось запустить смену hostname')
        self.redirect('/operations',f'Применение WEB Proxy hostname {raw} запущено в фоне'); return
    except Exception as e:
        self.send_html('Ошибка действия',f'<div class="card"><h1>Действие не выполнено</h1><pre>{esc(type(e).__name__+": "+str(e))}</pre><p><a class="btn secondary" href="/operations">Назад</a></p></div>','operations',400)
Handler.do_POST=_o_do_POST


# Navigation entry + global update notification.
_o_page_prev=page_template
def page_template(title,body,user,active='dashboard',refresh=None,message=''):
    doc=_o_page_prev(title,body,user,active,refresh,message)
    cls='active' if active=='operations' else ''; link=f'<a class="{cls}" href="/operations">Операции</a>'
    needle='<a class="" href="/system">Система</a>'; active_needle='<a class="active" href="/system">Система</a>'
    if needle in doc: doc=doc.replace(needle,link+needle,1)
    elif active_needle in doc: doc=doc.replace(active_needle,link+active_needle,1)
    updates=int((_o_update_status().get('updates') or 0))
    if updates>0 and active!='operations':
        banner=f"<div style='border:1px solid #b54708;background:#3a250c;padding:11px 13px;border-radius:10px;margin-bottom:14px'><b class='warn'>Доступно обновлений: {updates}</b> · <a href='/operations'>Открыть Update Center →</a></div>"
        doc=doc.replace('<main id="live-root"',banner+'<main id="live-root"',1)
    return doc
