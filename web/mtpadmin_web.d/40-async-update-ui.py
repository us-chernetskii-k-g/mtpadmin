# MTPADMIN 0.11.5 asynchronous Update Center presentation.

def _o_update_center(csrf):
    data=_o_update_status(); comps=data.get('components') or {}; rows=[]
    op=_o_component_status(); op_comp=str(op.get('component') or ''); op_state=str(op.get('state') or '')
    busy=op_state in ('queued','running')
    labels=(('mtpadmin','MTPADMIN'),('telemt','TeleMT'),('webproxy','Telegram WEB Proxy'))
    for key,label in labels:
        c=comps.get(key) or {}; cur=c.get('current') or '—'; latest=c.get('latest') or '—'; available=bool(c.get('available'))
        if key=='webproxy': cur=_o_short(cur); latest=_o_short(latest)
        is_busy=busy and op_comp==key
        if is_busy:
            status='<span class="warn"><b>Выполняется…</b></span>'
            button=f"<button class='secondary' type='button' disabled style='opacity:.55;cursor:wait'>{esc(label)} · выполняется</button>"
        else:
            status='<span class="warn"><b>Доступно обновление</b></span>' if available else ('<span class="ok">Актуально</span>' if latest!='—' else '<span class="muted">Нет данных</span>')
            verb='Обновить' if available else 'Проверить / переустановить'
            cls='warnbtn' if available else 'secondary'
            button=(f"<form class='inline' method='post' action='/action/component-update'>"
                    f"<input type='hidden' name='csrf' value='{esc(csrf)}'>"
                    f"<input type='hidden' name='component' value='{key}'>"
                    f"<button class='{cls}'>{verb} {esc(label)}</button></form>")
        rows.append([esc(label),esc(cur),esc(latest),status,button])
    checked=data.get('checked_at'); checked_txt=dt.datetime.fromtimestamp(int(checked)).strftime('%Y-%m-%d %H:%M:%S') if checked else 'ещё не проверялось'
    op_html=''
    if op:
        state=str(op.get('state') or ''); cls='ok' if state=='success' else ('bad' if state=='failed' else 'warn')
        state_label={'queued':'QUEUED','running':'RUNNING','success':'SUCCESS','failed':'FAILED'}.get(state,state.upper() or 'UNKNOWN')
        op_html=(f"<div class='ui-summary' style='margin-top:10px'>"
                 f"<span class='ui-chip {cls}'>{esc(op.get('component',''))} · {esc(state_label)}</span>"
                 f"<span class='muted'>{esc(op.get('detail',''))}</span></div>")
    checkform=f"<form class='inline' method='post' action='/action/update-check'><input type='hidden' name='csrf' value='{esc(csrf)}'><button class='secondary'>Проверить сейчас</button></form>"
    return (f"<div class='card'><div class='a-head'><div><h2>Update Center</h2><div class='muted'>Последняя проверка: {esc(checked_txt)}</div></div>{checkform}</div>"
            f"{table(['Компонент','Установлено','Доступно','Статус','Действие'],rows)}{op_html}"
            "<div class='muted' style='margin-top:10px'>Обновления запускаются отдельной системной задачей. Можно уйти со страницы: процесс продолжится сам. TeleMT использует backup/rollback, MTPADMIN — blue/green.</div></div>")
