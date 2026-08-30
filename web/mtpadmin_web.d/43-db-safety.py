# MTPADMIN 0.11.8 database safety/observability.
# Do not silently turn SQLite failures into believable zero statistics.

_DB_QUERY_LAST_ERROR=''
_DB_QUERY_LAST_ERROR_TS=0
_DB_QUERY_LAST_LOG=0


def query(sql,params=()):
    global _DB_QUERY_LAST_ERROR,_DB_QUERY_LAST_ERROR_TS,_DB_QUERY_LAST_LOG
    con=None
    try:
        con=db_connect(); con.row_factory=sqlite3.Row
        rows=[dict(r) for r in con.execute(sql,params).fetchall()]
        _DB_QUERY_LAST_ERROR=''
        return rows
    except Exception as e:
        _DB_QUERY_LAST_ERROR=f'{type(e).__name__}: {e}'; _DB_QUERY_LAST_ERROR_TS=int(time.time())
        if int(time.time())-_DB_QUERY_LAST_LOG>=30:
            print('MTPADMIN web SQLite query error: '+_DB_QUERY_LAST_ERROR,flush=True); _DB_QUERY_LAST_LOG=int(time.time())
        return []
    finally:
        if con is not None:
            try: con.close()
            except Exception: pass


def _x_event(category,action,actor='system',detail=''):
    con=None
    try:
        con=sqlite3.connect(DB,timeout=5)
        con.execute('INSERT INTO system_events(ts,category,action,actor,detail) VALUES(?,?,?,?,?)',(int(time.time()),str(category)[:32],str(action)[:80],str(actor)[:80],str(detail)[:500]))
        con.commit()
    except Exception as e:
        print('MTPADMIN event write error: '+type(e).__name__+': '+str(e),flush=True)
    finally:
        if con is not None:
            try: con.close()
            except Exception: pass

_db_page_prev=page_template
def page_template(title,body,user,active='dashboard',refresh=None,message=''):
    if _DB_QUERY_LAST_ERROR and int(time.time())-_DB_QUERY_LAST_ERROR_TS<60:
        body=("<div class='card' style='margin-bottom:14px;border-color:#b42318'><div class='bad'><b>Статистика временно недоступна.</b></div><div class='muted'>"+esc(_DB_QUERY_LAST_ERROR)+"</div></div>"+body)
    return _db_page_prev(title,body,user,active,refresh,message)
