GUARD_PY = "/usr/local/lib/mtpadmin/scanner_guard.py"


def _fmt_epoch(v):
    try:
        return dt.datetime.fromtimestamp(int(v)).strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return "—"


def _guard_class_badge(v):
    v = str(v or "UNKNOWN")
    cls = "ok" if v in ("CLIENT", "WHITELIST") else ("bad" if v in ("SCAN", "BANNED") else "warn")
    return f'<span class="{cls}">{esc(v)}</span>'


def _guard_form(csrf, action, ip, label, css="secondary", duration="", confirm=""):
    extra = f'<input type="hidden" name="duration" value="{esc(duration)}">' if duration else ""
    confirm_attr = f' onsubmit="return confirm(\'{esc(confirm)}\')"' if confirm else ""
    return (f'<form class="inline" method="post" action="{action}"{confirm_attr}>'
            f'<input type="hidden" name="csrf" value="{esc(csrf)}">'
            f'<input type="hidden" name="ip" value="{esc(ip)}">{extra}'
            f'<button class="{css}">{esc(label)}</button></form>')


def security_html(user, csrf):
    now = int(time.time())
    rc, _ = run(["systemctl", "is-active", "--quiet", "mtpadmin-scanner.service"], timeout=5)
    service = '<span class="ok">● ACTIVE</span>' if rc == 0 else '<span class="bad">● OFFLINE</span>'
    hb = scalar("SELECT value FROM scanner_meta WHERE key='heartbeat'", default=0)
    try:
        hb_age = max(0, now - int(hb)) if hb else None
    except Exception:
        hb_age = None
    classes = query("SELECT classification,count(*) n FROM scanner_observations WHERE last_seen>=? GROUP BY classification", (now - 86400,))
    counts = {str(x.get('classification')): int(x.get('n') or 0) for x in classes}
    bans = query("SELECT ip,created_at,expires_at,reason,actor FROM scanner_bans WHERE active=1 AND (expires_at IS NULL OR expires_at>?) ORDER BY created_at DESC", (now,))
    white = query("SELECT ip,created_at,note,actor FROM scanner_whitelist ORDER BY created_at DESC LIMIT 100")
    suspicious = query("""SELECT ip,classification,total_attempts,first_seen,last_seen,country_code,city,asn,org
        FROM scanner_observations
        WHERE last_seen>=? AND classification IN ('SCAN','HOSTING?','UNKNOWN')
          AND (classification!='UNKNOWN' OR total_attempts>=2)
        ORDER BY CASE classification WHEN 'SCAN' THEN 0 WHEN 'HOSTING?' THEN 1 ELSE 2 END,
                 total_attempts DESC,last_seen DESC LIMIT 150""", (now - 86400,))
    audit_rows = query("SELECT ts,actor,action,ip,detail FROM scanner_audit ORDER BY ts DESC LIMIT 30")

    cards = f"""<div class='grid'>
<div class='card metric'><div class='k'>Scanner Guard</div><div class='v'>{service}</div><div class='muted'>heartbeat: {esc(str(hb_age)+' сек' if hb_age is not None else 'нет')}</div></div>
<div class='card metric'><div class='k'>SCAN · 24 часа</div><div class='v bad'>{counts.get('SCAN',0)}</div><div class='muted'>повторные SYN без успешного клиента</div></div>
<div class='card metric'><div class='k'>Клиенты · 24 часа</div><div class='v ok'>{counts.get('CLIENT',0)}</div><div class='muted'>подтверждены TeleMT</div></div>
<div class='card metric'><div class='k'>Блокировки</div><div class='v'>{len(bans)}</div><div class='muted'>автобан: OFF · whitelist: {len(white)}</div></div>
</div>"""

    intro = """<div class='card' style='margin-top:14px'><h2>Как читать статусы</h2>
<div class='muted'>Scanner Guard наблюдает только новые TCP-подключения к порту MTProxy и сверяет их с IP, которые TeleMT признал клиентами. <b>SCAN</b> и <b>HOSTING?</b> — эвристические метки, а не доказательство принадлежности IP Роскомнадзору, ТСПУ или другой организации. В версии 0.6.0 автоматическая блокировка намеренно отключена.</div></div>"""

    srows=[]
    for r in suspicious:
        ip=str(r.get('ip') or '')
        acts=(
            _guard_form(csrf,'/action/guard-ban',ip,'24 ч','warnbtn','24h',f'Заблокировать {ip} на 24 часа?')+
            _guard_form(csrf,'/action/guard-ban',ip,'7 дней','warnbtn','7d',f'Заблокировать {ip} на 7 дней?')+
            _guard_form(csrf,'/action/guard-ban',ip,'Навсегда','danger','permanent',f'Постоянно заблокировать {ip}?')+
            _guard_form(csrf,'/action/guard-whitelist',ip,'Whitelist','secondary',confirm=f'Добавить {ip} в whitelist?')
        )
        srows.append([
            _guard_class_badge(r.get('classification')),esc(ip),esc(r.get('total_attempts',0)),
            esc(r.get('country_code','')),esc(r.get('city','')),esc(r.get('asn','')),esc(r.get('org','')),
            esc(_fmt_epoch(r.get('first_seen'))),esc(_fmt_epoch(r.get('last_seen'))),acts
        ])
    suspect_box = "<div class='card' style='margin-top:14px'><h2>Подозрительные обращения · последние 24 часа</h2>" + table(
        ['Статус','IP','SYN','CC','Город','ASN','Сеть','Первый','Последний','Действия'], srows) + "</div>"

    manual = f"""<div class='card' style='margin-top:14px'><h2>Ручная блокировка</h2>
<form method='post' action='/action/guard-ban'><input type='hidden' name='csrf' value='{esc(csrf)}'><div class='formgrid'>
<div><label>IP</label><input name='ip' required placeholder='1.2.3.4'></div>
<div><label>Срок</label><select name='duration'><option value='24h'>24 часа</option><option value='7d'>7 дней</option><option value='30d'>30 дней</option><option value='permanent'>Навсегда</option></select></div>
<div><label>Причина</label><input name='reason' maxlength='120' placeholder='manual'></div></div>
<div style='margin-top:12px'><button class='danger'>Заблокировать</button></div></form></div>"""

    brows=[]
    for r in bans:
        ip=str(r.get('ip') or '')
        exp='Навсегда' if not r.get('expires_at') else _fmt_epoch(r.get('expires_at'))
        brows.append([esc(ip),esc(_fmt_epoch(r.get('created_at'))),esc(exp),esc(r.get('reason','')),esc(r.get('actor','')),
                      _guard_form(csrf,'/action/guard-unban',ip,'Разблокировать','secondary',confirm=f'Разблокировать {ip}?')])
    ban_box = "<div class='card'><h2>Активные блокировки</h2>"+table(['IP','Создано','До','Причина','Кем',''],brows)+"</div>"

    wrows=[]
    for r in white:
        ip=str(r.get('ip') or '')
        wrows.append([esc(ip),esc(_fmt_epoch(r.get('created_at'))),esc(r.get('note','')),esc(r.get('actor','')),
                      _guard_form(csrf,'/action/guard-unwhitelist',ip,'Удалить','secondary',confirm=f'Удалить {ip} из whitelist?')])
    white_box = "<div class='card'><h2>Whitelist</h2>"+table(['IP','Добавлен','Примечание','Кем',''],wrows)+"</div>"

    arows=[[esc(_fmt_epoch(r.get('ts'))),esc(r.get('actor','')),esc(r.get('action','')),esc(r.get('ip','')),esc(r.get('detail',''))] for r in audit_rows]
    audit_box = "<div class='card' style='margin-top:14px'><h2>Журнал действий</h2>"+table(['Время','Кем','Действие','IP','Подробности'],arows)+"</div>"
    return cards+intro+suspect_box+manual+"<div class='grid2' style='margin-top:14px'>"+ban_box+white_box+"</div>"+audit_box


def _safe_guard_ip(v):
    try:
        a=ipaddress.ip_address((v or '').strip())
    except ValueError:
        raise ValueError('Некорректный IP')
    if a.is_loopback or a.is_unspecified or a.is_multicast or a.is_link_local or not a.is_global:
        raise ValueError('Разрешены только публичные IP')
    st=state(); own=st.get('PUBLIC_IP','')
    if own and a == ipaddress.ip_address(own):
        raise ValueError('IP самого сервера блокировать запрещено')
    return str(a)


def handle_guard_post(handler, path, f):
    if not path.startswith('/action/guard-'):
        return False
    ip=_safe_guard_ip(f.get('ip')); actor=('web:'+handler.user())[:80]
    if path=='/action/guard-ban':
        duration=(f.get('duration') or '24h').strip().lower()
        if duration not in {'30m','24h','7d','30d','permanent'}: raise ValueError('Некорректный срок блокировки')
        reason=(f.get('reason') or 'web manual').strip()[:120]
        rc,out=run([GUARD_PY,'ban',ip,duration,'--reason',reason,'--actor',actor],timeout=20)
    elif path=='/action/guard-unban':
        rc,out=run([GUARD_PY,'unban',ip,'--actor',actor],timeout=20)
    elif path=='/action/guard-whitelist':
        rc,out=run([GUARD_PY,'whitelist',ip,'--note','web manual','--actor',actor],timeout=20)
    elif path=='/action/guard-unwhitelist':
        rc,out=run([GUARD_PY,'unwhitelist',ip,'--actor',actor],timeout=20)
    else:
        return False
    if rc: raise RuntimeError(out)
    handler.redirect('/guard',out); return True


# Redirect the existing Security tab to the richer Scanner Guard page.
_page_template_base = page_template
def page_template(title, body, user, active="dashboard", refresh=None, message=""):
    doc = _page_template_base(title, body, user, active, refresh, message)
    return doc.replace('href="/security">Безопасность</a>', 'href="/guard">Безопасность</a>')
