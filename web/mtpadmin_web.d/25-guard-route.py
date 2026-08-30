            elif path=='/guard':
                self.send_html('Безопасность',security_html(self.user(),csrf_token(self.user())),'security',refresh=15,message=msg)
