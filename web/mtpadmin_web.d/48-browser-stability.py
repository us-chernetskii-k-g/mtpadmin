# MTPADMIN 0.12.4 browser stability guard.
#
# The legacy UI stack accumulated several independent background DOM mutators:
# - the base page replaces all of #live-root from a full-page fetch on a timer;
# - compact-ui watches #live-root and rewrites tables/tabs after mutations;
# - world-map watches #live-root and schedules map polishing after mutations.
#
# In combination these mechanisms repeatedly rebuild a large DOM tree and can
# make long-lived Firefox/mobile sessions progressively slow or unresponsive.
# 0.12.4 intentionally switches the admin panel to a stable request-driven UI:
# data is fresh when a page is opened/reloaded, while background DOM mutation is
# disabled. A later release may add small endpoint-specific polling without
# replacing the whole page.

_BS_REPLACEMENTS = (
    (
        "initDynamic(); const ms=Math.max(3000,parseInt(root.dataset.liveMs||'15000')); setInterval(()=>tick(false),ms); document.addEventListener('visibilitychange',()=>{if(!document.hidden)tick(true);}); window.addEventListener('focus',()=>tick(false));",
        "initDynamic(); /* MTPADMIN 0.12.4: background full-page live refresh disabled */",
    ),
    (
        "var root=document.getElementById('live-root');if(root)new MutationObserver(run).observe(root,{childList:true,subtree:true});",
        "/* MTPADMIN 0.12.4: compact-ui MutationObserver disabled */",
    ),
    (
        "new MutationObserver(schedule).observe(root,{subtree:true,childList:true});",
        "/* MTPADMIN 0.12.4: world-map MutationObserver disabled */",
    ),
    (
        "new MutationObserver(enhance).observe(document.documentElement,{childList:true,subtree:true});",
        "/* MTPADMIN 0.12.4: client-ui MutationObserver disabled */",
    ),
)

_bs_page_template = page_template


def page_template(title, body, user, active='dashboard', refresh=None, message=''):
    doc = _bs_page_template(title, body, user, active=active, refresh=refresh, message=message)
    for old, new in _BS_REPLACEMENTS:
        doc = doc.replace(old, new)
    # Do not advertise a background cadence that no longer exists.
    doc = re.sub(r'(<span class="live-pill" id="live-state">).*?(</span>)',
                 r'\1● по запросу\2', doc, count=1, flags=re.S)
    return doc
