# MTPADMIN 0.9.0 analytics extension.
# Lightweight server-rendered SVG charts; no CDN, no external JS, no client IP export.
import math as _a_math


def _a_num(v):
    try: return float(v or 0)
    except Exception: return 0.0


def _a_downsample(rows, limit=120):
    if len(rows) <= limit:
        return rows
    step = len(rows) / float(limit)
    out=[]; i=0.0
    while int(i) < len(rows):
        out.append(rows[int(i)]); i += step
    return out[:limit]


def _a_chart(labels, series, height=220, value_suffix=''):
    """Return a responsive inline SVG line chart.

    series: [(label,[numbers],css_color), ...]
    """
    n=max([len(labels)] + [len(x[1]) for x in series] + [0])
    if n <= 0:
        return "<div class='muted'>Пока недостаточно данных для графика.</div>"
    vals=[_a_num(v) for _name,arr,_color in series for v in arr]
    vmax=max(vals+[1.0]); vmin=min(vals+[0.0])
    if vmin > 0: vmin=0.0
    span=max(1e-9,vmax-vmin)
    W=900; H=height; left=48; right=18; top=20; bottom=38
    iw=W-left-right; ih=H-top-bottom
    def xy(i,v):
        x=left + (iw*(i/(n-1 if n>1 else 1)))
        y=top + ih*(1-((_a_num(v)-vmin)/span))
        return x,y
    grid=[]
    for j in range(5):
        y=top+ih*j/4
        val=vmax-(span*j/4)
        grid.append(f"<line x1='{left}' y1='{y:.1f}' x2='{W-right}' y2='{y:.1f}' class='a-grid'/><text x='{left-7}' y='{y+4:.1f}' text-anchor='end' class='a-axis'>{esc(f'{val:.0f}{value_suffix}')}</text>")
    paths=[]
    for name,arr,color in series:
        if not arr: continue
        pts=[xy(i,v) for i,v in enumerate(arr)]
        d=' '.join(('M' if i==0 else 'L')+f'{x:.1f},{y:.1f}' for i,(x,y) in enumerate(pts))
        circles=''.join(f"<circle cx='{x:.1f}' cy='{y:.1f}' r='2.2' fill='{color}'><title>{esc(name)}: {esc(arr[i])}</title></circle>" for i,(x,y) in enumerate(pts) if len(pts)<=45 or i in (0,len(pts)-1))
        paths.append(f"<path d='{d}' fill='none' stroke='{color}' stroke-width='2.4' vector-effect='non-scaling-stroke'/>{circles}")
    first=esc(labels[0] if labels else ''); last=esc(labels[-1] if labels else '')
    legend=''.join(f"<span class='a-legend-item'><i style='background:{color}'></i>{esc(name)}</span>" for name,_arr,color in series)
    return (f"<div class='a-chart-wrap'><svg class='a-chart' viewBox='0 0 {W} {H}' role='img'>"
            +''.join(grid)+''.join(paths)
            +f"<text x='{left}' y='{H-10}' class='a-axis'>{first}</text><text x='{W-right}' y='{H-10}' text-anchor='end' class='a-axis'>{last}</text></svg>"
            +f"<div class='a-legend'>{legend}</div></div>")


def _a_pct(cur,prev):
    cur=_a_num(cur); prev=_a_num(prev)
    if prev <= 0:
        return ('+100%' if cur>0 else '0%', 'ok' if cur>0 else 'muted')
    pct=(cur-prev)/prev*100
    if abs(pct)<0.5: return ('0%','muted')
    return (f"{pct:+.0f}%", 'ok' if pct>0 else 'warn')


def _a_online_rows(seconds=21600):
    cutoff=int(time.time())-seconds
    return query("SELECT ts,connections,unique_ips FROM online_samples WHERE username='__GLOBAL__' AND ts>=? ORDER BY ts",(cutoff,))


def _a_online_card(seconds=21600,title='Online · последние 6 часов'):
    rows=_a_downsample(_a_online_rows(seconds),120)
    if not rows:
        return f"<div class='card'><h2>{esc(title)}</h2><div class='muted'>История online начнёт заполняться после установки 0.9.0. Снимок сохраняется каждые 30 секунд.</div></div>"
    labels=[dt.datetime.fromtimestamp(int(r['ts'])).strftime('%H:%M') for r in rows]
    conns=[int(r.get('connections') or 0) for r in rows]
    ips=[int(r.get('unique_ips') or 0) for r in rows]
    peak=max(conns or [0]); avg=(sum(ips)/len(ips)) if ips else 0
    chart=_a_chart(labels,[('Соединения',conns,'#60a5fa'),('Активные IP',ips,'#32d583')],220)
    return f"<div class='card'><div class='a-head'><div><h2>{esc(title)}</h2><div class='muted'>Пик соединений: <b>{peak}</b> · среднее активных IP: <b>{avg:.1f}</b></div></div></div>{chart}</div>"


def _a_daily_data(period):
    start,end=period_bounds(period)
    clients=query("SELECT day,count(DISTINCT ip_hash) uniq,sum(observations) sessions FROM anon_visits WHERE day BETWEEN ? AND ? GROUP BY day ORDER BY day",(start,end))
    traffic=query("SELECT day,sum(connections) connections,sum(bytes_from_client)+sum(bytes_to_client) bytes FROM daily_traffic WHERE day BETWEEN ? AND ? GROUP BY day ORDER BY day",(start,end))
    return clients,traffic


def _a_daily_charts(period):
    clients,traffic=_a_daily_data(period)
    if not clients and not traffic:
        return "<div class='card' style='margin-bottom:14px'><h2>Графики</h2><div class='muted'>За выбранный период данных пока нет.</div></div>"
    labels=sorted({str(r['day']) for r in clients+traffic})
    cm={str(r['day']):r for r in clients}; tm={str(r['day']):r for r in traffic}
    short=[x[5:] for x in labels]
    uniq=[int((cm.get(d) or {}).get('uniq') or 0) for d in labels]
    sess=[int((cm.get(d) or {}).get('sessions') or 0) for d in labels]
    conns=[int((tm.get(d) or {}).get('connections') or 0) for d in labels]
    mb=[round(_a_num((tm.get(d) or {}).get('bytes'))/1048576,2) for d in labels]
    c1=_a_chart(short,[('Уникальные IP',uniq,'#32d583'),('Сеансы',sess,'#60a5fa')],220)
    c2=_a_chart(short,[('Соединения',conns,'#fdb022')],220)
    c3=_a_chart(short,[('Трафик MB',mb,'#8b5cf6')],220,' MB')
    return f"<div class='grid2' style='margin-bottom:14px'><div class='card'><h2>Клиенты и сеансы</h2>{c1}</div><div class='card'><h2>Соединения</h2>{c2}</div></div><div class='card' style='margin-bottom:14px'><h2>Суммарный трафик</h2>{c3}</div>"


def _a_overview_trends():
    now=int(time.time()); hour=now-3600
    live=query("SELECT ts,connections,unique_ips FROM online_samples WHERE username='__GLOBAL__' ORDER BY ts DESC LIMIT 1")
    old=query("SELECT ts,connections,unique_ips FROM online_samples WHERE username='__GLOBAL__' AND ts<=? ORDER BY ts DESC LIMIT 1",(hour,))
    cur=live[0] if live else {'connections':0,'unique_ips':0}; prev=old[0] if old else {'connections':0,'unique_ips':0}
    td=dt.datetime.now().date(); yd=td-dt.timedelta(days=1)
    today=scalar("SELECT count(DISTINCT ip_hash) FROM anon_visits WHERE day=?",(td.isoformat(),),0)
    yesterday=scalar("SELECT count(DISTINCT ip_hash) FROM anon_visits WHERE day=?",(yd.isoformat(),),0)
    tbytes=scalar("SELECT coalesce(sum(bytes_from_client+bytes_to_client),0) FROM daily_traffic WHERE day=?",(td.isoformat(),),0)
    ybytes=scalar("SELECT coalesce(sum(bytes_from_client+bytes_to_client),0) FROM daily_traffic WHERE day=?",(yd.isoformat(),),0)
    dc,cc=_a_pct(cur.get('connections'),prev.get('connections')); di,ci=_a_pct(today,yesterday); db,cb=_a_pct(tbytes,ybytes)
    return f"""<div class='grid' style='margin-top:14px'>
<div class='card metric'><div class='k'>Online сейчас</div><div class='v'>{int(cur.get('connections') or 0)}</div><div class='{cc}'>{esc(dc)} к часу назад</div></div>
<div class='card metric'><div class='k'>Активные IP сейчас</div><div class='v'>{int(cur.get('unique_ips') or 0)}</div><div class='muted'>снимок каждые 30 сек</div></div>
<div class='card metric'><div class='k'>Уникальные сегодня</div><div class='v'>{esc(today)}</div><div class='{ci}'>{esc(di)} ко вчера</div></div>
<div class='card metric'><div class='k'>Трафик сегодня</div><div class='v' style='font-size:21px'>{esc(human_bytes(tbytes))}</div><div class='{cb}'>{esc(db)} ко вчера</div></div>
</div>"""


def _a_security_analytics():
    now=int(time.time()); cutoff=now-86400
    buckets=query('''SELECT CASE WHEN risk_score<25 THEN '0–24' WHEN risk_score<60 THEN '25–59' WHEN risk_score<80 THEN '60–79' ELSE '80–100' END bucket,count(*) n
                     FROM scanner_observations WHERE last_seen>=? GROUP BY bucket''',(cutoff,))
    bm={r['bucket']:int(r['n'] or 0) for r in buckets}; order=['0–24','25–59','60–79','80–100']; vals=[bm.get(x,0) for x in order]
    riskchart=_a_chart(order,[('IP',vals,'#f97066')],180)
    nets=query('''SELECT coalesce(asn,'—') asn,coalesce(org,'—') org,count(*) n,max(risk_score) maxrisk
                  FROM scanner_observations WHERE last_seen>=? AND classification NOT IN ('CLIENT','WHITELIST')
                  GROUP BY asn,org ORDER BY n DESC,maxrisk DESC LIMIT 8''',(cutoff,))
    rows=[[esc(r['asn']),esc(r['org']),esc(r['n']),risk_badge(r['maxrisk'])] for r in nets]
    return f"<div class='grid2' style='margin-top:14px'><div class='card'><h2>Risk · распределение за 24 часа</h2>{riskchart}</div><div class='card'><h2>Подозрительные сети · 24 часа</h2>{table(['ASN','Сеть','IP','Max risk'],rows)}</div></div>"


# Preserve the existing page implementations and add analytics around them.
_a_dashboard_html=dashboard_html
def dashboard_html():
    return _a_dashboard_html()+_a_overview_trends()+"<div style='margin-top:14px'>"+_a_online_card(21600)+"</div>"

_a_stats_html=stats_html
def stats_html(period):
    return _a_daily_charts(period)+_a_stats_html(period)

_a_active_clients_html=active_clients_html
def active_clients_html():
    return _a_active_clients_html()+"<div style='margin-top:14px'>"+_a_online_card(21600)+"</div>"

_a_scanner_security_html=scanner_security_html
def scanner_security_html(user,csrf,params):
    return _a_scanner_security_html(user,csrf,params)+_a_security_analytics()


# Chart styling is injected through the already-proven page-template wrapper.
_a_page_template=page_template
def page_template(title,body,user,active='dashboard',refresh=None,message=''):
    doc=_a_page_template(title,body,user,active,refresh,message)
    css="""<style>
.a-chart-wrap{width:100%;overflow:hidden}.a-chart{width:100%;height:auto;display:block}.a-grid{stroke:#26364f;stroke-width:1}.a-axis{fill:#94a3b8;font-size:11px}.a-legend{display:flex;gap:14px;flex-wrap:wrap;margin-top:6px;color:#aebbd0;font-size:12px}.a-legend-item{display:inline-flex;align-items:center;gap:6px}.a-legend-item i{display:inline-block;width:10px;height:10px;border-radius:50%}.a-head{display:flex;justify-content:space-between;gap:12px;align-items:flex-start}
</style>"""
    return doc.replace('</head>',css+'</head>',1)
