# MTPADMIN 0.10.0 analytics-plus extension.
# Correct baselines, interactive time ranges, source analytics and event journal.

_X_RANGES={'1h':3600,'6h':21600,'24h':86400,'7d':7*86400,'30d':30*86400}
_X_RANGE_LABELS={'1h':'1 ч','6h':'6 ч','24h':'24 ч','7d':'7 дней','30d':'30 дней'}


def _x_range(v,default='6h'):
    v=str(v or default)
    return v if v in _X_RANGES else default


def _x_chart(labels,series,height=220,value_suffix=''):
    n=max([len(labels)]+[len(a) for _n,a,_c in series]+[0])
    if n<=0:
        return "<div class='muted'>Пока недостаточно данных для графика.</div>"
    vals=[_a_num(v) for _name,arr,_color in series for v in arr]
    vmax=max(vals+[1.0]); vmin=min(vals+[0.0])
    if vmin>0: vmin=0.0
    span=max(1e-9,vmax-vmin)
    W=900; H=height; left=50; right=18; top=20; bottom=42
    iw=W-left-right; ih=H-top-bottom
    def xy(i,v):
        x=left+iw*(i/(n-1 if n>1 else 1)); y=top+ih*(1-((_a_num(v)-vmin)/span)); return x,y
    grid=[]
    for j in range(5):
        y=top+ih*j/4; val=vmax-span*j/4
        grid.append(f"<line x1='{left}' y1='{y:.1f}' x2='{W-right}' y2='{y:.1f}' class='a-grid'/><text x='{left-7}' y='{y+4:.1f}' text-anchor='end' class='a-axis'>{esc(f'{val:.0f}{value_suffix}')}</text>")
    parts=[]
    for name,arr,color in series:
        if not arr: continue
        pts=[xy(i,v) for i,v in enumerate(arr)]
        d=' '.join(('M' if i==0 else 'L')+f'{x:.1f},{y:.1f}' for i,(x,y) in enumerate(pts))
        dots=[]
        for i,(x,y) in enumerate(pts):
            lab=labels[i] if i<len(labels) else str(i)
            dots.append(f"<circle cx='{x:.1f}' cy='{y:.1f}' r='5' fill='transparent' stroke='transparent' class='x-hit'><title>{esc(lab)} · {esc(name)}: {esc(arr[i])}{esc(value_suffix)}</title></circle>")
        parts.append(f"<path d='{d}' fill='none' stroke='{color}' stroke-width='2.4' vector-effect='non-scaling-stroke'/>"+''.join(dots))
    ticks=[]
    if labels:
        picks=sorted(set([0,max(0,(n-1)//4),max(0,(n-1)//2),max(0,3*(n-1)//4),n-1]))
        for i in picks:
            x=left+iw*(i/(n-1 if n>1 else 1)); anchor='middle'
            if i==0: anchor='start'
            elif i==n-1: anchor='end'
            ticks.append(f"<text x='{x:.1f}' y='{H-10}' text-anchor='{anchor}' class='a-axis'>{esc(labels[i])}</text>")
    legend=''.join(f"<span class='a-legend-item'><i style='background:{color}'></i>{esc(name)}</span>" for name,_arr,color in series)
    return f"<div class='a-chart-wrap'><svg class='a-chart' viewBox='0 0 {W} {H}' role='img'>{''.join(grid)}{''.join(parts)}{''.join(ticks)}</svg><div class='a-legend'>{legend}</div></div>"


def _x_compare(cur,prev,exists=True):
    if not exists:
        return 'нет данных для сравнения','muted'
    cur=_a_num(cur); prev=_a_num(prev)
    if prev==0:
        if cur==0: return '0%','muted'
        return 'рост с 0','ok'
    pct=(cur-prev)/prev*100
    if abs(pct)<0.5: return '0%','muted'
    return f'{pct:+.0f}%',('ok' if pct>0 else 'warn')


def _x_online_rows(seconds):
    cutoff=int(time.time())-int(seconds)
    return query("SELECT ts,connections,unique_ips FROM online_samples WHERE username='__GLOBAL__' AND ts>=? ORDER BY ts",(cutoff,))


def _x_range_buttons(path,current):
    return "<div class='actions x-ranges'>"+''.join(f"<a class='btn {'secondary' if k!=current else ''}' href='{path}?range={k}'>{esc(_X_RANGE_LABELS[k])}</a>" for k in _X_RANGES)+"</div>"


def _x_online_card(rng='6h',path='/active'):
    rng=_x_range(rng); seconds=_X_RANGES[rng]
    rows=_a_downsample(_x_online_rows(seconds),180)
    title=f"Online · {_X_RANGE_LABELS[rng]}"
    head=f"<div class='a-head'><div><h2>{esc(title)}</h2>"
    if not rows:
        return f"<div class='card'>{head}<div class='muted'>История online пока накапливается.</div></div>{_x_range_buttons(path,rng)}</div>"
    labels=[]
    for r in rows:
        t=dt.datetime.fromtimestamp(int(r['ts']))
        labels.append(t.strftime('%H:%M') if seconds<=86400 else t.strftime('%m-%d %H:%M'))
    conns=[int(r.get('connections') or 0) for r in rows]; ips=[int(r.get('unique_ips') or 0) for r in rows]
    peak=max(conns or [0]); avg=sum(ips)/len(ips) if ips else 0
    chart=_x_chart(labels,[('Соединения',conns,'#60a5fa'),('Активные IP',ips,'#32d583')],230)
    return f"<div class='card'>{head}<div class='muted'>Пик соединений: <b>{peak}</b> · среднее активных IP: <b>{avg:.1f}</b></div></div>{_x_range_buttons(path,rng)}</div>{chart}</div>"


def _x_overview_trends():
    now=int(time.time()); target=now-3600
    live=query("SELECT ts,connections,unique_ips FROM online_samples WHERE username='__GLOBAL__' ORDER BY ts DESC LIMIT 1")
    old=query("SELECT ts,connections,unique_ips FROM online_samples WHERE username='__GLOBAL__' AND ts BETWEEN ? AND ? ORDER BY abs(ts-?) LIMIT 1",(target-600,target+600,target))
    cur=live[0] if live else {'connections':0,'unique_ips':0}; prev=old[0] if old else {}
    dc,cc=_x_compare(cur.get('connections'),prev.get('connections'),bool(old))
    td=dt.datetime.now().date(); yd=td-dt.timedelta(days=1)
    tr=query("SELECT count(DISTINCT ip_hash) v FROM anon_visits WHERE day=?",(td.isoformat(),)); yr=query("SELECT count(DISTINCT ip_hash) v FROM anon_visits WHERE day=?",(yd.isoformat(),))
    tb=query("SELECT coalesce(sum(bytes_from_client+bytes_to_client),0) v FROM daily_traffic WHERE day=?",(td.isoformat(),)); yb=query("SELECT coalesce(sum(bytes_from_client+bytes_to_client),0) v FROM daily_traffic WHERE day=?",(yd.isoformat(),))
    today=int((tr[0] if tr else {}).get('v') or 0); yesterday=int((yr[0] if yr else {}).get('v') or 0)
    tbytes=int((tb[0] if tb else {}).get('v') or 0); ybytes=int((yb[0] if yb else {}).get('v') or 0)
    di,ci=_x_compare(today,yesterday,bool(yr)); db,cb=_x_compare(tbytes,ybytes,bool(yb))
    return f"""<div class='grid' style='margin-top:14px'>
<div class='card metric'><div class='k'>Online сейчас</div><div class='v'>{int(cur.get('connections') or 0)}</div><div class='{cc}'>{esc(dc)} к часу назад</div></div>
<div class='card metric'><div class='k'>Активные IP сейчас</div><div class='v'>{int(cur.get('unique_ips') or 0)}</div><div class='muted'>снимок каждые 30 сек</div></div>
<div class='card metric'><div class='k'>Уникальные сегодня</div><div class='v'>{today}</div><div class='{ci}'>{esc(di)} ко вчера</div></div>
<div class='card metric'><div class='k'>Трафик сегодня</div><div class='v' style='font-size:21px'>{esc(human_bytes(tbytes))}</div><div class='{cb}'>{esc(db)} ко вчера</div></div>
</div>"""


def _x_daily_charts(period):
    clients,traffic=_a_daily_data(period)
    if not clients and not traffic:
        return "<div class='card' style='margin-bottom:14px'><h2>Графики</h2><div class='muted'>За выбранный период данных пока нет.</div></div>"
    labels=sorted({str(r['day']) for r in clients+traffic}); short=[x[5:] for x in labels]
    cm={str(r['day']):r for r in clients}; tm={str(r['day']):r for r in traffic}
    uniq=[int((cm.get(d) or {}).get('uniq') or 0) for d in labels]; sess=[int((cm.get(d) or {}).get('sessions') or 0) for d in labels]
    conns=[int((tm.get(d) or {}).get('connections') or 0) for d in labels]; mb=[round(_a_num((tm.get(d) or {}).get('bytes'))/1048576,2) for d in labels]
    c1=_x_chart(short,[('Уникальные IP',uniq,'#32d583'),('Сеансы',sess,'#60a5fa')],220)
    c2=_x_chart(short,[('Соединения',conns,'#fdb022')],220); c3=_x_chart(short,[('Трафик MB',mb,'#8b5cf6')],220,' MB')
    return f"<div class='grid2' style='margin-bottom:14px'><div class='card'><h2>Клиенты и сеансы</h2>{c1}</div><div class='card'><h2>Соединения</h2>{c2}</div></div><div class='card' style='margin-bottom:14px'><h2>Суммарный трафик</h2>{c3}</div>"


def _x_source_analytics(period='7d'):
    period=period if period in PERIODS else '7d'; start,end=period_bounds(period); users=source_rows(); out=[]
    for u in users:
        name=str(u.get('username') or '')
        uv=scalar("SELECT count(DISTINCT ip_hash) FROM anon_visits WHERE username=? AND day BETWEEN ? AND ?",(name,start,end),0)
        sess=scalar("SELECT coalesce(sum(observations),0) FROM anon_visits WHERE username=? AND day BETWEEN ? AND ?",(name,start,end),0)
        new=scalar("SELECT count(DISTINCT a.ip_hash) FROM anon_visits a WHERE a.username=? AND a.day BETWEEN ? AND ? AND a.day=(SELECT min(b.day) FROM anon_visits b WHERE b.username=a.username AND b.ip_hash=a.ip_hash)",(name,start,end),0)
        con=scalar("SELECT coalesce(sum(connections),0) FROM daily_traffic WHERE username=? AND day BETWEEN ? AND ?",(name,start,end),0)
        byt=scalar("SELECT coalesce(sum(bytes_from_client+bytes_to_client),0) FROM daily_traffic WHERE username=? AND day BETWEEN ? AND ?",(name,start,end),0)
        out.append([esc(name),esc(u.get('current_connections',0)),esc(u.get('active_unique_ips',0)),esc(uv),esc(new),esc(sess),esc(con),esc(human_bytes(byt))])
    opts=" ".join(f'<a class="btn {"" if k==period else "secondary"}" href="/sources?period={k}">{esc(v)}</a>' for k,v in PERIODS.items())
    return f"<div class='card' style='margin-top:14px'><div class='a-head'><div><h2>Аналитика источников · {esc(PERIODS.get(period,period))}</h2><div class='muted'>Новые — IP, впервые появившиеся у этого источника в выбранном периоде.</div></div><div class='actions'>{opts}</div></div>{table(['Источник','Online','Активные IP','Уникальных','Новых','Сеансов','Соединений','Трафик'],out)}</div>"


def _x_event_init():
    try:
        with sqlite3.connect(DB,timeout=5) as con:
            con.execute('''CREATE TABLE IF NOT EXISTS system_events(
                id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, category TEXT NOT NULL,
                action TEXT NOT NULL, actor TEXT, detail TEXT)''')
            con.execute('CREATE INDEX IF NOT EXISTS idx_system_events_ts ON system_events(ts DESC)'); con.commit()
    except Exception: pass


def _x_event(category,action,actor='system',detail=''):
    try:
        with sqlite3.connect(DB,timeout=5) as con:
            con.execute('INSERT INTO system_events(ts,category,action,actor,detail) VALUES(?,?,?,?,?)',(int(time.time()),str(category)[:32],str(action)[:80],str(actor)[:80],str(detail)[:500])); con.commit()
    except Exception: pass


def _x_events_html():
    sysrows=query("SELECT ts,category,action,actor,detail FROM system_events ORDER BY ts DESC LIMIT 100")
    audit=query("SELECT ts,actor,action,ip,detail FROM scanner_audit ORDER BY ts DESC LIMIT 80")
    states=query("SELECT ts,ip,old_class,new_class,risk_score,detail FROM scanner_state_events ORDER BY ts DESC LIMIT 80")
    merged=[]
    for r in sysrows: merged.append((int(r.get('ts') or 0),'SYSTEM',r))
    for r in audit: merged.append((int(r.get('ts') or 0),'GUARD',r))
    for r in states: merged.append((int(r.get('ts') or 0),'STATE',r))
    merged.sort(key=lambda x:x[0],reverse=True); rows=[]
    for ts,kind,r in merged[:150]:
        when=guard_epoch(ts)
        if kind=='SYSTEM': desc=f"{r.get('category','')} · {r.get('action','')}"; actor=r.get('actor',''); detail=r.get('detail','')
        elif kind=='GUARD': desc=f"Guard · {r.get('action','')} · {r.get('ip','')}"; actor=r.get('actor',''); detail=r.get('detail','')
        else: desc=f"{r.get('ip','')} · {r.get('old_class','')} → {r.get('new_class','')} · risk {r.get('risk_score',0)}"; actor='Scanner Guard'; detail=r.get('detail','')
        rows.append([esc(when),esc(kind),esc(desc),esc(actor),esc(detail)])
    return "<div class='card'><h1>События</h1><div class='muted' style='margin-bottom:12px'>Единая лента обновлений MTPADMIN, действий администратора и Scanner Guard.</div>"+table(['Время','Тип','Событие','Кто','Детали'],rows)+"</div>"

_x_event_init()

# Audit source mutations performed from web.
_x_source_mutation_prev=source_mutation
def source_mutation(argv,capture_secret=False):
    result=_x_source_mutation_prev(argv,capture_secret)
    safe=' '.join(str(x) for x in argv[:3])
    _x_event('source','config change','web',safe)
    return result

# Dedicated pages with query-aware analytics.
_x_get_prev=Handler.do_GET
def _x_do_GET(self):
    path=urllib.parse.urlsplit(self.path).path
    if path not in ('/','/active','/stats','/sources','/events'):
        return _x_get_prev(self)
    if not self.require_user(): return
    p=self.params(); msg=p.get('msg','')
    try:
        if path=='/':
            rng=_x_range(p.get('range'),'6h')
            body=_a_dashboard_html()+_x_overview_trends()+"<div style='margin-top:14px'>"+_x_online_card(rng,'/')+"</div>"
            self.send_html('Обзор',body,'dashboard',refresh=5,message=msg)
        elif path=='/active':
            rng=_x_range(p.get('range'),'6h')
            body=_a_active_clients_html()+"<div style='margin-top:14px'>"+_x_online_card(rng,'/active')+"</div>"
            self.send_html('Активные клиенты',body,'active',refresh=5,message=msg)
        elif path=='/stats':
            period=p.get('period','7d'); period=period if period in PERIODS else '7d'
            self.send_html('Статистика',_x_daily_charts(period)+_a_stats_html(period),'stats',message=msg)
        elif path=='/sources':
            period=p.get('period','7d'); period=period if period in PERIODS else '7d'
            self.send_html('Источники',sources_html(self.user(),csrf_token(self.user()))+_x_source_analytics(period),'sources',message=msg)
        else:
            self.send_html('События',_x_events_html(),'events',refresh=10,message=msg)
    except Exception as e:
        self.send_html('Ошибка',f'<div class="card"><h1>Ошибка</h1><pre>{esc(type(e).__name__+": "+str(e))}</pre></div>','dashboard',500)
Handler.do_GET=_x_do_GET

# Add Events to navigation after Security.
_x_page_prev=page_template
def page_template(title,body,user,active='dashboard',refresh=None,message=''):
    doc=_x_page_prev(title,body,user,active,refresh,message)
    cls='active' if active=='events' else ''
    link=f'<a class="{cls}" href="/events">События</a>'
    needle='<a class="" href="/system">Система</a>'
    active_needle='<a class="active" href="/system">Система</a>'
    if needle in doc: doc=doc.replace(needle,link+needle,1)
    elif active_needle in doc: doc=doc.replace(active_needle,link+active_needle,1)
    css="""<style>.x-ranges{margin-top:8px}.x-hit{pointer-events:all}.x-hit:hover{stroke:#fff;stroke-width:1;fill:rgba(96,165,250,.18)}</style>"""
    return doc.replace('</head>',css+'</head>',1)
