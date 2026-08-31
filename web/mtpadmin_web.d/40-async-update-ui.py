# MTPADMIN 0.11.12 asynchronous Update Center presentation.
# Each component has its own POST route. The component is no longer taken from
# mutable form fields, so live refresh or browser autofill cannot redirect an
# MTPADMIN update into TeleMT/WEB Proxy (or vice versa).

def _o_update_center(csrf):
    data=_o_update_status(); comps=data.get('components') or {}; rows=[]
    op=_o_component_status(); op_comp=str(op.get('component') or ''); op_state=str(op.get('state') or '')
    busy=op_state in ('queued','running')
    labels=(('mtpadmin','MTPADMIN'),('telemt','TeleMT'),('webproxy','Telegram WEB Proxy'))
    for key,label in labels:
        c=comps.get(key) or {}; cur=c.get('current') or '—'; latest=c.get('latest') or '—'; available=bool(c.get('available'))
        if key=='webproxy': cur=_o_short(cur); latest=_o_short(latest)
        if busy:
            if op_comp==key:
                status='<span class="warn"><b>Выполняется…</b></span>'
                text=f'{label} · выполняется'
            else:
                status='<span class="muted">Ожидание текущей операции</span>'
                text=f'{label} · недоступно'
            button=f"<button class='secondary' type='button' disabled style='opacity:.55;cursor:wait'>{esc(text)}</button>"
        else:
            status='<span class="warn"><b>Доступно обновление</b></span>' if available else ('<span class="ok">Актуально</span>' if latest!='—' else '<span class="muted">Нет данных</span>')
            verb='Обновить' if available else 'Проверить / переустановить'
            cls='warnbtn' if available else 'secondary'
            button=(f"<form class='inline component-update-form' method='post' action='/action/component-update/{esc(key)}' data-component='{esc(key)}'>"
                    f"<input type='hidden' name='csrf' value='{esc(csrf)}'>"
                    f"<button class='{cls}' type='submit'>{verb} {esc(label)}</button></form>")
        rows.append([esc(label),esc(cur),esc(latest),status,button])
    checked=data.get('checked_at'); checked_txt=dt.datetime.fromtimestamp(int(checked)).strftime('%Y-%m-%d %H:%M:%S') if checked else 'ещё не проверялось'
    op_html=''
    if op:
        state=str(op.get('state') or ''); cls='ok' if state=='success' else ('bad' if state=='failed' else 'warn')
        state_label={'queued':'QUEUED','running':'RUNNING','success':'SUCCESS','failed':'FAILED'}.get(state,state.upper() or 'UNKNOWN')
        op_html=(f"<div class='ui-summary' style='margin-top:10px'>"
                 f"<span class='ui-chip {cls}'>{esc(op.get('component',''))} · {esc(state_label)}</span>"
                 f"<span class='muted'>{esc(op.get('detail',''))}</span></div>")
    check_disabled=' disabled style="opacity:.55;cursor:wait"' if busy else ''
    checkform=f"<form class='inline' method='post' action='/action/update-check'><input type='hidden' name='csrf' value='{esc(csrf)}'><button class='secondary'{check_disabled}>Проверить сейчас</button></form>"
    return (f"<div class='card'><div class='a-head'><div><h2>Update Center</h2><div class='muted'>Последняя проверка: {esc(checked_txt)}</div></div>{checkform}</div>"
            f"{table(['Компонент','Установлено','Доступно','Статус','Действие'],rows)}{op_html}"
            "<div class='muted' style='margin-top:10px'>Одновременно выполняется только одна операция. Можно уйти со страницы: системная задача продолжится сама. TeleMT использует backup/rollback, MTPADMIN — blue/green.</div></div>")


# Route-safe component update handler. The component comes exclusively from the
# URL path generated above; POST body contains only CSRF. This intentionally
# overrides the older generic /action/component-update handler from 38-operations.
_au_post_prev = Handler.do_POST

def _au_do_POST(self):
    path=urllib.parse.urlsplit(self.path).path
    prefix='/action/component-update/'
    # A stale pre-0.11.12 tab may still submit the old generic form. Never let
    # that request reach the legacy field-based handler; force a page reload.
    if path=='/action/component-update':
        if not self.require_user(): return
        self.send_html('Обновите страницу',"<div class='card'><h1>Форма обновления устарела</h1><p>Обновите страницу «Операции» и повторите действие. Компонент не запускался.</p><p><a class='btn' href='/operations'>Открыть Update Center</a></p></div>",'operations',409)
        return
    if not path.startswith(prefix):
        return _au_post_prev(self)
    if not self.require_user(): return
    try:
        comp=path[len(prefix):]
        if comp not in ('mtpadmin','telemt','webproxy') or '/' in comp:
            raise ValueError('Неизвестный компонент')
        f=self.form()
        if not csrf_ok(self.user(),f.get('csrf','')):
            self.send_html('CSRF','<div class="card"><h1>Запрос отклонён</h1></div>','operations',403); return
        rc,out=run([_O_COMPONENT,'dispatch',comp],timeout=10)
        if rc: raise RuntimeError(out or 'Не удалось запустить обновление')
        self.redirect('/operations',f'Обновление {comp} запущено в фоне')
    except Exception as e:
        self.send_html('Ошибка действия',f'<div class="card"><h1>Действие не выполнено</h1><pre>{esc(type(e).__name__+": "+str(e))}</pre><p><a class="btn secondary" href="/operations">Назад</a></p></div>','operations',400)

Handler.do_POST=_au_do_POST


# Global live-refresh safety. Hidden fields are server-authored action data
# (CSRF, source name, component, etc.) and must never be restored from a stale
# DOM snapshot. Only visible/editable controls are preserved across refresh.
_au_page_template_prev = page_template

def page_template(title, body, user, active="dashboard", refresh=None, message=""):
    doc = _au_page_template_prev(title, body, user, active=active, refresh=refresh, message=message)
    old_controls = "function controls(){const out={}; root.querySelectorAll('input,select,textarea').forEach((e,i)=>{const k=e.id||e.name||('i'+i); if(e.type==='checkbox'||e.type==='radio')out[k]={c:e.checked};else out[k]={v:e.value};}); return out;}"
    old_restore = "function restore(s){root.querySelectorAll('input,select,textarea').forEach((e,i)=>{const k=e.id||e.name||('i'+i),v=s[k]; if(!v)return; if('c'in v)e.checked=v.c;else if('v'in v)e.value=v.v;});}"
    new_controls = "function controls(){const out={}; const els=[...root.querySelectorAll('input:not([type=hidden]),select,textarea')]; els.forEach((e,i)=>{const k=e.id||((e.form?.action||'')+'|'+(e.name||e.tagName)+'|'+i); if(e.type==='checkbox'||e.type==='radio')out[k]={c:e.checked};else out[k]={v:e.value};}); return out;}"
    new_restore = "function restore(s){const els=[...root.querySelectorAll('input:not([type=hidden]),select,textarea')]; els.forEach((e,i)=>{const k=e.id||((e.form?.action||'')+'|'+(e.name||e.tagName)+'|'+i),v=s[k]; if(!v)return; if('c'in v)e.checked=v.c;else if('v'in v)e.value=v.v;});}"
    if old_controls not in doc or old_restore not in doc:
        raise RuntimeError('live-refresh control contract changed')
    return doc.replace(old_controls,new_controls,1).replace(old_restore,new_restore,1)
