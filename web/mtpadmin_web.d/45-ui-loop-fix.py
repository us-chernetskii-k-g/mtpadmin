# MTPADMIN 0.12.3 browser render-loop safety.
#
# The redesigned UI used a document-wide MutationObserver(enhance). enhance()
# writes navigation textContent, which itself creates another DOM mutation and
# can trap a browser in a self-triggering render loop.
#
# Do not wrap page_template after the release is already active. Remove the
# dangerous observer directly from the UI script while the assembled Python
# runtime is being built. The normal one-shot DOMContentLoaded enhance() stays.

_UI_LOOP_OBSERVER = "new MutationObserver(enhance).observe(document.documentElement,{childList:true,subtree:true});"
_UI_LOOP_REPLACEMENT = "/* MTPADMIN 0.12.3: self-triggering MutationObserver disabled */"

if '_CLIENT_SCRIPT' not in globals():
    raise RuntimeError('MTPADMIN UI safety: _CLIENT_SCRIPT is not available')

_count = _CLIENT_SCRIPT.count(_UI_LOOP_OBSERVER)
if _count != 1:
    raise RuntimeError(f'MTPADMIN UI safety: dangerous observer count={_count}')

_CLIENT_SCRIPT = _CLIENT_SCRIPT.replace(_UI_LOOP_OBSERVER, _UI_LOOP_REPLACEMENT, 1)
