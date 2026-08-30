            elif path=='/healthz':
                data=b'ok\n'; self.send_response(200); self.send_header('Content-Type','text/plain'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
            else: self.send_html('Не найдено','<div class="card"><h1>404</h1></div>','dashboard',404)
        except Exception as e:
            self.send_html('Ошибка',f'<div class="card"><h1>Ошибка</h1><pre>{esc(type(e).__name__+": "+str(e))}</pre></div>','dashboard',500)

    def do_POST(self):
        if not self.require_user(): return
        path=urllib.parse.urlsplit(self.path).path
        try:
            f=self.form()
            if not csrf_ok(self.user(),f.get('csrf','')):
                self.send_html('CSRF','<div class="card"><h1>Запрос отклонён</h1><p>CSRF token недействителен. Обновите страницу.</p></div>','dashboard',403); return
            if handle_guard_post(self,path,f): return
            if path=='/action/source-add':
                name=safe_source_name(f.get('name')); argv=['add',name]
                tag=(f.get('ad_tag') or '').strip()
                if tag:
                    if not HEX32_RE.fullmatch(tag): raise ValueError('Ad tag должен содержать 32 hex-символа')
                    argv += ['--ad-tag',tag.lower()]
                mc=safe_int(f.get('max_conns'),'Макс. соединений'); mi=safe_int(f.get('max_ips'),'Макс. IP')
                if mc: argv += ['--max-conns',str(mc)]
                if mi: argv += ['--max-ips',str(mi)]
                secret=source_mutation(argv,capture_secret=True)
                body=f'<div class="card"><h1>Источник {esc(name)} создан</h1><p>Сохраните новый secret. Он показан только в этом ответе и не помещается в URL.</p><div class="linkbox">{esc(secret)}</div><p><a class="btn" href="/sources">Вернуться к источникам</a></p></div>'
                self.send_html('Источник создан',body,'sources'); return
            if path in ('/action/source-enable','/action/source-disable','/action/source-rotate','/action/source-delete'):
                name=safe_source_name(f.get('name')); primary=state().get('PROFILE','MAIN')
                if path.endswith('enable'): source_mutation(['enable',name]); msg=f'{name}: включён'
                elif path.endswith('disable'): source_mutation(['disable',name]); msg=f'{name}: отключён'
                elif path.endswith('rotate'):
                    secret=source_mutation(['rotate',name],capture_secret=True)
                    body=f'<div class="card"><h1>Secret источника {esc(name)} изменён</h1><p>Сохраните новый secret. Старые ссылки уже недействительны.</p><div class="linkbox">{esc(secret)}</div><p><a class="btn" href="/sources">Вернуться к источникам</a></p></div>'
                    self.send_html('Secret изменён',body,'sources'); return
                else:
                    if name==primary: raise ValueError('Основной профиль удалять запрещено')
                    source_mutation(['delete',name]); msg=f'{name}: удалён'
                self.redirect('/sources',msg); return
            if path=='/action/backup':
                rc,out=cli('backup',timeout=50)
                if rc: raise RuntimeError(out)
                self.redirect('/system','Backup создан: '+out[-180:]); return
            if path=='/action/geo-update':
                rc,out=cli('geo-update',timeout=180)
                if rc: raise RuntimeError(out)
                self.redirect('/system','GeoIP обновлён'); return
            if path=='/action/restart':
                rc,out=cli('restart',timeout=60)
                if rc: raise RuntimeError(out)
                self.redirect('/system','TeleMT перезапущен'); return
            self.send_html('Не найдено','<div class="card"><h1>404</h1></div>','dashboard',404)
        except Exception as e:
            self.send_html('Ошибка действия',f'<div class="card"><h1>Действие не выполнено</h1><pre>{esc(type(e).__name__+": "+str(e))}</pre><p><a class="btn secondary" href="javascript:history.back()">Назад</a></p></div>','dashboard',400)


# Extensions are attached only after the original fragmented Handler class has
# completed. The legacy web fragments intentionally continue functions/classes.
GUARD_PY='/usr/local/lib/mtpadmin/scanner_guard.py'
GUARD_PERIODS={'1h':3600,'24h':86400,'7d':7*86400,'30d':30*86400}
GUARD_CLASSES=('ALL','CLIENT','UNKNOWN','HOSTING?','SCAN','WHITELIST','BANNED')


def guard_epoch(v):
    try: return dt.datetime.fromtimestamp(int(v)).strftime('%Y-%m-%d %H:%M:%S')
    except Exception: return '—'


def guard_interval(first,last,n):
    try:
        n=int(n or 0); first=int(first or 0); last=int(last or 0)
        if n<=1: return '—'
        sec=max(0,(last-first)/(n-1))
    except Exception:
        return '—'
    if sec<60: return f'{sec:.0f} сек'
    if sec<3600: return f'{sec/60:.1f} мин'
    return f'{sec/3600:.1f} ч'


def guard_badge(v):
    v=str(v or 'UNKNOWN')
    cls='ok' if v in ('CLIENT','WHITELIST') else ('bad' if v in ('SCAN','BANNED') else 'warn')
    return f'<span class="{cls}">{esc(v)}</span>'


def risk_badge(v):
    try: n=max(0,min(100,int(v or 0)))
    except Exception: n=0
    cls='ok' if n<25 else ('warn' if n<60 else 'bad')
    return f'<span class="{cls}"><b>{n}</b></span>'


def guard_form(csrf,action,ip,label,css='secondary',duration='',confirm=''):
    extra=f'<input type="hidden" name="duration" value="{esc(duration)}">' if duration else ''
    confirm_attr=''
    if confirm:
        safe_msg=str(confirm).replace('\\','\\\\').replace("'","\\'")
        confirm_attr=f' onsubmit="return confirm(\'{esc(safe_msg)}\')"'
    return (f'<form class="inline" method="post" action="{action}"{confirm_attr}>'
            f'<input type="hidden" name="csrf" value="{esc(csrf)}">'
            f'<input type="hidden" name="ip" value="{esc(ip)}">{extra}'
            f'<button class="{css}">{esc(label)}</button></form>')


def active_clients_html():
    users=source_rows(); by_name={str(u.get('username','')):u for u in users}
    try:
        live=api_json('/v1/stats/users/active-ips',timeout=5) or []
    except Exception:
        live=[]
        for u in users:
            ips=u.get('active_unique_ips_list') or []
            if ips: live.append({'username':u.get('username',''),'active_ips':ips})
    rows=[]; unique=set(); active_sources=0
    for entry in live:
        name=str(entry.get('username','')); ips=entry.get('active_ips') or []
        if ips: active_sources+=1
        src=by_name.get(name,{})
        for raw_ip in ips:
            try: ip=str(ipaddress.ip_address(raw_ip))
            except ValueError: continue
            unique.add(ip)
            hist=query('SELECT country_code,city,asn,org,first_seen,last_seen,hits FROM clients WHERE ip=? LIMIT 1',(ip,))
            h=hist[0] if hist else {}
            obs=query('SELECT classification,risk_score,valid_last_seen FROM scanner_observations WHERE ip=? LIMIT 1',(ip,))
            o=obs[0] if obs else {}
            rows.append([
                '<span class="ok">● LIVE</span>',esc(name),esc(ip),esc(h.get('country_code','')),esc(h.get('city','')),
                esc(h.get('asn','')),esc(h.get('org','')),esc(src.get('current_connections',0)),
                esc(guard_epoch(h.get('first_seen'))),esc(guard_epoch(h.get('last_seen'))),guard_badge(o.get('classification','CLIENT'))
            ])
    rows.sort(key=lambda r:(r[1],r[2]))
    total_conns=sum(int(u.get('current_connections') or 0) for u in users)
    cards=f"""<div class='grid'>
<div class='card metric'><div class='k'>Текущие соединения</div><div class='v'>{total_conns}</div><div class='muted'>по всем источникам</div></div>
<div class='card metric'><div class='k'>Активные IP</div><div class='v ok'>{len(unique)}</div><div class='muted'>live TeleMT</div></div>
<div class='card metric'><div class='k'>Активные источники</div><div class='v'>{active_sources}</div><div class='muted'>из {len(users)}</div></div>
<div class='card metric'><div class='k'>Обновление</div><div class='v' style='font-size:20px'>5 сек</div><div class='muted'>{esc(dt.datetime.now().strftime('%H:%M:%S'))}</div></div>
</div>"""
    note="<div class='card' style='margin-top:14px'><h2>Активные клиенты сейчас</h2><div class='muted'>Данные берутся из live API TeleMT. Поле «Соед. источника» — общее число текущих соединений этого источника, а не число соединений конкретного IP.</div></div>"
    body=table(['','Источник','IP','CC','Город','ASN','Провайдер / сеть','Соед. источника','Первый','Последний','Guard'],rows)
    return cards+note+"<div class='card' style='margin-top:14px'>"+body+"</div>"


def _guard_filters(params):
    period=str(params.get('period','24h'))
    if period not in GUARD_PERIODS: period='24h'
    cls=str(params.get('class','ALL')).upper()
    if cls not in GUARD_CLASSES: cls='ALL'
    q=str(params.get('q','')).strip()[:80]
    return period,cls,q


def scanner_security_html(user,csrf,params):
    now=int(time.time()); period,cls,q=_guard_filters(params); cutoff=now-GUARD_PERIODS[period]
    rc,_=run(['systemctl','is-active','--quiet','mtpadmin-scanner.service'],timeout=5)
    service='<span class="ok">● ACTIVE</span>' if rc==0 else '<span class="bad">● OFFLINE</span>'
    hb=scalar("SELECT value FROM scanner_meta WHERE key='heartbeat'",default=0)
    try: hb_age=max(0,now-int(hb)) if hb else None
    except Exception: hb_age=None
    cls_rows=query("SELECT classification,count(*) n FROM scanner_observations WHERE last_seen>=? GROUP BY classification",(now-86400,))
    counts={str(r.get('classification')):int(r.get('n') or 0) for r in cls_rows}
    high=scalar("SELECT count(*) n FROM scanner_observations WHERE last_seen>=? AND risk_score>=70 AND classification NOT IN ('CLIENT','WHITELIST')",(now-86400,),0)
    bans=query("SELECT ip,created_at,expires_at,reason,actor FROM scanner_bans WHERE active=1 AND (expires_at IS NULL OR expires_at>?) ORDER BY created_at DESC",(now,))
    white=query("SELECT ip,created_at,note,actor FROM scanner_whitelist ORDER BY created_at DESC LIMIT 100")

    where=['last_seen>=?']; args=[cutoff]
    if cls!='ALL': where.append('classification=?'); args.append(cls)
    if q:
        like='%'+q+'%'; where.append('(ip LIKE ? OR city LIKE ? OR asn LIKE ? OR org LIKE ?)'); args.extend([like,like,like,like])
    observed=query('''SELECT ip,classification,risk_score,total_attempts,first_seen,last_seen,valid_last_seen,country_code,city,asn,org
        FROM scanner_observations WHERE '''+' AND '.join(where)+''' ORDER BY risk_score DESC,last_seen DESC LIMIT 250''',tuple(args))
    events=query("SELECT ts,ip,old_class,new_class,attempts,risk_score,detail FROM scanner_state_events WHERE ts>=? ORDER BY ts DESC LIMIT 60",(cutoff,))
    audit_rows=query("SELECT ts,actor,action,ip,detail FROM scanner_audit ORDER BY ts DESC LIMIT 30")

    cards=f"""<div class='grid'>
<div class='card metric'><div class='k'>Scanner Guard</div><div class='v'>{service}</div><div class='muted'>heartbeat: {esc(str(hb_age)+' сек' if hb_age is not None else 'нет')}</div></div>
<div class='card metric'><div class='k'>SCAN · 24 часа</div><div class='v bad'>{counts.get('SCAN',0)}</div><div class='muted'>эвристика, автобан OFF</div></div>
<div class='card metric'><div class='k'>CLIENT · 24 часа</div><div class='v ok'>{counts.get('CLIENT',0)}</div><div class='muted'>подтверждены TeleMT</div></div>
<div class='card metric'><div class='k'>Risk ≥ 70 · 24 часа</div><div class='v {'bad' if int(high or 0) else ''}'>{esc(high)}</div><div class='muted'>только для ручной проверки</div></div>
</div>"""
    info=f"""<div class='card' style='margin-top:14px'><h2>Scanner Guard · аналитика</h2><div class='muted'>Guard наблюдает новые TCP-подключения только к порту MTProxy и сверяет их с клиентами TeleMT. Risk score 0–100, SCAN и HOSTING? — эвристики для ручной проверки, а не доказательство принадлежности IP какой-либо организации. В {esc(VERSION)} автоматическая блокировка выключена.</div></div>"""

    popts=''.join(f"<option value='{k}' {'selected' if k==period else ''}>{v}</option>" for k,v in [('1h','1 час'),('24h','24 часа'),('7d','7 дней'),('30d','30 дней')])
    copts=''.join(f"<option value='{esc(k)}' {'selected' if k==cls else ''}>{esc('Все статусы' if k=='ALL' else k)}</option>" for k in GUARD_CLASSES)
    filters=f"""<div class='card' style='margin-top:14px'><h2>Фильтры наблюдений</h2><form method='get' action='/security'><div class='formgrid'>
<div><label>Период</label><select name='period'>{popts}</select></div><div><label>Статус</label><select name='class'>{copts}</select></div>
<div><label>Поиск</label><input name='q' value='{esc(q)}' placeholder='IP, город, ASN или провайдер'></div><div style='align-self:end'><button>Показать</button> <a class='btn secondary' href='/security'>Сбросить</a></div>
</div></form></div>"""

    orows=[]
    for r in observed:
        ip=str(r.get('ip') or ''); status=str(r.get('classification') or 'UNKNOWN')
        if status=='BANNED': acts=guard_form(csrf,'/action/guard-unban',ip,'Разблокировать','secondary',confirm=f'Разблокировать {ip}?')
        elif status=='WHITELIST': acts=guard_form(csrf,'/action/guard-unwhitelist',ip,'Убрать whitelist','secondary',confirm=f'Удалить {ip} из whitelist?')
        elif status=='CLIENT': acts='<span class="muted">валидный клиент</span>'
        else:
            acts=(guard_form(csrf,'/action/guard-ban',ip,'24 ч','warnbtn','24h',f'Заблокировать {ip} на 24 часа?')+
                  guard_form(csrf,'/action/guard-ban',ip,'7 дней','warnbtn','7d',f'Заблокировать {ip} на 7 дней?')+
                  guard_form(csrf,'/action/guard-whitelist',ip,'Whitelist','secondary',confirm=f'Добавить {ip} в whitelist?'))
        orows.append([risk_badge(r.get('risk_score')),guard_badge(status),esc(ip),esc(r.get('total_attempts',0)),
                      esc(guard_interval(r.get('first_seen'),r.get('last_seen'),r.get('total_attempts'))),esc(r.get('country_code','')),
                      esc(r.get('city','')),esc(r.get('asn','')),esc(r.get('org','')),esc(guard_epoch(r.get('last_seen'))),
                      esc(guard_epoch(r.get('valid_last_seen'))),acts])
    observed_box="<div class='card' style='margin-top:14px'><h2>Все наблюдаемые IP</h2>"+table(['Risk','Статус','IP','SYN','Сред. интервал','CC','Город','ASN','Сеть','Последний SYN','Последний TeleMT','Действия'],orows)+"</div>"

    erows=[[esc(guard_epoch(r.get('ts'))),esc(r.get('ip','')),guard_badge(r.get('old_class')),guard_badge(r.get('new_class')),esc(r.get('attempts',0)),risk_badge(r.get('risk_score')),esc(r.get('detail',''))] for r in events]
    events_box="<div class='card' style='margin-top:14px'><h2>История смены статусов</h2>"+table(['Время','IP','Было','Стало','SYN','Risk','Причина'],erows)+"</div>"

    manual=f"""<div class='card' style='margin-top:14px'><h2>Ручная блокировка</h2><form method='post' action='/action/guard-ban'><input type='hidden' name='csrf' value='{esc(csrf)}'><div class='formgrid'>
<div><label>IP</label><input name='ip' required placeholder='1.2.3.4'></div><div><label>Срок</label><select name='duration'><option value='24h'>24 часа</option><option value='7d'>7 дней</option><option value='30d'>30 дней</option><option value='permanent'>Навсегда</option></select></div>
<div><label>Причина</label><input name='reason' maxlength='120' placeholder='manual'></div></div><div style='margin-top:12px'><button class='danger'>Заблокировать</button></div></form></div>"""

    brows=[]
    for r in bans:
        ip=str(r.get('ip') or ''); exp='Навсегда' if not r.get('expires_at') else guard_epoch(r.get('expires_at'))
        brows.append([esc(ip),esc(guard_epoch(r.get('created_at'))),esc(exp),esc(r.get('reason','')),esc(r.get('actor','')),guard_form(csrf,'/action/guard-unban',ip,'Разблокировать','secondary',confirm=f'Разблокировать {ip}?')])
    ban_box="<div class='card'><h2>Активные блокировки</h2>"+table(['IP','Создано','До','Причина','Кем',''],brows)+"</div>"
    wrows=[]
    for r in white:
        ip=str(r.get('ip') or '')
        wrows.append([esc(ip),esc(guard_epoch(r.get('created_at'))),esc(r.get('note','')),esc(r.get('actor','')),guard_form(csrf,'/action/guard-unwhitelist',ip,'Удалить','secondary',confirm=f'Удалить {ip} из whitelist?')])
    white_box="<div class='card'><h2>Whitelist</h2>"+table(['IP','Добавлен','Примечание','Кем',''],wrows)+"</div>"
    arows=[[esc(guard_epoch(r.get('ts'))),esc(r.get('actor','')),esc(r.get('action','')),esc(r.get('ip','')),esc(r.get('detail',''))] for r in audit_rows]
    audit_box="<div class='card' style='margin-top:14px'><h2>Журнал действий администратора</h2>"+table(['Время','Кем','Действие','IP','Подробности'],arows)+"</div>"
    return cards+info+filters+observed_box+events_box+manual+"<div class='grid2' style='margin-top:14px'>"+ban_box+white_box+"</div>"+audit_box


def safe_guard_ip(v):
    try: a=ipaddress.ip_address((v or '').strip())
    except ValueError: raise ValueError('Некорректный IP')
    if a.is_loopback or a.is_unspecified or a.is_multicast or a.is_link_local or not a.is_global:
        raise ValueError('Разрешены только публичные IP')
    own=state().get('PUBLIC_IP','')
    if own and a==ipaddress.ip_address(own): raise ValueError('IP самого сервера блокировать запрещено')
    return str(a)


def handle_guard_post(handler,path,f):
    if not path.startswith('/action/guard-'): return False
    ip=safe_guard_ip(f.get('ip')); actor=('web:'+handler.user())[:80]
    if path=='/action/guard-ban':
        duration=(f.get('duration') or '24h').strip().lower()
        if duration not in {'30m','24h','7d','30d','permanent'}: raise ValueError('Некорректный срок блокировки')
        reason=(f.get('reason') or 'web manual').strip()[:120]
        rc,out=run([GUARD_PY,'ban',ip,duration,'--reason',reason,'--actor',actor],timeout=20)
    elif path=='/action/guard-unban': rc,out=run([GUARD_PY,'unban',ip,'--actor',actor],timeout=20)
    elif path=='/action/guard-whitelist': rc,out=run([GUARD_PY,'whitelist',ip,'--note','web manual','--actor',actor],timeout=20)
    elif path=='/action/guard-unwhitelist': rc,out=run([GUARD_PY,'unwhitelist',ip,'--actor',actor],timeout=20)
    else: return False
    if rc: raise RuntimeError(out)
    handler.redirect('/security',out); return True


# Add a dedicated live-clients navigation entry without changing the older UI
# fragment chain.
_base_page_template=page_template
def page_template(title,body,user,active='dashboard',refresh=None,message=''):
    doc=_base_page_template(title,body,user,active,refresh,message)
    cls='active' if active=='active' else ''
    link=f'<a class="{cls}" href="/active">Активные</a>'
    return doc.replace('</a><a class="" href="/geo">География</a>',f'</a>{link}<a class="" href="/geo">География</a>',1).replace('</a><a class="active" href="/geo">География</a>',f'</a>{link}<a class="active" href="/geo">География</a>',1)


# Replace Security with analytics and intercept /active. Other routes stay on
# the original handler.
_original_do_GET=Handler.do_GET
def _scanner_do_GET(self):
    path=urllib.parse.urlsplit(self.path).path
    if path not in ('/security','/active'):
        return _original_do_GET(self)
    if not self.require_user(): return
    p=self.params(); msg=p.get('msg','')
    try:
        if path=='/active':
            self.send_html('Активные клиенты',active_clients_html(),'active',refresh=5,message=msg)
        else:
            self.send_html('Безопасность',scanner_security_html(self.user(),csrf_token(self.user()),p),'security',refresh=15,message=msg)
    except Exception as e:
        self.send_html('Ошибка',f'<div class="card"><h1>Ошибка</h1><pre>{esc(type(e).__name__+": "+str(e))}</pre></div>','security' if path=='/security' else 'active',500)
Handler.do_GET=_scanner_do_GET

# Product version shown in the header follows state.env after update.
VERSION=state().get('MTPADMIN_VERSION','0.7.0')


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--listen',default='127.0.0.1')
    ap.add_argument('--port',type=int,default=9199)
    args=ap.parse_args()
    if args.listen not in ('127.0.0.1','::1'):
        raise SystemExit('MTPADMIN Web refuses non-loopback listen address')
    if not Path(CSRF_FILE).exists():
        raise SystemExit(f'missing {CSRF_FILE}')
    httpd=ThreadingHTTPServer((args.listen,args.port),Handler)
    httpd.daemon_threads=True
    print(f'MTPADMIN Web {VERSION} listening on {args.listen}:{args.port}',flush=True)
    httpd.serve_forever()

if __name__=='__main__': main()
