# MTPADMIN 0.11.6 WEB Proxy link recovery + compact connection links.


def _o_webproxy_secret():
    """Read WEB_PROXY secret with the same section/key semantics as user_config.py.

    TeleMT config is edited as text by user_config.py, so the UI should not depend
    on the whole file being accepted by tomllib. Only the [access.users] entry for
    the configured WEB source is inspected.
    """
    st=_o_state(); wanted=str(st.get('WEBPROXY_SOURCE','WEB_PROXY') or 'WEB_PROXY')
    try:
        section=None
        section_re=re.compile(r'^\s*\[([^\[\]]+)\]\s*(?:#.*)?$')
        key_re=re.compile(r'^\s*(?:"'+re.escape(wanted)+r'"|'+re.escape(wanted)+r')\s*=\s*"([0-9A-Fa-f]{32})"\s*(?:#.*)?$')
        for raw in Path(CFG).read_text(encoding='utf-8').splitlines():
            m=section_re.match(raw)
            if m:
                section=m.group(1).strip(); continue
            if section!='access.users':
                continue
            m=key_re.match(raw)
            if m:
                return m.group(1).lower()
    except Exception:
        pass
    return ''


def _o_webproxy_links():
    st=_o_state(); host=str(st.get('WEBPROXY_HOST','') or '').strip().lower(); sec=_o_webproxy_secret()
    if not host or not sec:
        return {}
    q=urllib.parse.urlencode({'server':host,'secret':sec})
    return {
        'tg':'tg://webproxy?'+q,
        'https':'https://t.me/webproxy?'+q,
    }


def _o_webproxy_link():
    return _o_webproxy_links().get('https','')


def _links_mask(link):
    try:
        p=urllib.parse.urlsplit(link)
        q=urllib.parse.parse_qs(p.query)
        host=(q.get('server') or [''])[0]
        if p.scheme=='tg': return f'tg://webproxy · {host}'
        if p.netloc=='t.me' and p.path=='/webproxy': return f't.me/webproxy · {host}'
        if p.scheme in ('tg','https') and 'secret' in q: return f'{p.scheme}://… · secret скрыт'
    except Exception:
        pass
    return 'Ссылка готова · secret скрыт'


def _links_item(label, link, iid, primary=False):
    if not link: return ''
    masked=_links_mask(link)
    cls='btn' if primary else 'btn secondary'
    return (f"<div class='link-compact-row'><div><span class='tag'>{esc(label)}</span> "
            f"<span class='muted'>{esc(masked)}</span></div><div class='actions'>"
            f"<button class='{cls}' type='button' data-copy-target='{esc(iid)}' onclick=\"navigator.clipboard.writeText(document.getElementById('{esc(iid)}').textContent).then(()=>{{this.textContent='Скопировано';setTimeout(()=>this.textContent='Копировать',1200)}})\">Копировать</button>"
            f"<button class='secondary' type='button' onclick=\"var e=document.getElementById('{esc(iid)}');e.hidden=!e.hidden;this.textContent=e.hidden?'Показать':'Скрыть'\">Показать</button>"
            f"</div><div class='linkbox' id='{esc(iid)}' hidden>{esc(link)}</div></div>")


def _compact_source_links(row, idx):
    links=row.get('links') or {}; chunks=[]
    modes=(('classic','Classic'),('secure','Secure'),('tls','Fake-TLS'))
    for mode,label in modes:
        vals=links.get(mode) or []
        for j,link in enumerate(vals):
            chunks.append(_links_item(label,str(link),f'cplink_{idx}_{mode}_{j}',primary=(mode=='tls')))
    return ''.join(chunks) or '<div class="muted">Ссылок нет</div>'


def _compact_webproxy_block():
    st=_o_state(); ready=st.get('WEBPROXY_READY','0')=='1' and _o_service('tproxy-server.service') and _o_http_ok('http://127.0.0.1:8081/readyz')
    links=_o_webproxy_links(); host=st.get('WEBPROXY_HOST','')
    if not links:
        return ("<div class='card'><h2>Telegram WEB Proxy</h2><div class='warn'>Сервер " + ('READY, но ' if ready else '') +
                "клиентская ссылка пока не сформирована.</div></div>")
    qr=_o_qr(links['https'])
    status="<span class='ok'>● READY</span>" if ready else "<span class='warn'>● SETUP</span>"
    return (f"<div class='card' style='margin-bottom:12px'><div class='a-head'><div><h2>Telegram WEB Proxy</h2>"
            f"<div class='muted'>{status} · {esc(host)} · HTTPS/443</div></div>{qr}</div>"
            f"{_links_item('TG direct',links['tg'],'webproxy_tg',True)}"
            f"{_links_item('t.me',links['https'],'webproxy_https',False)}"
            "<div class='muted' style='margin-top:9px'>Обычный заход на hostname должен показывать настоящий публичный сайт. Relay активируется только WEB-capability клиента.</div></div>")


# Replace the old verbose Links page with compact cards. Full URLs are hidden by
# default so screenshots do not casually expose proxy secrets.
def links_html():
    users=source_rows(); blocks=[_compact_webproxy_block()]
    for i,u in enumerate(users):
        name=str(u.get('username',''))
        if name==str(_o_state().get('WEBPROXY_SOURCE','WEB_PROXY')):
            continue
        status="<span class='ok'>ON</span>" if u.get('enabled',True) else "<span class='bad'>OFF</span>"
        body=_compact_source_links(u,i)
        blocks.append(f"<div class='card' style='margin-bottom:12px'><div class='a-head'><h2>{esc(name)}</h2><div>{status}</div></div>{body}</div>")
    return "<div class='a-head' style='margin-bottom:10px'><div><h1>Ссылки подключения</h1><div class='muted'>Secret скрыты по умолчанию. Для телефона используйте копирование или QR.</div></div></div>"+''.join(blocks)


# Refresh WEB Proxy card in Operations with both link forms once the recovered
# secret is available.
_old_o_webproxy_card_116=_o_webproxy_card
def _o_webproxy_card(csrf):
    base=_old_o_webproxy_card_116(csrf)
    links=_o_webproxy_links()
    if not links:
        return base
    # Old card already contains the hostname controls and source. Replace only
    # the stale single-link area / message with a compact pair.
    pair=("<div class='ui-summary' style='margin-top:12px'><span class='ui-chip ok'>Клиентские ссылки готовы</span>"
          "<span class='muted'>TG direct + t.me</span></div>"
          +_links_item('TG direct',links['tg'],'op_webproxy_tg',True)
          +_links_item('t.me',links['https'],'op_webproxy_https',False))
    if "<div class='muted'>WEB link ещё не сформирован.</div>" in base:
        return base.replace("<div class='muted'>WEB link ещё не сформирован.</div>",pair,1)
    # If the old single link exists, append the two canonical forms rather than
    # exposing a raw URL immediately.
    return base+pair


_LINKS_116_STYLE=r'''
<style id="links-116-style">
.link-compact-row{border:1px solid #26364f;border-radius:10px;padding:10px;margin-top:8px;background:#0b1728}.link-compact-row>.actions{margin-top:8px}.link-compact-row .linkbox[hidden]{display:none}.link-compact-row .linkbox{margin-top:8px}.link-compact-row button{padding:6px 9px;font-size:12px}
</style>
'''
_old_page_template_116=page_template
def page_template(title,body,user,active='dashboard',refresh=None,message=''):
    doc=_old_page_template_116(title,body,user,active,refresh,message)
    if 'links-116-style' not in doc:
        doc=doc.replace('</head>',_LINKS_116_STYLE+'</head>',1)
    return doc
