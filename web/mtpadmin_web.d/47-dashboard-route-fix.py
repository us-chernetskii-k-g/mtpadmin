# MTPADMIN 0.12.4 dashboard route binding fix.
#
# analytics-plus owns the real HTTP route for `/` and calls a renderer snapshot
# captured earlier as `_a_dashboard_html`. The responsive client layer replaces
# `dashboard_html()` later in assembly, so without rebinding the snapshot the
# new dashboard exists in Python but the browser keeps receiving the old body.
#
# This mirrors the already-proven `/active` rebinding used by the WEB client UI.

if '_a_dashboard_html' in globals():
    _a_dashboard_html = dashboard_html
