    crows = [[esc(x.get("country_code")), esc(x.get("country_name")), esc(x.get("u")), esc(x.get("s"))] for x in countries]
    return cards + f"<div class='grid2' style='margin-top:14px'><div class='card'><h2>Источники</h2>{table(['Источник','Статус','Соединения','IP','Трафик'],sources)}</div><div class='card'><h2>Страны сегодня</h2>{table(['Код','Страна','Уникальных','Сеансов'],crows)}</div></div>"


def stats_html(period):
    start, end = period_bounds(period)
    rows = query("SELECT day, count(DISTINCT ip_hash) uniq, sum(observations) sessions FROM anon_visits WHERE day BETWEEN ? AND ? GROUP BY day ORDER BY day DESC", (start, end))
    traffic = query("SELECT day, sum(connections) connections, sum(bad_connections) bad, sum(bytes_from_client) bfrom, sum(bytes_to_client) bto FROM daily_traffic WHERE day BETWEEN ? AND ? GROUP BY day ORDER BY day DESC", (start, end))
    r1 = [[esc(r['day']), esc(r['uniq']), esc(r['sessions'])] for r in rows]
    r2 = [[esc(r['day']), esc(r['connections']), esc(r['bad']), human_bytes(r['bfrom']), human_bytes(r['bto'])] for r in traffic]
    opts = " ".join(f'<a class="btn {"" if k==period else "secondary"}" href="/stats?period={k}">{esc(v)}</a>' for k,v in PERIODS.items())
    return f"<div class='actions' style='margin-bottom:12px'>{opts}</div><div class='grid2'><div class='card'><h2>Клиенты · {esc(PERIODS.get(period,period))}</h2>{table(['День','Уникальных','Сеансов'],r1)}</div><div class='card'><h2>Трафик</h2>{table(['День','Соединения','Ошибки','От клиента','К клиенту'],r2)}</div></div>"


def clients_html():
    rows = query("SELECT ip,country_code,city,asn,org,first_seen,last_seen,hits FROM clients ORDER BY last_seen DESC LIMIT 300")
    out = []
    for r in rows:
        fs = dt.datetime.fromtimestamp(r['first_seen']).strftime('%Y-%m-%d %H:%M:%S') if r.get('first_seen') else ''
        ls = dt.datetime.fromtimestamp(r['last_seen']).strftime('%Y-%m-%d %H:%M:%S') if r.get('last_seen') else ''
        out.append([esc(r['ip']),esc(r.get('country_code','')),esc(r.get('city','')),esc(r.get('asn','')),esc(r.get('org','')),esc(fs),esc(ls),esc(r.get('hits',0))])
    return "<div class='card'><h1>Клиенты / история IP</h1><div class='muted' style='margin-bottom:10px'>Полные IP хранятся ограниченный срок согласно настройке retention.</div>" + table(['IP','CC','Город','ASN','Провайдер / сеть','Первый','Последний','Набл.'],out) + "</div>"


def geo_html(period):
    start,end = period_bounds(period)
    countries=query("SELECT country_code,country_name,count(DISTINCT ip_hash) u,sum(observations) s FROM anon_visits WHERE day BETWEEN ? AND ? GROUP BY country_code,country_name ORDER BY u DESC,s DESC LIMIT 40",(start,end))
    cities=query("SELECT city,region,country_code,count(DISTINCT ip_hash) u,sum(observations) s FROM anon_visits WHERE day BETWEEN ? AND ? AND coalesce(city,'')!='' GROUP BY city,region,country_code ORDER BY u DESC,s DESC LIMIT 60",(start,end))
    providers=query("SELECT asn,org,count(DISTINCT ip_hash) u,sum(observations) s FROM anon_visits WHERE day BETWEEN ? AND ? AND coalesce(asn,'')!='' GROUP BY asn,org ORDER BY u DESC,s DESC LIMIT 60",(start,end))
    opts=" ".join(f'<a class="btn {"" if k==period else "secondary"}" href="/geo?period={k}">{esc(v)}</a>' for k,v in PERIODS.items())
    return f"<div class='actions' style='margin-bottom:12px'>{opts}</div><div class='card'><h2>Страны</h2>{table(['Код','Страна','Уникальных','Сеансов'],[[esc(x['country_code']),esc(x['country_name']),esc(x['u']),esc(x['s'])] for x in countries])}</div><div class='grid2' style='margin-top:14px'><div class='card'><h2>Города</h2>{table(['Город','Регион','CC','Уникальных','Сеансов'],[[esc(x['city']),esc(x['region']),esc(x['country_code']),esc(x['u']),esc(x['s'])] for x in cities])}</div><div class='card'><h2>Провайдеры / ASN</h2>{table(['ASN','Сеть','Уникальных','Сеансов'],[[esc(x['asn']),esc(x['org']),esc(x['u']),esc(x['s'])] for x in providers])}</div></div>"


def source_links_html(row, idx):
    links = row.get("links") or {}
    parts=[]
    for mode,label in (("classic","Classic"),("secure","Secure"),("tls","Fake-TLS")):
        for link in links.get(mode) or []:
            iid=f"lnk{idx}_{mode}_{len(parts)}"
            parts.append(f'<div><span class="tag">{label}</span><div class="linkbox" id="{iid}">{esc(link)}</div><button class="secondary" onclick="copyText(\'{iid}\')">Копировать</button></div>')
    return "".join(parts) or '<div class="muted">Ссылок нет</div>'


def sources_html(user, csrf):
    st=state(); primary=st.get('PROFILE','MAIN'); users=source_rows()
    rows=[]
    for i,u in enumerate(users):
        name=str(u.get('username',''))
        status='<span class="ok">ON</span>' if u.get('enabled',True) else '<span class="bad">OFF</span>'
        actions=[]
        if u.get('enabled',True):
            actions.append(f'<form class="inline" method="post" action="/action/source-disable"><input type="hidden" name="csrf" value="{csrf}"><input type="hidden" name="name" value="{esc(name)}"><button class="warnbtn">Отключить</button></form>')
        else:
            actions.append(f'<form class="inline" method="post" action="/action/source-enable"><input type="hidden" name="csrf" value="{csrf}"><input type="hidden" name="name" value="{esc(name)}"><button>Включить</button></form>')
        actions.append(f'<form class="inline" method="post" action="/action/source-rotate" onsubmit="return confirm(\'Сменить secret источника {esc(name)}? Старые ссылки сразу перестанут работать.\')"><input type="hidden" name="csrf" value="{csrf}"><input type="hidden" name="name" value="{esc(name)}"><button class="warnbtn">Сменить secret</button></form>')
        if name != primary:
            actions.append(f'<form class="inline" method="post" action="/action/source-delete" onsubmit="return confirm(\'Удалить источник {esc(name)}?\')"><input type="hidden" name="csrf" value="{csrf}"><input type="hidden" name="name" value="{esc(name)}"><button class="danger">Удалить</button></form>')
        rows.append([esc(name),status,esc(u.get('current_connections',0)),esc(u.get('active_unique_ips',0)),esc(u.get('max_tcp_conns') or '—'),esc(u.get('max_unique_ips') or '—'),''.join(actions)])
    add=f"""<div class='card' style='margin-bottom:14px'><h2>Добавить источник</h2><form method='post' action='/action/source-add'><input type='hidden' name='csrf' value='{csrf}'><div class='formgrid'>
<div><label>Имя</label><input name='name' required placeholder='SITE или TG_AD_01'></div><div><label>Отдельный ad tag (необязательно)</label><input name='ad_tag' maxlength='32'></div>
<div><label>Макс. соединений</label><input name='max_conns' inputmode='numeric'></div><div><label>Макс. уникальных IP</label><input name='max_ips' inputmode='numeric'></div></div><div style='margin-top:12px'><button>Создать источник</button></div></form></div>"""
    return add+"<div class='card'><h1>Источники / secrets</h1>"+table(['Источник','Статус','Соед.','IP','Макс. соед.','Макс. IP','Действия'],rows)+"</div>"


def links_html():
    users=source_rows(); blocks=[]
    for i,u in enumerate(users):
        blocks.append(f"<div class='card' style='margin-bottom:12px'><h2>{esc(u.get('username'))} · {'ON' if u.get('enabled',True) else 'OFF'}</h2>{source_links_html(u,i)}</div>")
    return "<h1>Ссылки подключения</h1>"+''.join(blocks)


def command_panel(title, command, active, extra=""):
    rc,out=cli(*command,timeout=35)
    cls='ok' if rc==0 else 'bad'
    return f"<div class='card'><h1>{esc(title)}</h1>{extra}<div class='{cls}' style='margin-bottom:8px'>Код выполнения: {rc}</div><pre>{esc(out)}</pre></div>"


class Handler(BaseHTTPRequestHandler):
    server_version = "MTPADMIN-Web"

    def log_message(self, fmt, *args):
        # Never log query strings or POST bodies. Keep only method/path/status to journal.
        path = urllib.parse.urlsplit(self.path).path
        print(f"{self.address_string()} {self.command} {path}")

    def user(self):
        return (self.headers.get("X-MTPADMIN-User") or "").strip()

    def send_html(self, title, body, active="dashboard", status=200, refresh=None, message=""):
        user=self.user()
        data=page_template(title,body,user,active,refresh,message).encode()
        self.send_response(status)
        self.send_header("Content-Type","text/html; charset=utf-8")
        self.send_header("Content-Length",str(len(data)))
        self.send_header("Cache-Control","no-store")
        self.send_header("X-Content-Type-Options","nosniff")
        self.send_header("X-Frame-Options","DENY")
        self.send_header("Referrer-Policy","no-referrer")
        self.end_headers(); self.wfile.write(data)

    def require_user(self):
        if not self.user():
            self.send_error(HTTPStatus.FORBIDDEN, "Access only through authenticated Caddy proxy")
            return False
        return True

    def redirect(self, where, message=""):
        if message:
            sep='&' if '?' in where else '?'
            where += sep + urllib.parse.urlencode({'msg':message})
        self.send_response(303); self.send_header('Location',where); self.end_headers()

    def params(self):
        q=urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        return {k:v[-1] for k,v in q.items() if v}

    def form(self):
        try:
            n=int(self.headers.get('Content-Length','0'))
        except ValueError: n=0
        if n<0 or n>65536: raise ValueError('Слишком большой запрос')
        raw=self.rfile.read(n).decode('utf-8','replace')
        q=urllib.parse.parse_qs(raw,keep_blank_values=True)
        return {k:v[-1] for k,v in q.items() if v}

    def do_GET(self):
        if not self.require_user(): return
        path=urllib.parse.urlsplit(self.path).path
        p=self.params(); msg=p.get('msg','')
        try:
            if path=='/': self.send_html('Обзор',dashboard_html(),'dashboard',refresh=10,message=msg)
            elif path=='/stats':
                period=p.get('period','7d'); period=period if period in PERIODS else '7d'
                self.send_html('Статистика',stats_html(period),'stats',message=msg)
            elif path=='/clients': self.send_html('Клиенты',clients_html(),'clients',message=msg)
            elif path=='/geo':
                period=p.get('period','today'); period=period if period in PERIODS else 'today'
                self.send_html('География',geo_html(period),'geo',message=msg)
            elif path=='/sources': self.send_html('Источники',sources_html(self.user(),csrf_token(self.user())),'sources',message=msg)
            elif path=='/links': self.send_html('Ссылки',links_html(),'links',message=msg)
            elif path=='/security': self.send_html('Безопасность',command_panel('Безопасность',['security'],'security'),'security',message=msg)
            elif path=='/system':
                tok=csrf_token(self.user())
                actions=f"""<div class='card' style='margin-bottom:14px'><h2>Действия</h2><div class='actions'>
<form class='inline' method='post' action='/action/backup'><input type='hidden' name='csrf' value='{tok}'><button>Создать backup</button></form>
<form class='inline' method='post' action='/action/geo-update'><input type='hidden' name='csrf' value='{tok}'><button class='secondary'>Обновить GeoIP</button></form>
<form class='inline' method='post' action='/action/restart' onsubmit="return confirm('Перезапустить TeleMT? Активные соединения кратковременно оборвутся.')"><input type='hidden' name='csrf' value='{tok}'><button class='warnbtn'>Перезапустить TeleMT</button></form>
</div></div>"""
                body=actions+"<div class='grid2'>"+command_panel('Диагностика',['doctor'],'system')+command_panel('Ресурсы',['resources'],'system')+"</div>"+command_panel('Последние логи',['logs','120'],'system')
                self.send_html('Система',body,'system',message=msg)
