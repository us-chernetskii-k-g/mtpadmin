# MTPADMIN 0.11.8 stability layer.
# Keeps config/runtime sources visible, verifies source mutations end-to-end,
# and keeps persistent SQLite statistics separate from resettable TeleMT runtime counters.

_ST_RUNTIME_ERROR=''
_ST_CONFIG_ERROR=''
_ST_DB_ERROR=''


def _st_config_sources():
    global _ST_CONFIG_ERROR
    try:
        import tomllib
        with open(CFG,'rb') as f:
            d=tomllib.load(f)
        access=d.get('access') or {}
        users=access.get('users') or {}
        enabled=access.get('user_enabled') or {}
        adtags=access.get('user_ad_tags') or {}
        maxc=access.get('user_max_tcp_conns') or {}
        maxi=access.get('user_max_unique_ips') or {}
        out={}
        for name,secret in users.items():
            name=str(name)
            out[name]={
                'username':name,
                'secret':str(secret or '').lower(),
                'enabled':bool(enabled.get(name,True)),
                'user_ad_tag':str(adtags.get(name) or '').lower() or None,
                'max_tcp_conns':maxc.get(name),
                'max_unique_ips':maxi.get(name),
                'config_present':True,
            }
        _ST_CONFIG_ERROR=''
        return out
    except Exception as e:
        _ST_CONFIG_ERROR=f'{type(e).__name__}: {e}'
        return {}


def _st_runtime_sources():
    global _ST_RUNTIME_ERROR
    try:
        rows=api_json('/v1/users',timeout=5) or []
        _ST_RUNTIME_ERROR=''
        return {str(r.get('username') or ''):dict(r) for r in rows if r.get('username')}
    except Exception as e:
        _ST_RUNTIME_ERROR=f'{type(e).__name__}: {e}'
        return {}


def source_rows():
    cfg=_st_config_sources(); runtime=_st_runtime_sources(); st=state(); primary=str(st.get('PROFILE','MAIN'))
    names=set(cfg)|set(runtime); out=[]
    for name in sorted(names,key=lambda n:(n!=primary,n.lower())):
        c=cfg.get(name) or {}; r=runtime.get(name) or {}
        row=dict(c); row.update(r)
        row['username']=name
        row['config_present']=name in cfg
        row['in_runtime']=name in runtime and bool(r.get('in_runtime',True))
        if name in cfg:
            for key in ('enabled','user_ad_tag','max_tcp_conns','max_unique_ips'):
                if key not in r:
                    row[key]=c.get(key)
        out.append(row)
    return out


def _st_runtime_secret(row):
    links=(row or {}).get('links') or {}
    for link in links.get('classic') or []:
        try:
            q=urllib.parse.parse_qs(urllib.parse.urlsplit(str(link)).query)
            sec=(q.get('secret') or [''])[0].lower()
            if re.fullmatch(r'[0-9a-f]{32}',sec): return sec
        except Exception:
            pass
    return ''


def _st_source_matches(name):
    cfg=_st_config_sources(); rt=_st_runtime_sources()
    if name not in cfg:
        return name not in rt
    if name not in rt:
        return False
    c=cfg[name]; r=rt[name]
    if bool(r.get('enabled',True)) != bool(c.get('enabled',True)): return False
    for key in ('max_tcp_conns','max_unique_ips'):
        cv=c.get(key); rv=r.get(key)
        if cv is not None:
            try: cv=int(cv)
            except Exception: pass
        if rv is not None:
            try: rv=int(rv)
            except Exception: pass
        if cv!=rv: return False
    ca=(c.get('user_ad_tag') or '').lower(); ra=str(r.get('user_ad_tag') or '').lower()
    if ca!=ra: return False
    cs=str(c.get('secret') or '').lower(); rs=_st_runtime_secret(r)
    if cs and rs and cs!=rs: return False
    return True


def _st_wait_telemt(seconds=30):
    end=time.time()+seconds
    while time.time()<end:
        try:
            if subprocess.run(['systemctl','is-active','--quiet','mtpadmin-telemt.service'],timeout=3).returncode==0:
                api_json('/v1/health/ready',timeout=2)
                return True
        except Exception:
            pass
        time.sleep(1)
    return False


def _st_restart_telemt():
    rc,out=run(['systemctl','restart','mtpadmin-telemt.service'],timeout=35)
    if rc!=0: raise RuntimeError(out or 'TeleMT restart failed')
    if not _st_wait_telemt(30): raise RuntimeError('TeleMT did not become READY after restart')


def _st_kick_guard():
    try:
        subprocess.run(['systemctl','restart','mtpadmin-scanner.service'],timeout=20,check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    except Exception:
        pass


def _st_validate_config():
    import tomllib
    with open(CFG,'rb') as f: tomllib.load(f)


def _st_backup_config():
    Path('/var/backups/mtpadmin').mkdir(parents=True,exist_ok=True)
    dest=f"/var/backups/mtpadmin/source-before-{time.time_ns()}.toml"
    shutil.copy2(CFG,dest)
    return dest


def source_mutation(argv,capture_secret=False):
    if not argv or len(argv)<2: raise ValueError('Некорректная операция источника')
    name=safe_source_name(str(argv[1]))
    with ACTION_LOCK:
        backup=_st_backup_config()
        rc,out=run([USERCFG,*argv],timeout=20)
        if rc!=0:
            shutil.copy2(backup,CFG)
            raise RuntimeError(out or 'Config edit failed')
        try:
            _st_validate_config()
            applied=False
            try:
                reload_config()
                applied=_st_source_matches(name)
            except Exception:
                applied=False
            if not applied:
                _st_restart_telemt()
                applied=_st_source_matches(name)
                _st_kick_guard()
            if not applied:
                raise RuntimeError(f'Runtime TeleMT не подтвердил изменение источника {name}')
        except Exception as e:
            shutil.copy2(backup,CFG)
            try:
                _st_restart_telemt(); _st_kick_guard()
            except Exception as rollback_error:
                raise RuntimeError(f'{e}; rollback restart failed: {rollback_error}') from e
            raise
        try:
            _x_event('source','config applied','web',' '.join(str(x) for x in argv[:3]))
        except Exception:
            pass
        return out.strip() if capture_secret else ''


def _st_repair_source(name):
    name=safe_source_name(name)
    if name not in _st_config_sources(): raise ValueError('Источник отсутствует в config.toml')
    _st_restart_telemt(); _st_kick_guard()
    if not _st_source_matches(name):
        raise RuntimeError(f'После restart источник {name} всё ещё не совпадает с config.toml')


def _st_source_state(row):
    cfg=bool(row.get('config_present')); run=bool(row.get('in_runtime'))
    if cfg and run: return '<span class="ok">● ACTIVE</span>'
    if cfg and not run: return '<span class="warn">● CONFIG ONLY</span>'
    return '<span class="bad">● RUNTIME ONLY</span>'


def _st_edit_form(csrf,row):
    name=str(row.get('username') or '')
    tag=str(row.get('user_ad_tag') or '')
    maxc='' if row.get('max_tcp_conns') is None else str(row.get('max_tcp_conns'))
    maxi='' if row.get('max_unique_ips') is None else str(row.get('max_unique_ips'))
    return (f"<details class='source-edit'><summary>Настроить</summary>"
            f"<form method='post' action='/action/source-edit' autocomplete='off'>"
            f"<input type='hidden' name='csrf' value='{esc(csrf)}'><input type='hidden' name='name' value='{esc(name)}'>"
            f"<div class='formgrid' style='margin-top:9px'>"
            f"<div><label>Ad tag</label><input name='ad_tag' autocomplete='off' value='{esc(tag)}' placeholder='пусто = глобальный'></div>"
            f"<div><label>Макс. соединений</label><input name='max_conns' inputmode='numeric' value='{esc(maxc)}' placeholder='пусто = без лимита'></div>"
            f"<div><label>Макс. уникальных IP</label><input name='max_ips' inputmode='numeric' value='{esc(maxi)}' placeholder='пусто = без лимита'></div>"
            f"</div><div class='actions' style='margin-top:9px'><button>Сохранить настройки</button></div></form></details>")


def sources_html(user,csrf):
    st=state(); primary=str(st.get('PROFILE','MAIN')); websrc=str(st.get('WEBPROXY_SOURCE','WEB_PROXY')); users=source_rows(); rows=[]
    for u in users:
        name=str(u.get('username') or ''); actions=[]
        if u.get('config_present'):
            actions.append(_st_edit_form(csrf,u))
            if not u.get('in_runtime'):
                actions.append(f"<form class='inline' method='post' action='/action/source-repair'><input type='hidden' name='csrf' value='{esc(csrf)}'><input type='hidden' name='name' value='{esc(name)}'><button class='secondary'>Восстановить runtime</button></form>")
            if name!=websrc:
                if u.get('enabled',True):
                    actions.append(f"<form class='inline' method='post' action='/action/source-disable'><input type='hidden' name='csrf' value='{esc(csrf)}'><input type='hidden' name='name' value='{esc(name)}'><button class='warnbtn'>Отключить</button></form>")
                else:
                    actions.append(f"<form class='inline' method='post' action='/action/source-enable'><input type='hidden' name='csrf' value='{esc(csrf)}'><input type='hidden' name='name' value='{esc(name)}'><button>Включить</button></form>")
                actions.append(f"<form class='inline' method='post' action='/action/source-rotate' onsubmit=\"return confirm('Сменить secret источника {esc(name)}? Старые ссылки перестанут работать.')\"><input type='hidden' name='csrf' value='{esc(csrf)}'><input type='hidden' name='name' value='{esc(name)}'><button class='warnbtn'>Сменить secret</button></form>")
                if name!=primary:
                    actions.append(f"<form class='inline' method='post' action='/action/source-delete' onsubmit=\"return confirm('Удалить источник {esc(name)}?')\"><input type='hidden' name='csrf' value='{esc(csrf)}'><input type='hidden' name='name' value='{esc(name)}'><button class='danger'>Удалить</button></form>")
            else:
                actions.append("<span class='muted'>WEB_PROXY управляется через Операции</span>")
        ad='<span class="muted">глобальный</span>' if not u.get('user_ad_tag') else esc(str(u.get('user_ad_tag')))
        rows.append([esc(name),_st_source_state(u),esc(u.get('current_connections',0)),esc(u.get('active_unique_ips',0)),ad,esc(u.get('max_tcp_conns') if u.get('max_tcp_conns') is not None else '—'),esc(u.get('max_unique_ips') if u.get('max_unique_ips') is not None else '—'),'<div class="actions">'+''.join(actions)+'</div>'])
    add=f"""<div class='card' style='margin-bottom:14px'><h2>Добавить источник</h2><div class='muted' style='margin-bottom:10px'>Источник считается созданным только после подтверждения TeleMT runtime. Если hot reload не сработает, MTPADMIN сам выполнит короткий restart.</div><form method='post' action='/action/source-add' autocomplete='off'><input type='hidden' name='csrf' value='{esc(csrf)}'><div class='formgrid'>
<div><label>Имя</label><input name='name' required autocomplete='new-password' autocapitalize='off' spellcheck='false' value='' placeholder='SITE или TG_AD_01'></div><div><label>Отдельный ad tag</label><input name='ad_tag' autocomplete='new-password' maxlength='32' placeholder='необязательно'></div>
<div><label>Макс. соединений</label><input name='max_conns' inputmode='numeric' autocomplete='off'></div><div><label>Макс. уникальных IP</label><input name='max_ips' inputmode='numeric' autocomplete='off'></div></div><div style='margin-top:12px'><button>Создать источник</button></div></form></div>"""
    warnings=[]
    if _ST_CONFIG_ERROR: warnings.append('config.toml: '+_ST_CONFIG_ERROR)
    if _ST_RUNTIME_ERROR: warnings.append('TeleMT API: '+_ST_RUNTIME_ERROR)
    notice=("<div class='card' style='margin-bottom:14px;border-color:#b54708'><b class='warn'>Есть расхождение config/runtime.</b><div class='muted'>"+esc(' · '.join(warnings))+"</div></div>") if warnings else ''
    return add+notice+"<div class='card'><h1>Источники</h1><div class='muted' style='margin-bottom:10px'>ACTIVE — есть и в config.toml, и в TeleMT runtime. CONFIG ONLY больше не скрывается.</div>"+table(['Источник','Состояние','Соед.','IP','Ad tag','Макс. соед.','Макс. IP','Действия'],rows)+"</div>"


def _st_history_source_names(start,end):
    names=set()
    for r in query("SELECT DISTINCT username FROM anon_visits WHERE day BETWEEN ? AND ? UNION SELECT DISTINCT username FROM daily_traffic WHERE day BETWEEN ? AND ? AND username!='__GLOBAL__'",(start,end,start,end)):
        n=str(r.get('username') or '')
        if n: names.add(n)
    return names


def _x_source_analytics(period='7d'):
    period=period if period in PERIODS else '7d'; start,end=period_bounds(period); current={str(u.get('username') or ''):u for u in source_rows()}; names=set(current)|_st_history_source_names(start,end); out=[]
    for name in sorted(names,key=str.lower):
        u=current.get(name) or {}; uv=scalar("SELECT count(DISTINCT ip_hash) FROM anon_visits WHERE username=? AND day BETWEEN ? AND ?",(name,start,end),0)
        sess=scalar("SELECT coalesce(sum(observations),0) FROM anon_visits WHERE username=? AND day BETWEEN ? AND ?",(name,start,end),0)
        new=scalar("SELECT count(DISTINCT a.ip_hash) FROM anon_visits a WHERE a.username=? AND a.day BETWEEN ? AND ? AND a.day=(SELECT min(b.day) FROM anon_visits b WHERE b.username=a.username AND b.ip_hash=a.ip_hash)",(name,start,end),0)
        con=scalar("SELECT coalesce(sum(connections),0) FROM daily_traffic WHERE username=? AND day BETWEEN ? AND ?",(name,start,end),0)
        byt=scalar("SELECT coalesce(sum(bytes_from_client+bytes_to_client),0) FROM daily_traffic WHERE username=? AND day BETWEEN ? AND ?",(name,start,end),0)
        state_label='runtime' if u.get('in_runtime') else ('config' if u.get('config_present') else 'архив')
        out.append([esc(name),esc(state_label),esc(u.get('current_connections',0)),esc(u.get('active_unique_ips',0)),esc(uv),esc(new),esc(sess),esc(con),esc(human_bytes(byt))])
    opts=" ".join(f'<a class="btn {"" if k==period else "secondary"}" href="/sources?period={k}">{esc(v)}</a>' for k,v in PERIODS.items())
    return f"<div class='card' style='margin-top:14px'><div class='a-head'><div><h2>Аналитика источников · {esc(PERIODS.get(period,period))}</h2><div class='muted'>Исторические источники остаются в отчёте даже после удаления из runtime.</div></div><div class='actions'>{opts}</div></div>{table(['Источник','Состояние','Online','Активные IP','Уникальных','Новых','Сеансов','Соединений','Трафик'],out)}</div>"


def _st_db_health():
    con=None
    try:
        con=db_connect(); row=con.execute("SELECT value FROM collector_meta WHERE key='heartbeat'").fetchone(); hb=int(row[0]) if row and row[0] else 0
        return True,hb,''
    except Exception as e:
        return False,0,f'{type(e).__name__}: {e}'
    finally:
        if con is not None:
            try: con.close()
            except Exception: pass


def _st_dashboard_html():
    st=state(); users=source_rows(); current=sum(int(u.get('current_connections') or 0) for u in users if u.get('in_runtime')); active_ips=sum(int(u.get('active_unique_ips') or 0) for u in users if u.get('in_runtime')); today=dt.date.today().isoformat()
    uniq=scalar("SELECT count(DISTINCT ip_hash) FROM anon_visits WHERE day=?",(today,),0); sessions=scalar("SELECT coalesce(sum(observations),0) FROM anon_visits WHERE day=?",(today,),0); traffic=scalar("SELECT coalesce(sum(bytes_from_client+bytes_to_client),0) FROM daily_traffic WHERE day=? AND username!='__GLOBAL__'",(today,),0)
    countries=query("SELECT country_code,country_name,count(DISTINCT ip_hash) u,sum(observations) s FROM anon_visits WHERE day=? GROUP BY country_code,country_name ORDER BY u DESC,s DESC LIMIT 8",(today,))
    dbok,hb,dberr=_st_db_health(); age=max(0,int(time.time())-hb) if hb else None
    try: telemt_ok=subprocess.run(['systemctl','is-active','--quiet','mtpadmin-telemt.service'],timeout=3).returncode==0 and not _ST_RUNTIME_ERROR
    except Exception: telemt_ok=False
    cards=f"""<div class='grid'>
<div class='card metric'><div class='k'>Telegram Proxy</div><div class='v {'ok' if telemt_ok else 'bad'}'>{'ONLINE' if telemt_ok else 'ПРОВЕРИТЬ'}</div><div class='muted'>{esc(st.get('PUBLIC_HOST',''))}:{esc(st.get('PORT',''))}</div></div>
<div class='card metric'><div class='k'>Сейчас</div><div class='v'>{current}</div><div class='muted'>активных IP: {active_ips}</div></div>
<div class='card metric'><div class='k'>Сегодня</div><div class='v'>{esc(uniq)}</div><div class='muted'>сеансов: {esc(sessions)}</div></div>
<div class='card metric'><div class='k'>Трафик сегодня</div><div class='v' style='font-size:22px'>{esc(human_bytes(traffic))}</div><div class='muted'>сохранён в SQLite и не обнуляется при restart</div></div>
</div>"""
    notices=[]
    if not dbok: notices.append("<div class='bad'><b>Статистика недоступна:</b> "+esc(dberr)+"</div>")
    elif age is None or age>30: notices.append("<div class='warn'><b>Collector не обновляет статистику.</b> heartbeat: "+esc(str(age)+' сек' if age is not None else 'нет')+"</div>")
    if _ST_RUNTIME_ERROR: notices.append("<div class='warn'><b>TeleMT API:</b> "+esc(_ST_RUNTIME_ERROR)+"</div>")
    notices.append("<div class='muted'>Дата статистики: "+esc(today)+" · timezone сервера: "+esc(time.tzname[0] if time.tzname else 'local')+"</div>")
    notice="<div class='card' style='margin-top:14px'>"+''.join(notices)+"</div>"
    srows=[]
    for u in users:
        name=str(u.get('username') or ''); t=scalar("SELECT coalesce(sum(bytes_from_client+bytes_to_client),0) FROM daily_traffic WHERE day=? AND username=?",(today,name),0)
        srows.append([esc(name),_st_source_state(u),esc(u.get('current_connections',0)),esc(u.get('active_unique_ips',0)),esc(human_bytes(t))])
    crows=[[esc(x.get('country_code')),esc(x.get('country_name')),esc(x.get('u')),esc(x.get('s'))] for x in countries]
    return cards+notice+f"<div class='grid2' style='margin-top:14px'><div class='card'><h2>Источники</h2>{table(['Источник','Состояние','Соединения','IP','Трафик сегодня'],srows)}</div><div class='card'><h2>Страны сегодня</h2>{table(['Код','Страна','Уникальных','Сеансов'],crows)}</div></div>"

# analytics-plus calls this captured global when rendering the dashboard.
_a_dashboard_html=_st_dashboard_html


def _st_support_card():
    return """<div class='card' style='margin-top:14px'><div class='a-head'><div><h2>VPN BOSS</h2><div class='muted'>MTPADMIN — бесплатный инструмент экосистемы VPN BOSS.</div></div><a class='btn' href='https://t.me/boss_of_this_vpn' target='_blank' rel='noopener'>Группа VPN BOSS →</a></div><p>Новости проекта, помощь, обсуждение и новые инструменты — в Telegram-группе VPN BOSS.</p><div class='actions'><a class='btn secondary' href='https://brakonder.ru' target='_blank' rel='noopener'>brakonder.ru</a><a class='btn secondary' href='https://yookassa.ru/my/i/aoLKJEpmtnnX/l' target='_blank' rel='noopener'>Поддержать разработку</a></div></div>"""

_st_page_prev=page_template
def page_template(title,body,user,active='dashboard',refresh=None,message=''):
    if active=='dashboard': body=body+_st_support_card()
    doc=_st_page_prev(title,body,user,active,refresh,message)
    css="""<style>.source-edit{border:1px solid #334155;border-radius:8px;padding:6px 8px}.source-edit summary{cursor:pointer;color:#cbd5e1}.source-edit[open]{min-width:330px}</style>"""
    return doc.replace('</head>',css+'</head>',1)

_st_post_prev=Handler.do_POST
def _st_do_POST(self):
    path=urllib.parse.urlsplit(self.path).path
    if path not in ('/action/source-edit','/action/source-repair'):
        return _st_post_prev(self)
    if not self.require_user(): return
    try:
        f=self.form()
        if not csrf_ok(self.user(),f.get('csrf','')):
            self.send_html('CSRF','<div class="card"><h1>Запрос отклонён</h1></div>','sources',403); return
        name=safe_source_name(f.get('name'))
        if path=='/action/source-repair':
            _st_repair_source(name); self.redirect('/sources',f'{name}: runtime восстановлен из config.toml'); return
        tag=(f.get('ad_tag') or '').strip(); mc=(f.get('max_conns') or '').strip(); mi=(f.get('max_ips') or '').strip()
        argv=['edit',name,'--ad-tag',tag or 'none','--max-conns',mc or 'none','--max-ips',mi or 'none']
        source_mutation(argv); self.redirect('/sources',f'{name}: настройки применены и подтверждены runtime'); return
    except Exception as e:
        self.send_html('Ошибка действия',f'<div class="card"><h1>Изменение не применено</h1><pre>{esc(type(e).__name__+": "+str(e))}</pre><p><a class="btn secondary" href="/sources">Назад</a></p></div>','sources',400)
Handler.do_POST=_st_do_POST
