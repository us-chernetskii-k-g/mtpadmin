# MTPADMIN 0.11.4 compact ergonomic UI layer.

_COMPACT_STYLE = r'''
<style id="mtpadmin-compact-style">
.wrap{max-width:1280px!important;padding:14px 18px!important}.top{margin-bottom:10px!important}.brand{font-size:22px!important}.nav{position:sticky;top:0;z-index:40;display:flex!important;flex-wrap:nowrap!important;overflow-x:auto;white-space:nowrap;padding:8px 0;margin-bottom:12px!important;background:rgba(9,17,31,.94);backdrop-filter:blur(10px);scrollbar-width:none}.nav::-webkit-scrollbar{display:none}.nav a{padding:7px 10px!important;font-size:13px}
.card{padding:13px!important}.grid,.grid2{gap:10px!important}.metric .v{font-size:23px!important}.metric .k{font-size:12px}.flash{margin-bottom:10px!important}
h1{font-size:20px!important}h2{font-size:16px!important;margin-bottom:9px!important}.footer{margin-top:12px!important}
.ui-tabs{display:flex;gap:6px;overflow-x:auto;white-space:nowrap;margin:10px 0 12px}.ui-tabs button{background:#17243a;border-color:#334763;color:#cbd5e1;padding:7px 11px}.ui-tabs button.active{background:#1d4ed8;border-color:#60a5fa;color:#fff}.ui-pane{display:none}.ui-pane.active{display:block}
.ui-table-wrap{overflow:auto;max-height:54vh;border:1px solid #26364f;border-radius:10px}.ui-table-wrap table{margin:0;min-width:720px}.ui-table-wrap th{position:sticky;top:0;background:#17243a;z-index:2}.ui-table-wrap td,.ui-table-wrap th{padding:7px 8px!important}
.ui-summary{display:flex;gap:7px;flex-wrap:wrap;margin:0 0 10px}.ui-chip{display:inline-flex;align-items:center;gap:5px;padding:5px 8px;border-radius:999px;border:1px solid #334763;background:#0d1829;font-size:12px}.ui-chip.ok{color:#32d583}.ui-chip.warn{color:#fdb022}.ui-chip.bad{color:#f97066}
details.ui-details{border:1px solid #26364f;border-radius:11px;background:#0d1829;margin:8px 0;overflow:hidden}details.ui-details>summary{cursor:pointer;padding:10px 12px;font-weight:650;list-style:none}details.ui-details>summary::-webkit-details-marker{display:none}details.ui-details>.ui-details-body{padding:0 12px 12px}
@media(max-width:700px){.wrap{padding:10px!important}.top{align-items:flex-start}.user{font-size:11px}.grid{grid-template-columns:repeat(2,1fr)!important}.nav a{padding:7px 9px!important}.ui-table-wrap{max-height:60vh}}@media(max-width:480px){.grid{grid-template-columns:1fr!important}}
</style>
'''

_COMPACT_SCRIPT = r'''
<script id="mtpadmin-compact-script">
(function(){
  function wrapTables(root){
    (root||document).querySelectorAll('table').forEach(function(t){
      if(t.closest('.ui-table-wrap'))return;
      if(t.rows && t.rows.length<=4)return;
      var w=document.createElement('div');w.className='ui-table-wrap';t.parentNode.insertBefore(w,t);w.appendChild(t);
    });
  }
  function tabs(){
    document.querySelectorAll('[data-ui-tabs]').forEach(function(bar){
      if(bar.dataset.bound)return;bar.dataset.bound='1';
      var key='mtpadmin-tab:'+location.pathname;var buttons=Array.from(bar.querySelectorAll('[data-ui-tab]'));
      function show(name){
        buttons.forEach(function(b){b.classList.toggle('active',b.dataset.uiTab===name)});
        var host=bar.parentElement;host.querySelectorAll(':scope > .ui-pane').forEach(function(p){p.classList.toggle('active',p.dataset.uiPane===name)});
        try{sessionStorage.setItem(key,name)}catch(e){}
      }
      buttons.forEach(function(b){b.addEventListener('click',function(){show(b.dataset.uiTab)})});
      var saved='';try{saved=sessionStorage.getItem(key)||''}catch(e){};if(!buttons.some(function(b){return b.dataset.uiTab===saved}))saved=buttons[0]?buttons[0].dataset.uiTab:'';if(saved)show(saved);
    });
  }
  function run(){wrapTables(document);tabs()}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',run);else run();
  var root=document.getElementById('live-root');if(root)new MutationObserver(run).observe(root,{childList:true,subtree:true});
})();
</script>
'''

_old_page_template_114 = page_template

def page_template(title, body, user, active="dashboard", refresh=None, message=""):
    html = _old_page_template_114(title, body, user, active=active, refresh=refresh, message=message)
    if 'mtpadmin-compact-style' not in html:
        html = html.replace('</head>', _COMPACT_STYLE + '</head>', 1)
    if 'mtpadmin-compact-script' not in html:
        html = html.replace('</body>', _COMPACT_SCRIPT + '</body>', 1)
    return html

# Rebuild only the presentation of Operations; existing actions/helpers remain unchanged.
_old_o_operations_html_114 = _o_operations_html

def _o_operations_html(user, csrf):
    score, checks = _o_health(); cls='ok' if score>=90 else ('warn' if score>=70 else 'bad')
    st=_o_state(); current=st.get('MTPADMIN_VERSION',VERSION)
    learning=scalar("SELECT count(*) FROM scanner_observations WHERE risk_score>=70 AND classification NOT IN ('CLIENT','WHITELIST','BANNED')",(),0)
    updates=int((_o_update_status().get('updates') or 0))
    wp_ready=st.get('WEBPROXY_READY','0')=='1' and _o_service('tproxy-server.service') and _o_http_ok('http://127.0.0.1:8081/readyz')
    metrics=f"""<div class='grid'>
<div class='card metric'><div class='k'>Health</div><div class='v {cls}'>{score}/100</div><div class='muted'>состояние сервисов</div></div>
<div class='card metric'><div class='k'>MTPADMIN</div><div class='v'>{esc(current)}</div><div class='muted'>blue/green</div></div>
<div class='card metric'><div class='k'>WEB Proxy</div><div class='v {'ok' if wp_ready else 'warn'}'>{'READY' if wp_ready else 'SETUP'}</div><div class='muted'>{esc(st.get('WEBPROXY_HOST','не настроен'))}</div></div>
<div class='card metric'><div class='k'>Обновления</div><div class='v {'warn' if updates else 'ok'}'>{updates}</div><div class='muted'>{'доступны' if updates else 'актуально'}</div></div></div>"""
    chips=''.join(f"<span class='ui-chip {'ok' if ok else 'bad'}'>{'●' if ok else '×'} {esc(name)}</span>" for name,ok in [(r[0], 'PASS' in r[1]) for r in checks])
    overview=f"""<div class='ui-pane active' data-ui-pane='overview'><div class='card'><h2>Состояние</h2><div class='ui-summary'>{chips}</div><div class='muted'>Guard learning: {esc(learning)} адресов с Risk ≥70 · autoban OFF.</div></div></div>"""
    updates_p=f"<div class='ui-pane' data-ui-pane='updates'>{_o_update_center(csrf)}</div>"
    web_p=f"<div class='ui-pane' data-ui-pane='webproxy'>{_o_webproxy_card(csrf)}</div>"
    guard_p=f"<div class='ui-pane' data-ui-pane='guard'><div class='card'><h2>Scanner Guard · Learning Mode</h2><div class='muted' style='margin-bottom:8px'>Только симуляция — автоматических блокировок нет.</div>{_o_learning()}</div></div>"
    details=f"""<div class='ui-pane' data-ui-pane='details'><div class='grid2'><div class='card'><h2>Health checks</h2>{table(['Компонент','Статус'],checks)}</div><div class='card'><h2>Последние backup</h2>{_o_backups()}</div></div></div>"""
    tabs="""<div class='ui-tabs' data-ui-tabs><button type='button' data-ui-tab='overview'>Обзор</button><button type='button' data-ui-tab='updates'>Обновления</button><button type='button' data-ui-tab='webproxy'>WEB Proxy</button><button type='button' data-ui-tab='guard'>Guard</button><button type='button' data-ui-tab='details'>Подробности</button></div>"""
    return metrics+tabs+overview+updates_p+web_p+guard_p+details
