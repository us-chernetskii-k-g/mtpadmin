            elif path=='/healthz':
                data=b'ok\n'; self.send_response(200); self.send_header('Content-Type','text/plain'); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
            else: self.send_html('Не найдено','<div class="card"><h1>404</h1></div>','dashboard',404)
        except Exception as e:
            self.send_html('Ошибка',f'<div class="card"><h1>Ошибка</h1><pre>{esc(type(e).__name__+": "+str(e))}</pre></div>','dashboard',500)

    def do_POST(self):
        if not self.require_user(): return
        path=urllib.parse.urlsplit(self.path).path
        try:
            f=self.form()
            if not csrf_ok(self.user(),f.get('csrf','')):
                self.send_html('CSRF','<div class="card"><h1>Запрос отклонён</h1><p>CSRF token недействителен. Обновите страницу.</p></div>','dashboard',403); return
            if handle_guard_post(self,path,f): return
            if path=='/action/source-add':
                name=safe_source_name(f.get('name')); argv=['add',name]
                tag=(f.get('ad_tag') or '').strip()
                if tag:
                    if not HEX32_RE.fullmatch(tag): raise ValueError('Ad tag должен содержать 32 hex-символа')
                    argv += ['--ad-tag',tag.lower()]
                mc=safe_int(f.get('max_conns'),'Макс. соединений'); mi=safe_int(f.get('max_ips'),'Макс. IP')
                if mc: argv += ['--max-conns',str(mc)]
                if mi: argv += ['--max-ips',str(mi)]
                secret=source_mutation(argv,capture_secret=True)
                body=f'<div class="card"><h1>Источник {esc(name)} создан</h1><p>Сохраните новый secret. Он показан только в этом ответе и не помещается в URL.</p><div class="linkbox">{esc(secret)}</div><p><a class="btn" href="/sources">Вернуться к источникам</a></p></div>'
                self.send_html('Источник создан',body,'sources'); return
            if path in ('/action/source-enable','/action/source-disable','/action/source-rotate','/action/source-delete'):
                name=safe_source_name(f.get('name')); primary=state().get('PROFILE','MAIN')
                if path.endswith('enable'): source_mutation(['enable',name]); msg=f'{name}: включён'
                elif path.endswith('disable'): source_mutation(['disable',name]); msg=f'{name}: отключён'
                elif path.endswith('rotate'):
                    secret=source_mutation(['rotate',name],capture_secret=True)
                    body=f'<div class="card"><h1>Secret источника {esc(name)} изменён</h1><p>Сохраните новый secret. Старые ссылки уже недействительны.</p><div class="linkbox">{esc(secret)}</div><p><a class="btn" href="/sources">Вернуться к источникам</a></p></div>'
                    self.send_html('Secret изменён',body,'sources'); return
                else:
                    if name==primary: raise ValueError('Основной профиль удалять запрещено')
                    source_mutation(['delete',name]); msg=f'{name}: удалён'
                self.redirect('/sources',msg); return
            if path=='/action/backup':
                rc,out=cli('backup',timeout=50)
                if rc: raise RuntimeError(out)
                self.redirect('/system','Backup создан: '+out[-180:]); return
            if path=='/action/geo-update':
                rc,out=cli('geo-update',timeout=180)
                if rc: raise RuntimeError(out)
                self.redirect('/system','GeoIP обновлён'); return
            if path=='/action/restart':
                rc,out=cli('restart',timeout=60)
                if rc: raise RuntimeError(out)
                self.redirect('/system','TeleMT перезапущен'); return
            self.send_html('Не найдено','<div class="card"><h1>404</h1></div>','dashboard',404)
        except Exception as e:
            self.send_html('Ошибка действия',f'<div class="card"><h1>Действие не выполнено</h1><pre>{esc(type(e).__name__+": "+str(e))}</pre><p><a class="btn secondary" href="javascript:history.back()">Назад</a></p></div>','dashboard',400)


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('--listen',default='127.0.0.1')
    ap.add_argument('--port',type=int,default=9199)
    args=ap.parse_args()
    if args.listen not in ('127.0.0.1','::1'):
        raise SystemExit('MTPADMIN Web refuses non-loopback listen address')
    if not Path(CSRF_FILE).exists():
        raise SystemExit(f'missing {CSRF_FILE}')
    httpd=ThreadingHTTPServer((args.listen,args.port),Handler)
    httpd.daemon_threads=True
    print(f'MTPADMIN Web {VERSION} listening on {args.listen}:{args.port}',flush=True)
    httpd.serve_forever()

if __name__=='__main__': main()
