# MTPADMIN 0.12.1 browser UI safety hotfix.
#
# The 0.12.0 presentation layer used a document-wide MutationObserver that
# called enhance() after every DOM mutation. enhance() itself normalised the
# navigation labels with textContent assignments, which generated another
# mutation and could trap the browser in a self-triggering render loop.
#
# Keep the rest of the 0.12.0 UI unchanged, but strip that observer from the
# final HTML response. The initial DOMContentLoaded/one-shot enhance() remains,
# so branding, navigation labels, user badge and responsive shell are still
# applied. Live MTPADMIN content refresh does not replace those shell elements.

_UI_LOOP_OBSERVER = "new MutationObserver(enhance).observe(document.documentElement,{childList:true,subtree:true});"
_UI_LOOP_REPLACEMENT = "/* MTPADMIN 0.12.1: self-triggering MutationObserver disabled */"
_ui_loop_base_page_template = page_template


def page_template(title, body, user, active='dashboard', refresh=None, message=''):
    doc = _ui_loop_base_page_template(
        title,
        body,
        user,
        active=active,
        refresh=refresh,
        message=message,
    )
    if _UI_LOOP_OBSERVER in doc:
        doc = doc.replace(_UI_LOOP_OBSERVER, _UI_LOOP_REPLACEMENT, 1)
    return doc
